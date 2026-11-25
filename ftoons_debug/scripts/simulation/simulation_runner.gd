class_name SimulationRunner
extends RefCounted

signal sound_effect_requested(event: Dictionary)
signal audio_clock_advanced(playback: Dictionary)
signal campaign_completed(goal: Dictionary)
const CampaignGoals = preload("res://scripts/simulation/campaign_goals.gd")
## Explicit diagnostic opt-out for physics captures beyond the native finish.
var campaign_goals_enabled := true

const SimulationState = preload("res://scripts/simulation/simulation_state.gd")
const PartRegistry = preload("res://scripts/simulation/part_registry.gd")
const BearingPhysics = preload("res://scripts/simulation/bearing_physics.gd")
const WorldPhysics = preload("res://scripts/simulation/world_physics.gd")
const GearConnections = preload("res://scripts/simulation/gear_connections.gd")
const NativeState = preload("res://scripts/simulation/native_state_contract.gd")
const NativeConstructionFrames = preload("res://scripts/simulation/native_construction_frames.gd")

const FIXED_SHIFT := 15
const FIXED_ONE := 1 << FIXED_SHIFT

var puzzle: PuzzleDefinition
var registry: PartRegistry
var initial_state: SimulationState
var state: SimulationState
var step_acceleration: Dictionary = {}
var bearing_physics := BearingPhysics.new()
var world_physics := WorldPhysics.new()
const DOS_TO_RUNNER_SHIFT := FIXED_SHIFT - 9
# 2F8F:00AC initializes descriptor+11C from this 85-entry table.
# Original TOONS.EXE file offset 268520; verified against the live descriptors.
# Equal ranks preserve inventory arrival order (1000:5AD1 uses strict <).
const NATIVE_INVENTORY_ORDER := [36,37,35,68,69,70,71,73,74,79,12,22,23,24,30,60,61,63,64,65,66,67,72,54,55,56,57,58,59,14,3,15,16,17,20,21,53,78,76,1,0,18,25,80,81,2,13,52,38,39,40,41,42,43,44,19,62,75,4,5,6,7,8,9,10,11,31,32,33,34,45,46,77,26,27,28,29,82,83,47,48,49,50,51,84]

func is_cake4_pilot() -> bool:
	return puzzle.source_name.to_upper() == "CAKE4.LEV"


func uses_balloon_dragon_preview() -> bool:
	# Historical fixture classification, not a separate simulation path.
	if is_cake4_pilot():
		return true
	if puzzle.construction_context != "home_toons" or puzzle.parts.is_empty():
		return false
	for part in puzzle.parts:
		if part.part_type not in [23, 35]:
			return false
	return true


func _init(definition: PuzzleDefinition, part_registry: PartRegistry = null) -> void:
	puzzle = definition
	registry = part_registry if part_registry != null else PartRegistry.new()
	initial_state = _make_initial_state()
	state = initial_state.clone()

func uses_bearing_physics() -> bool:
	# Historical classifier retained for existing PUZ_802 tools. All puzzles
	# now run WorldPhysics, including when this narrow classifier returns false.
	return uses_rolling_physics()

func uses_rolling_physics() -> bool:
	return bearing_physics.supports(puzzle)

func uses_world_physics() -> bool:
	return world_physics.available()

func _construction_height(source: PartDefinition) -> int:
	# Campaign5D59 resets inventory extents with4704 before7AFA:0085
	# copies factory+5B into logical+43.6212 then derives a separate frame.
	if source.part_type in [47,48,49,50,51,84] and source.construction_context=="campaign" and source.is_in_parts_bin():
		var extent: Array=world_physics.data.geometry.get(str(source.part_type),{}).get("factory_extent",[])
		if extent.size()==2: return int(extent[1])
	return source.placement_height()

func _make_initial_state(place_inventory: bool = false) -> SimulationState:
	var result := SimulationState.new()
	for index in puzzle.parts.size():
		var source: PartDefinition = puzzle.parts[index]
		var part := SimulationState.SimPart.new()
		part.index = index
		part.part_type = source.part_type
		part.appearance = NativeConstructionFrames.source_selector(source)
		part.state = part.appearance if part.part_type == 2 else part.state
		part.flags = source.flags_1
		part.flags08 = source.flags_2
		part.flags0a = source.flags_3
		part.settings = source.wire_terminal
		part.authored_settings = source.wire_terminal
		part.definition = source
		part.previous_appearance = part.appearance
		part.older_appearance = part.appearance
		part.links.assign([source.connected_1,source.connected_2,source.outlet_plugged_1,source.outlet_plugged_2])
		part.trigger_state = -1 if part.part_type in [36,37] else 0
		part.width = source.placement_width()
		part.height = _construction_height(source)
		if part.part_type==61:
			var extent:=NativeConstructionFrames.anvil_initial_extent(source,puzzle,world_physics.data.geometry.get("61",{}))
			part.width=extent.x
			part.height=extent.y
		part.x_fixed = source.pos_x << FIXED_SHIFT
		part.y_fixed = source.pos_y << FIXED_SHIFT
		part.previous_position = Vector2i(source.pos_x,source.pos_y)
		part.older_position = part.previous_position
		part.placed = place_inventory or not source.is_in_parts_bin()
		part.flip_x = source.initial_flip_x()
		part.flip_y = source.initial_flip_y()
		if index<puzzle.editor_transforms.size():
			var transform: Dictionary=puzzle.editor_transforms[index]
			part.rotation=int(transform.rotation)
			part.editor_mirror_x=bool(transform.mirror_x)
			part.editor_mirror_y=bool(transform.mirror_y)
		var velocity := WorldPhysics.initial_velocity(part.part_type)
		part.vx_fixed = velocity.x << DOS_TO_RUNNER_SHIFT
		part.vy_fixed = velocity.y << DOS_TO_RUNNER_SHIFT
		result.parts.append(part)
	world_physics.initialize(puzzle,result)
	_replay_campaign_chain_history(result,place_inventory)
	RopePhysics.initialize(result)
	preload("res://scripts/simulation/belt_connections.gd").initialize(result)
	GearConnections.rebuild(result)
	_initialize_native_selectors(result)
	CampaignGoals.reset(puzzle,result)
	return result

func _replay_campaign_chain_history(runtime: SimulationState,place_inventory: bool) -> void:
	if puzzle.construction_context!="campaign": return
	# 298D:55AC first inserts the serialized solution into the stage lists.
	# 298D:5D59 then removes unpinned gadgets in mover/static traversal order.
	# Reproduce the list operations independently of the already recovered
	# per-type construction geometry and connection initialization below.
	runtime.query_chains.clear()
	for p in runtime.parts:
		p.placed=true
		world_physics.reactions.insert_chain(runtime,p,world_physics)
	var removed: Array[int]=[]
	for key in [0x1000,0x2000,0]:
		var loaded: Array=runtime.query_chains.get(key,[]).duplicate()
		for id in loaded:
			var p:=runtime.parts[int(id)]
			if removed.has(p.index) or not p.definition.is_in_parts_bin(): continue
			# 5D59 never removes a connection controller merely because its
			# derived inventory classification is true. 5907 removes it when
			# an endpoint is removed; an unpinned Pulley removes its Rope first.
			if p.part_type in [1,14]: continue
			if p.part_type==17:
				_campaign_remove_to_inventory(runtime,p.definition.pulley_rope_owner,removed)
			_campaign_remove_to_inventory(runtime,p.index,removed)
			# 5907: Belt before Rope slot0, then slot1. Removed controllers
			# disconnect both ends, so later endpoint visits do not reinsert.
			for candidate in runtime.parts:
				if candidate.part_type==1 and candidate.definition.belt_endpoints.has(p.index):
					_campaign_remove_to_inventory(runtime,candidate.index,removed)
			if p.part_type!=17:
				for slot in 2:
					for candidate in runtime.parts:
						if candidate.part_type!=14 or candidate.definition.rope_slots.is_empty(): continue
						var rope: Dictionary=candidate.definition.rope_slots[0]
						for end in 2:
							if int(rope.ends[end])==p.index and int(rope.slots[end])==slot:
								_campaign_remove_to_inventory(runtime,candidate.index,removed)
	runtime.query_chains[0x800]=removed.duplicate()
	if place_inventory:
		# The ordinary inventory leaders are dropped before connecting Ropes
		# and Belts. A successful drop reinserts through1000:5CA6 ->5AD1;
		# directly constructing an already-solved list skips this history.
		for connections in [false,true]:
			for id in removed:
				var p:=runtime.parts[id]
				if (p.part_type in [1,14])!=connections: continue
				take_inventory_connection(p)
				p.placed=true
				world_physics.reactions.insert_chain(runtime,p,world_physics)
	# Keep the linked successor view coherent also for the unsolved inventory.
	for key in runtime.query_chains:
		var chain: Array=runtime.query_chains[key]
		for i in chain.size():
			runtime.parts[int(chain[i])].list_next=int(chain[i+1]) if i+1<chain.size() else -1

static func take_inventory_connection(part: SimulationState.SimPart) -> void:
	if part.placed or part.part_type not in [1,14]: return
	# 2F9C:2F73 Take writes current and saved +95/+97 to -100. The
	# connection finish paths preserve that sorting key; endpoint reties
	# (2F9C:2533) do not perform Take and must preserve their existing key.
	part.list_position=Vector2i(-100,-100)
	part.x_fixed=-(100<<FIXED_SHIFT)
	part.y_fixed=-(100<<FIXED_SHIFT)

func _campaign_remove_to_inventory(runtime: SimulationState,index: int,removed: Array[int]) -> void:
	if index<0 or index>=runtime.parts.size() or removed.has(index): return
	var p:=runtime.parts[index]
	if not p.definition.is_in_parts_bin(): return
	p.placed=false
	world_physics.reactions.insert_chain(runtime,p,world_physics)
	var rank:=NATIVE_INVENTORY_ORDER.find(p.part_type)
	var slot:=removed.size()
	for i in removed.size():
		if rank<NATIVE_INVENTORY_ORDER.find(runtime.parts[removed[i]].part_type):
			slot=i
			break
	removed.insert(slot,p.index)


func _initialize_native_selectors(runtime: SimulationState) -> void:
	# Native8A1E copies saved+99 before calling the constructor. Keep this
	# selector separate from current rendering, especially for programmed Timers.
	for p in runtime.parts:
		if not NativeState.supported(p.part_type): continue
		var selector:=NativeConstructionFrames.source_selector(p.definition)
		var provenance:="298D:5142 authored saved selector"
		if p.part_type==0 and selector!=p.definition.appearance:
			provenance="298D:5D59 campaign inventory reset"
		elif p.part_type==38 and p.definition.construction_context=="campaign" and p.definition.is_in_parts_bin():
			selector=0
			provenance="298D:5D59 / 754B:03C0 inventory Timer saved selector reset"
		elif p.part_type==2:
			NativeConstructionFrames.refresh_switch(p)
			world_physics.frame_geometry(p)
			selector=p.appearance
			provenance="1000:5465/55B3 electrical socket construction"
		elif p.part_type in [17,47,48,49,50,51,84]:
			selector=p.appearance
			provenance="native construction route/width selector"
		elif p.part_type in [60,61] and p.appearance<2:
			# These constructors select the intact Rope-attached representation.
			var attached:=false
			for rope in runtime.ropes:
				attached=attached or int(rope.route[0])==p.index or int(rope.route.back())==p.index
			p.appearance=1 if attached else 0
			world_physics.frame_geometry(p)
			selector=1 if NativeConstructionFrames.initially_connected_to_primary(p.definition,puzzle) else 0
			provenance="initial active source Rope attachment saved selector"
		NativeState.seed_selector(p,selector,provenance)
		if p.part_type==2: p.state=selector

func set_native_construction_selector(index: int, selector: int, provenance: String, also_latch: bool=false) -> void:
	if state.tick!=0 or index<0 or index>=state.parts.size(): return
	var p:=state.parts[index]
	NativeState.write_saved_selector(p,selector,provenance,also_latch)
	if p.part_type==2 and also_latch: p.state=selector

func flip_native_construction(index: int, axis: int) -> bool:
	if state.tick!=0 or index<0 or index>=state.parts.size(): return false
	var p:=state.parts[index]
	if p.part_type in [3,41]:
		if axis!=1: return false
		# 5C75:0180 / 5D96:0054 select another pose. Neither toggles
		# flags08: reflecting that selected frame again would double-flip it.
		p.appearance=2 if p.appearance==0 else 0
	elif p.part_type==63:
		# 5F4B:0125 rotates between vertical/horizontal before it mirrors.
		if axis==1:
			if p.appearance==0:
				p.appearance=1
				p.flip_y=false
			else: p.flip_x=not p.flip_x
		elif axis==2:
			if p.appearance==0: p.flip_y=not p.flip_y
			else:
				p.appearance=0
				p.flip_x=false
		else: return false
		p.flags08=(p.flags08&~0x30)|(0x10 if p.flip_x else 0)|(0x20 if p.flip_y else 0)
		p.editor_mirror_x=false
		p.editor_mirror_y=false
		var meta: Dictionary=world_physics.data.geometry.get("63",{})
		var sizes: Array=meta.get("frame_sizes",[])
		if sizes.is_empty(): sizes=meta.get("sprite_frame_sizes",[])
		if p.appearance<sizes.size():
			p.width=int(sizes[p.appearance][0])
			p.height=int(sizes[p.appearance][1])
	else: return false
	p.previous_appearance=p.appearance
	p.older_appearance=p.appearance
	p.reaction_data["construction_appearance"]=p.appearance
	set_native_construction_selector(index,p.appearance,"native construction flip selector",p.part_type in [3,41])
	world_physics.frame_geometry(p)
	return true

func _prepare_native_run() -> void:
	if state.tick!=0: return
	for p in state.parts:
		if p.part_type in [1,14]:
			# Play -> 8A1E restores saved positions before normal updates.
			# Drag's temporary non-spatial -1 coordinates are not a sort key.
			p.x_fixed=p.list_position.x<<FIXED_SHIFT
			p.y_fixed=p.list_position.y<<FIXED_SHIFT
			p.previous_position=p.list_position
			p.older_position=p.list_position
		if not NativeState.supported(p.part_type): continue
		if bool(p.reaction_data.get(NativeState.PREPARED_KEY,false)): continue
		if not p.reaction_data.has(NativeState.SELECTOR_KEY):
			NativeState.seed_selector(p,NativeConstructionFrames.source_selector(p.definition),"source fallback for newly constructed record")
		NativeState.begin_reset(p)
		var selector: int=int(p.reaction_data[NativeState.LATCHED_STATE_KEY])
		if p.part_type in [2,41]: p.state=selector
		# +10/+12 are copied before the constructor can alter current+0E.
		p.previous_appearance=selector
		p.older_appearance=selector
		p.appearance=selector
		if p.part_type==2: NativeConstructionFrames.refresh_switch(p)
		if p.part_type==38:
			WorldPhysics.refresh_timer(p)
		if p.part_type in [60,61] and p.appearance<2:
			var attached:=false
			for rope in state.ropes:
				attached=attached or int(rope.route[0])==p.index or int(rope.route.back())==p.index
			p.appearance=1 if attached else 0
		world_physics.frame_geometry(p)
		NativeState.finish_reset(p)

func _restore_native_chain_order(previous: SimulationState) -> void:
	# 8A1E does not restore the pre-Play list heads. It first releases static
	# cats/mice (7244), freezes moving Rugs (7215), then resets authored nodes
	# in their existing order and frees spawned nodes. Preserve that history.
	var ordered:=previous.clone()
	for id in ordered.query_chains.get(0x2000,[]).duplicate():
		var p:=ordered.parts[int(id)]
		if p.part_type not in [36,37]: continue
		p.flags=(p.flags&~0x6000)|0x1000
		p.chain_override=-1
		world_physics.reactions.insert_chain(ordered,p,world_physics)
	for id in ordered.query_chains.get(0x1000,[]).duplicate():
		var p:=ordered.parts[int(id)]
		if p.part_type!=77: continue
		p.flags=(p.flags&~0x1000)|0x2000
		p.chain_override=-1
		world_physics.reactions.insert_chain(ordered,p,world_physics)
	state.query_chains.clear()
	for key in ordered.query_chains:
		var chain: Array=[]
		for id in ordered.query_chains[key]:
			if int(id)>=state.parts.size(): continue # Native destructor removes spawned nodes.
			var p:=state.parts[int(id)]
			p.flags=(p.flags&~0x7000)|(ordered.parts[int(id)].flags&0x7000)
			p.chain_override=ordered.parts[int(id)].chain_override
			chain.append(id)
		state.query_chains[key]=chain
		for i in chain.size():
			state.parts[int(chain[i])].list_next=int(chain[i+1]) if i+1<chain.size() else -1

func restore_construction_arrangement(arrangement: SimulationState) -> void:
	#1000:2589 performs another8A1E reset on normal Stop. Its saved+99
	#survives the run, while positions/settings/links return to the arrangement.
	var previous:=state
	state=arrangement.clone()
	# 8A1E restores gadget fields, not the process-global 298D:31F6 RNG.
	# Retain its advanced state across Stop instead of rewinding the backup.
	state.inherit_process_globals(previous)
	_restore_native_chain_order(previous)
	state.audio.stop_bank_effects()
	state.audio.begin_update_epoch()
	for p in state.parts:
		if not NativeState.supported(p.part_type) or p.index>=previous.parts.size(): continue
		var live:=previous.parts[p.index]
		if live.reaction_data.has(NativeState.SAVED_SELECTOR_KEY):
			p.reaction_data[NativeState.SAVED_SELECTOR_KEY]=live.reaction_data[NativeState.SAVED_SELECTOR_KEY]
			p.reaction_data[NativeState.SAVED_SOURCE_KEY]=live.reaction_data.get(NativeState.SAVED_SOURCE_KEY,"")
		p.reaction_data.erase(NativeState.PREPARED_KEY)
	_prepare_native_run()
	# 8A1E -> 533D/7844 restores attachment points and all length generations.
	# The construction loop (298D:2FB5 -> 887B -> 88BC) then shifts the
	# point caches on successive UI frames. Public Stop exposes that settled
	# construction state, rather than the intermediate reset-helper boundary.
	for rope in state.ropes:
		RopePhysics.refresh_event_points(state,rope)
		for side in 2: rope.lengths[side]=RopePhysics.distance(RopePhysics.end_delta(state,rope,side))
		rope.previous_lengths=rope.lengths.duplicate()
		rope.older_lengths=rope.lengths.duplicate()
		RopePhysics.seed_point_history(rope)
	for p in state.parts: p.reaction_data.erase(NativeState.PREPARED_KEY)
	state.running=false
	audio_clock_advanced.emit(state.audio.snapshot())

func reset() -> void:
	var sound_enabled := state.audio.enabled
	var previous:=state
	state = initial_state.clone()
	state.inherit_process_globals(previous)
	state.audio.stop_bank_effects()
	state.audio.begin_update_epoch()
	state.audio.set_enabled(sound_enabled)
	state.running = false
	_emit("reset", -1, {})
	audio_clock_advanced.emit(state.audio.snapshot())

func place_solution() -> void:
	# Reconstruct every authored record before building collision/query lists.
	# Reusing a running state would retain animation, spawned objects and queues;
	# moving inventory alone would leave the rest of the scene at its last tick.
	# Keep initial_state unchanged so Reset still restores the unsolved puzzle.
	var sound_enabled := state.audio.enabled
	var previous:=state
	state = _make_initial_state(true)
	state.inherit_process_globals(previous)
	state.audio.stop_bank_effects()
	state.audio.begin_update_epoch()
	state.audio.set_enabled(sound_enabled)
	_emit("place_solution", -1, {})
	audio_clock_advanced.emit(state.audio.snapshot())

func set_audio_enabled(enabled: bool) -> void:
	state.audio.set_enabled(enabled)
	audio_clock_advanced.emit(state.audio.snapshot())

func run() -> void:
	if state.goal.get("completed",false): return
	if state.tick==0: state.audio.begin_update_epoch()
	_prepare_native_run()
	state.running = true
	audio_clock_advanced.emit(state.audio.snapshot())
	_emit("run", -1, {})

func pause() -> void:
	state.running = false
	_emit("pause", -1, {})

func step() -> SimulationState:
	if state.goal.get("completed",false): return state
	_prepare_native_run()
	# Capture construction identities and gate origins before the first physics
	# update can move an actor or recycle its slot. Native selectors bind later.
	if campaign_goals_enabled and puzzle.authored_goals.has("when") and not state.goal.initialized:
		CampaignGoals.Authored.bind(puzzle.authored_goals, state)
	# Stable part order and explicit integer arithmetic make this independent of
	# render frame rate. Every puzzle uses the same recovered-data mechanics
	# path; type-specific reactions/AI remain separately tracked work.
	state.tick += 1
	state.audio.advance_to_tick(state.tick)
	if uses_world_physics():
		var events := world_physics.step(puzzle,state,step_acceleration)
		for event in events:
			_emit(String(event.kind),int(event.part_index),event)
		audio_clock_advanced.emit(state.audio.snapshot())
		_evaluate_goal(events)
		return state
	for part in state.parts:
		if not part.active or not part.placed:
			continue
		var acceleration: Vector2i = step_acceleration.get(part.part_type, Vector2i.ZERO)
		part.vx_fixed += acceleration.x
		part.vy_fixed += acceleration.y
		var behavior := registry.behavior_for(part.part_type)
		var behavior_acceleration := behavior.acceleration(part, puzzle)
		part.vx_fixed += behavior_acceleration.x
		part.vy_fixed += behavior_acceleration.y
		part.x_fixed += part.vx_fixed
		part.y_fixed += part.vy_fixed
		_emit("integrate", part.index, {"x_fixed": part.x_fixed, "y_fixed": part.y_fixed, "vx_fixed": part.vx_fixed, "vy_fixed": part.vy_fixed})
	audio_clock_advanced.emit(state.audio.snapshot())
	_evaluate_goal()
	return state

func _evaluate_goal(events: Array = []) -> void:
	if not campaign_goals_enabled: return
	CampaignGoals.advance(puzzle,state,events)
	if state.goal.get("completed",false):
		#1000:2554..2580 stops gameplay effects before entering the reward.
		state.audio.stop_bank_effects()
		audio_clock_advanced.emit(state.audio.snapshot())
		_emit("campaign_completed",-1,{"goal":state.goal.duplicate(true)})
		campaign_completed.emit(state.goal.duplicate(true))


func set_acceleration(part_type: int, x_fixed: int, y_fixed: int) -> void:
	step_acceleration[part_type] = Vector2i(x_fixed, y_fixed)

func set_transform(part_index: int, position: Vector2i, rotation: int = 0, flip_x: bool = false, flip_y: bool = false) -> bool:
	if part_index < 0 or part_index >= state.parts.size():
		return false
	var part := state.parts[part_index]
	# Preserve player resize through subsequent pickup/flip; authored definitions
	# remain immutable so Reset/Place solution still reconstruct original sizes.
	var construction_extent: Vector2i=part.reaction_data.get("construction_extent",Vector2i.ZERO)
	var construction_settings: int=int(part.reaction_data.get("construction_settings",-1))
	var construction_appearance: int=int(part.reaction_data.get("construction_appearance",-1))
	var initial_anvil_extent:=Vector2i(part.width,part.height)
	var native_fields:=NativeState.metadata(part)
	var editor_pinned: bool=puzzle.construction_context=="home_toons" and (part.flags0a&0x40)!=0
	# Tunnel +B1 is a live construction link in both modes. Repositioning must
	# retain the current pair, never resurrect a removed serialized solution link.
	var tunnel_partner: int=part.target_part if part.part_type==46 else -1
	part.x_fixed = position.x << FIXED_SHIFT
	part.y_fixed = position.y << FIXED_SHIFT
	part.previous_position = position
	part.older_position = position
	part.list_position = position
	part.rotation = posmod(rotation, 4)
	part.flip_x = flip_x
	part.flip_y = flip_y
	part.placed = true
	if uses_world_physics():
		# Repositioning establishes a fresh drop, including after an off-board run.
		var source: PartDefinition = part.definition
		part.flags08 = (source.flags_2 & ~0x30) | (0x10 if flip_x else 0) | (0x20 if flip_y else 0)
		part.flags0a = source.flags_3
		part.state = 0
		part.appearance = NativeConstructionFrames.source_selector(source)
		part.state = int(native_fields.get(NativeState.LATCHED_STATE_KEY,part.appearance)) if part.part_type == 2 else part.state
		var mirrors:=world_physics.native_mirror_flags(part)
		part.editor_mirror_x=(flip_x!=source.initial_flip_x()) and (mirrors&1)==0
		part.editor_mirror_y=(flip_y!=source.initial_flip_y()) and (mirrors&2)==0
		part.animation_tick = 0
		part.triggered = false
		var velocity := WorldPhysics.initial_velocity(part.part_type)
		part.vx_fixed = velocity.x << DOS_TO_RUNNER_SHIFT
		part.vy_fixed = velocity.y << DOS_TO_RUNNER_SHIFT
		part.contact_part = -1
		part.contact_angle = 0
		part.contact_edge = 0
		part.contact_status_8f = 0
		part.contact_status_90 = 0
		part.flags = source.flags_1 & ~(15|0x800)
		if puzzle.construction_context=="home_toons":
			part.flags=(part.flags&~0x8000)|(0x8000 if editor_pinned else 0)
			part.flags0a=(part.flags0a&~0x40)|(0x40 if editor_pinned else 0)
		part.trigger_state = 0
		part.reaction_state = 0
		part.authored_settings = source.wire_terminal
		part.settings = source.wire_terminal
		part.width = source.placement_width()
		part.height = _construction_height(source)
		if part.part_type==61:
			# Native6212 retains the first logical dimensions when a Rope
			# changes the drawing frame from31 to33 pixels (or back).
			part.width=initial_anvil_extent.x
			part.height=initial_anvil_extent.y
		# Keep live connection membership; manual placement is not Place solution.
		part.previous_appearance = part.appearance
		part.older_appearance = part.appearance
		part.target_part = -1
		if tunnel_partner>=0 and tunnel_partner<state.parts.size() and state.parts[tunnel_partner].active and state.parts[tunnel_partner].part_type==46 and state.parts[tunnel_partner].target_part==part_index:
			part.target_part=tunnel_partner
		part.aux_a5 = 0
		part.scratch61 = 0
		part.traversal_af = 0
		part.collision_enabled = true
		var rope_anchors: Array=RopePhysics.anchors(part).duplicate()
		part.reaction_data.clear()
		part.reaction_data["rope_anchors"]=rope_anchors
		if construction_settings>=0:
			part.settings=construction_settings
			part.authored_settings=construction_settings
			part.reaction_data["construction_settings"]=construction_settings
		#5D60:0000 (Anvil) selects its intact frame from the live Rope
		#attachment, not the authored solution selector. Piano follows the
		#same construction rule. An unconnected drag must clear frame1 too.
		if part.part_type in [60,61] and part.appearance<2:
			part.appearance=0
			for rope in state.ropes:
				if int(rope.route[0])==part_index or int(rope.route.back())==part_index:
					part.appearance=1
		RopePhysics.refresh_lengths(state,part_index)
		part.trigger_state = -1 if part.part_type in [36,37] else 0
		part.active = true
		world_physics.initialize_geometry(part)
		if construction_appearance>=0:
			part.appearance=construction_appearance
			part.previous_appearance=construction_appearance
			part.reaction_data["construction_appearance"]=construction_appearance
			world_physics.frame_geometry(part)
		if construction_extent!=Vector2i.ZERO:
			part.width=construction_extent.x
			part.height=construction_extent.y
			part.reaction_data["construction_extent"]=construction_extent
			world_physics.resize_geometry(part)
			world_physics.frame_geometry(part)
		if part.part_type==2:
			NativeConstructionFrames.refresh_switch(part)
			world_physics.frame_geometry(part)
		NativeState.restore_metadata(part,native_fields)
		world_physics.reactions.insert_chain(state,part,world_physics)
		BeltConnections.refresh(state,part_index)
		if part.part_type==18: GearConnections.rebuild(state)
	_emit("place", part_index, {"x": position.x, "y": position.y, "rotation": part.rotation, "flip_x": flip_x, "flip_y": flip_y})
	return true

func transform(part_index: int) -> Dictionary:
	if part_index < 0 or part_index >= state.parts.size():
		return {}
	var part := state.parts[part_index]
	return {"rotation": part.rotation, "flip_x": part.flip_x, "flip_y": part.flip_y}

func trace_json() -> String:
	return JSON.stringify(state.trace, "  ")

func _emit(kind: String, part_index: int, values: Dictionary) -> void:
	var event := {"tick": state.tick, "kind": kind, "part_index": part_index}
	for key in values:
		event[key] = values[key]
	state.trace.append(event)
	if kind == "sound_effect":
		sound_effect_requested.emit(event.duplicate(true))
	if state.trace.size() > 25000:
		state.trace = state.trace.slice(-20000)
