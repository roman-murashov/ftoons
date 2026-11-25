extends RefCounted
## One construction session shared by both presentations. No UI nodes are owned here.
signal level_load_requested(source_name: String)
signal puzzle_install_requested(puzzle: PuzzleDefinition)
const Document = preload("res://scripts/io/home_toons_document.gd")
const AuthoredGoals = preload("res://scripts/simulation/authored_goals.gd")
const CampaignGoals = preload("res://scripts/simulation/campaign_goals.gd")
var editor_solution: Dictionary = {}
var _loaded_goals: Dictionary = {}
var editor_source := "Untitled.json"
var last_save_path := ""
var campaign_progress := preload("res://scripts/io/campaign_progress.gd").new()
# Native DS:43D5 is1 after normal campaign startup; each full wipe advances it.
var wipe_phase:=1
var level_wipe_variant:=1
var retain_completion_audio:=false

func next_wipe_variant() -> int:
	wipe_phase=(wipe_phase+1)%3
	return wipe_phase

func completion_wipe_variant() -> int:
	if not runner.state.goal.has("wipe_variant"): runner.state.goal.wipe_variant=next_wipe_variant()
	return int(runner.state.goal.wipe_variant)

func is_completed() -> bool:
	return runner!=null and bool(runner.state.goal.get("completed",false))

func next_campaign_level(native_order: bool = false) -> String:
	if runner==null: return ""
	# Continue through the imported Windows series in both solo presentations.
	# Its last reward returns to construction and uses no DOS progress slot.
	if not runner.puzzle.head_to_head_goal.is_empty():
		var index := level_sources.find(runner.puzzle.source_name)
		if index >= 0 and index + 1 < level_sources.size():
			var following := String(level_sources[index + 1])
			if following.get_extension() == "H2H": return following
		return ""
	if runner.puzzle.campaign_goal_index<0: return ""
	if native_order: return campaign_progress.next_native_level(runner.puzzle.source_name)
	var names:=preload("res://scripts/simulation/campaign_goals.gd").level_names()
	var next:=runner.puzzle.campaign_goal_index+1
	return names[next] if next<names.size() else ""

func has_next_campaign_puzzle() -> bool:
	return not next_campaign_level().is_empty()

func replay_completed(start_immediately: bool = true) -> void:
	if not is_completed(): return
	retain_completion_audio=not start_immediately
	stop()
	# Original reward mode23 returns to construction through298D:206E..208E.
	# The Puzzles debug shortcut can additionally start the restored attempt.
	if start_immediately: play()
	retain_completion_audio=false

func advance_campaign(native_order: bool = false) -> bool:
	if not is_completed(): return false
	var next:=next_campaign_level(native_order)
	if next.is_empty(): return false
	retain_completion_audio=true
	stop()
	var loaded:=request_level(next)
	retain_completion_audio=false
	return loaded

func next_campaign_puzzle() -> bool:
	return advance_campaign()

func _campaign_completed(_goal: Dictionary) -> void:
	completion_wipe_variant()
	runner.state.completion_decoration()
	audio_reset_requested.emit() # Native1000:2554 -> sound-stop(-3), before the wipe.
	tick_accumulator=0.0
	if runner.puzzle.campaign_goal_index >= 0:
		var record: Dictionary=campaign_progress.record(runner.puzzle.source_name,runner.state.tick)
		runner.state.goal.campaign_presentation=campaign_progress.last_presentation.duplicate(true)
		runner.state.goal.completed_date=String(record.get("date",""))
		status="Puzzle completed — Instant replay, Next puzzle, or Stop to edit your arrangement."
		if not campaign_progress.error.is_empty(): status+=" "+campaign_progress.error
	elif not next_campaign_level().is_empty():
		status="Puzzle completed — Instant replay, Next puzzle, or Stop to edit your arrangement."
	else:
		status="Goal reached. Replay or stop to return to construction."
	changed.emit()

func is_editor() -> bool:
	return runner!=null and runner.puzzle.construction_context=="home_toons"

func authoring_available() -> bool:
	return runner!=null and play_backup==null and not grab_active and not runner.state.running

func toggle_editor() -> void:
	if not authoring_available(): return
	var codec:=Document.new()
	if is_editor():
		var doc:=Document.capture(runner)
		var playable:=codec.decode(doc,runner.puzzle.source_name,false)
		if playable!=null:
			editor_solution=doc
			editor_source=runner.puzzle.source_name
			puzzle_install_requested.emit(playable)
	else:
		var doc: Dictionary=editor_solution if not editor_solution.is_empty() and editor_source==runner.puzzle.source_name else Document.capture(runner,true)
		var authored:=codec.decode(doc,runner.puzzle.source_name,true)
		if authored!=null: puzzle_install_requested.emit(authored)
	status=codec.error if not codec.error.is_empty() else ("Home Toons: build the solution, then stick down fixed gadgets." if is_editor() else "Toon-O-Matic: unpinned gadgets are in the inventory.")
	changed.emit()

func new_editor_puzzle() -> void:
	if not authoring_available(): return
	editor_solution.clear()
	last_save_path=""
	var puzzle:=PuzzleDefinition.new()
	puzzle.source_name="Untitled.json"
	puzzle.title="No Title Yet"
	puzzle.instructions="No Description Yet"
	puzzle.construction_context="home_toons"
	puzzle.gravity=runner.puzzle.gravity
	puzzle.pressure=runner.puzzle.pressure
	puzzle.music=runner.puzzle.music
	puzzle_install_requested.emit(puzzle)
	status="New Home Toon. Choose any gadget from the bin."
	changed.emit()

func take_type(type_id: int, native: bool=true) -> int:
	if not is_editor() or not authoring_available(): return -1
	var source:=Document.factory(type_id)
	if source==null: return -1
	runner.puzzle.assign_goal_id(source)
	source.width_1=maxi(source.width_1,source.width_2) if source.width_1==0 else source.width_1
	source.height_1=maxi(source.height_1,source.height_2) if source.height_1==0 else source.height_1
	var seed:=PuzzleDefinition.new()
	seed.construction_context="home_toons"
	seed.parts.append(source)
	var factory_runner:=SimulationRunner.new(seed)
	var p:=factory_runner.state.parts[0].copy()
	# Reuse discarded templates, but never replace a live authored object.
	var index:=runner.state.parts.size()
	for old in runner.state.parts:
		if old.active and not old.placed and old.part_type==type_id: index=old.index; break
	if index==runner.state.parts.size():
		for old in runner.state.parts:
			if not old.placed and old.part_type==type_id: index=old.index; break
	source.list_index=index
	p.index=index
	if index==runner.state.parts.size():
		runner.state.parts.append(p)
		runner.puzzle.parts.append(source)
	else:
		runner.state.parts[index]=p
		runner.puzzle.parts[index]=source
	runner.world_physics.reactions.insert_chain(runner.state,p,runner.world_physics)
	if native: take_native(index)
	else: take(index)
	return index

func set_pinned(index: int, pinned: bool) -> void:
	if not is_editor() or not authoring_available() or index<0 or index>=runner.state.parts.size(): return
	var p:=runner.state.parts[index]
	if not p.active or not p.placed: return
	p.flags=(p.flags&~0x8000)|(0x8000 if pinned else 0)
	p.flags0a=(p.flags0a&~0x40)|(0x40 if pinned else 0)
	# 2F9C:1DE9..1E1C copies the Tunnel pin bit to its +B1 partner.
	var partner:=_tunnel_partner(index)
	if partner>=0:
		var other:=runner.state.parts[partner]
		other.flags=(other.flags&~0x8000)|(0x8000 if pinned else 0)
		other.flags0a=(other.flags0a&~0x40)|(0x40 if pinned else 0)
	status="Stuck down — stays on the stage." if pinned else "Unstuck — goes into the player's inventory."
	changed.emit()

func pin_all() -> void:
	if not is_editor() or not authoring_available(): return
	for p in runner.state.parts:
		if p.active and p.placed:
			p.flags|=0x8000
			p.flags0a|=0x40
	status="All placed gadgets stuck down."
	changed.emit()

func remove_editor_part(index: int) -> void:
	# Compatibility entry for editor authoring/research callers.
	if is_editor(): _flush_part(index)

func flush_part(index: int) -> void:
	if not can_edit_part(index): return
	if not authoring_available() or index<0 or index>=runner.state.parts.size(): return
	var p:=runner.state.parts[index]
	if not p.active or not p.placed or p.spawned or (p.flags0a&0x40): return
	if not is_editor() and not p.definition.is_in_parts_bin(): return
	_flush_part(index)

func _flush_part(index: int) -> void:
	if not authoring_available() or index<0 or index>=runner.state.parts.size(): return
	var removed: Array[int]=[index]
	_return_parts(removed,"Gadget returned to inventory. Attached connections returned to the bin.")

func save_editor(path: String, title: String, overwrite: bool=false) -> String:
	if not is_editor() or not authoring_available(): return "Stop and finish placement before saving."
	var doc:=Document.capture(runner)
	doc.title=title
	var codec:=Document.new()
	if not codec.save_file(path,doc,overwrite): return codec.error
	runner.puzzle.title=title
	runner.puzzle.source_name=path
	last_save_path=path
	editor_source=path
	editor_solution=doc
	if not level_sources.has(path): level_sources.append(path)
	status="Saved "+path
	changed.emit()
	return ""

func set_authored_goals(goals: Dictionary) -> String:
	if not is_editor() or not authoring_available(): return "Finish construction before setting goals."
	var problem := AuthoredGoals.validate(goals, Document.placed_goal_targets(runner))
	if not problem.is_empty(): return problem
	runner.puzzle.authored_goals = goals.duplicate(true)
	CampaignGoals.reset(runner.puzzle, runner.state)
	changed.emit()
	return ""

func load_editor(path: String) -> String:
	if not authoring_available(): return "Stop and finish placement before loading."
	var codec:=Document.new()
	var puzzle:=codec.load_file(path,is_editor())
	if puzzle==null: return codec.error
	editor_solution.clear()
	if not level_sources.has(path): level_sources.append(path)
	puzzle_install_requested.emit(puzzle)
	return ""
var level_sources: Array = []

func request_level(source_name: String) -> bool:
	if play_backup!=null or grab_active or not level_sources.has(source_name): return false
	if source_name.get_extension().to_lower()=="json": return load_editor(source_name).is_empty()
	editor_solution.clear()
	level_load_requested.emit(source_name)
	return runner!=null and runner.puzzle.source_name==source_name

signal changed
signal audio_reset_requested
const SimulationRunner = preload("res://scripts/simulation/simulation_runner.gd")
const RopeEditor = preload("res://scripts/simulation/rope_editor.gd")
var runner: SimulationRunner
var audio_state_provider: Callable
var rope_editor := RopeEditor.new()
var belt_editor := preload("res://scripts/simulation/belt_editor.gd").new()
var selected_index := -1
var grab_index := -1
var grab_backup: SimulationState
var grab_definitions: Array[PartDefinition] = []
# A first Tunnel drop commits only when its mandatory partner is dropped.
var tunnel_pair_first := -1
var grab_active := false
var play_backup: SimulationState
var status := "Choose an inventory item."
var type_names: Dictionary = {}
var tick_accumulator := 0.0
const DosRules = preload("res://scripts/ui/dos_construction_rules.gd")
var native_grab := false
var grab_anchor := Vector2i.ZERO
var placement_invalid := false
var resize_side := ""
var resize_start := Rect2i()
var resize_limits: Dictionary = {}
var probing_transform:=false

func can_edit_part(_index: int) -> bool:
	return true

func begin_native_resize(index: int, side: String, limits: Dictionary) -> void:
	_begin_grab(index)
	if grab_index!=index: return
	native_grab=true
	resize_side=side
	var p:=runner.state.parts[index]
	resize_start=Rect2i(RopePhysics.xy(p),Vector2i(p.width,p.height))
	resize_limits=limits
	changed.emit()

func _resize_native(pointer: Vector2i) -> void:
	var p:=runner.state.parts[grab_index]
	var pos:=resize_start.position
	var size:=resize_start.size
	var snap:=DosRules.drag_position(pointer,Vector2i.ZERO,false)
	if resize_side=="right": size.x=clampi(snap.x+16-pos.x,int(resize_limits.min_width),int(resize_limits.max_width))
	elif resize_side=="left":
		size.x=clampi(resize_start.end.x-snap.x,int(resize_limits.min_width),int(resize_limits.max_width))
		pos.x=resize_start.end.x-size.x
	elif resize_side=="bottom": size.y=clampi(snap.y+16-pos.y,int(resize_limits.min_height),int(resize_limits.max_height))
	elif resize_side=="top":
		size.y=clampi(resize_start.end.y-snap.y,int(resize_limits.min_height),int(resize_limits.max_height))
		pos.y=resize_start.end.y-size.y
	if p.part_type in [26,27,28,29,82,83]:
		if resize_side in ["left","right"]: size.y=16
		else: size.x=16
		p.reaction_data.erase("wall_frame_extent")
	if p.part_type==40:
		var sections:=clampi(roundi(float(size.y-26)/65.0),1,5)
		size.y=26+65*sections
		p.settings=sections<<4
		p.authored_settings=p.settings
	p.x_fixed=pos.x<<SimulationRunner.FIXED_SHIFT
	p.y_fixed=pos.y<<SimulationRunner.FIXED_SHIFT
	p.previous_position=pos
	p.older_position=pos
	p.list_position=pos
	p.width=size.x
	p.height=size.y
	p.reaction_data["construction_extent"]=size
	runner.world_physics.resize_geometry(p)
	runner.world_physics.frame_geometry(p)
	if p.part_type in [47,48,49,50,51,84]:
		runner.set_native_construction_selector(p.index,p.appearance,"7AFA:0078 incline resize construction")
	RopeEditor.refresh_connected(runner,grab_index)
	placement_invalid=DosRules.blocked(runner,grab_index) or not RopeEditor.movement_error(runner,grab_index).is_empty() or not belt_editor.movement_error(runner.state,grab_index).is_empty()
	status="Resize blocked." if placement_invalid else "Click to finish resizing; right-click cancels."

func take_native(index: int) -> void:
	take(index)
	if grab_index != index: return
	native_grab = true
	var p := runner.state.parts[index]
	runner.world_physics.frame_geometry(p)
	# Original3022/302E reads the Tunnel bin's still-zero frame dimensions
	# before its first preview construction. The new partner retains that anchor.
	grab_anchor = Vector2i.ZERO if p.part_type==46 else p.frame_size / 2
	changed.emit()

func pick_native(index: int, pointer: Vector2i) -> void:
	if runner==null or index<0 or index>=runner.state.parts.size(): return
	if runner.state.parts[index].flags0a&0x40: return
	_begin_grab(index)
	if grab_index != index: return
	native_grab = true
	grab_anchor = pointer - RopePhysics.xy(runner.state.parts[index])
	changed.emit()

func invoke(action: String, args: Array = []) -> void:
	callv(action, args)
	changed.emit()

func cancel_input(event: InputEvent) -> bool:
	if grab_active and event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		invoke("_cancel_grab")
		return true
	return false

func set_runner(value: SimulationRunner) -> void:
	_cancel_grab()
	_pull_presented_audio()
	if not retain_completion_audio: audio_reset_requested.emit()
	if runner!=null and runner.campaign_completed.is_connected(_campaign_completed): runner.campaign_completed.disconnect(_campaign_completed)
	if runner!=null and value!=null and runner!=value:
		value.state.inherit_process_globals(runner.state)
		level_wipe_variant=next_wipe_variant()
	runner = value
	_loaded_goals = runner.puzzle.authored_goals.duplicate(true) if runner != null else {}
	if runner!=null: runner.campaign_completed.connect(_campaign_completed)
	play_backup = null
	selected_index = -1
	tick_accumulator = 0.0
	changed.emit()

const PROGRAMMABLE_TYPES := [20,22,38,39,42,59,69]
const MESSAGE_CHARACTERS := "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,:'!@#$%&*()/?+-"

func can_program(index: int) -> bool:
	if not can_edit_part(index): return false
	if runner==null or play_backup!=null or grab_active or runner.state.running: return false
	if index<0 or index>=runner.state.parts.size(): return false
	var p:=runner.state.parts[index]
	return p.part_type in PROGRAMMABLE_TYPES and p.active and p.placed and (p.flags0a&0x800)!=0 and (p.flags0a&0x40)==0 and (p.definition.is_in_parts_bin() or runner.puzzle.construction_context=="home_toons")

func program_ratapult(index: int, value: int) -> bool:
	# Compatibility entry for the first programmer and its existing callers.
	if not can_program(index) or runner.state.parts[index].part_type!=22: return false
	_commit_program(index,posmod(value,100))
	return true

func adjust_program(index: int, direction: int) -> bool:
	if not can_program(index) or direction not in [-1,1]: return false
	var p:=runner.state.parts[index]
	var value:=p.settings
	match p.part_type:
		20,22,69: value=posmod(value+direction,100)
		38:
			value=posmod(value+direction,6)
			p.appearance=0
			p.previous_appearance=0
			p.reaction_data["construction_appearance"]=0
			runner.set_native_construction_selector(index,0,"754B:03C0 Timer programming resets saved selector")
		39: value=(value&0x4000)+posmod((value&255)+direction,100)
		42:
			var current:=MESSAGE_CHARACTERS.find(String.chr(value&255))
			if current<0: current=0
			value=(value&0xff00)|MESSAGE_CHARACTERS.unicode_at(posmod(current+direction,MESSAGE_CHARACTERS.length()))
		59:
			value=1 if value==0 else 0
			p.appearance=4 if value else 0
			p.previous_appearance=p.appearance
			p.reaction_data["construction_appearance"]=p.appearance
			runner.set_native_construction_selector(index,p.appearance,"754B:0508/050F Banana programming selector")
	_commit_program(index,value)
	return true

func _commit_program(index: int, value: int) -> void:
	var p:=runner.state.parts[index]
	# 754B:051F copies live +AF to the starting value +AD for every handler.
	p.settings=value
	p.authored_settings=value
	p.reaction_data["construction_settings"]=value
	runner.world_physics.frame_geometry(p)
	status="%s programmed."%type_names.get(p.part_type,"Gadget")
	changed.emit()

func take(index: int) -> void:
	if runner == null or play_backup != null or rope_editor.active() or belt_editor.active(): return
	if tunnel_pair_first>=0:
		status="Tunnel pair: place the second Tunnel or right-click to cancel the pair."
		changed.emit()
		return
	if index < 0 or index >= runner.state.parts.size(): return
	_cancel_grab()
	if runner.state.parts[index].placed:
		status = "Already placed — click it on the stage."
	else:
		_begin_grab(index)
	changed.emit()

func play() -> void:
	if runner == null: return
	if is_completed(): return
	if grab_active:
		status = "Finish placing the item or cancel before Play."
		changed.emit()
		return
	if play_backup == null:
		if not _can_test_editor_goal(): return
		if audio_state_provider.is_valid() and not runner.world_physics.reference_audio_clock.is_valid():
			runner.state.audio.restore(audio_state_provider.call())
		play_backup = runner.state.clone()
	runner.run()
	status = "Playing — Stop restores your arrangement."
	changed.emit()

func pause() -> void:
	if runner != null: runner.pause()
	changed.emit()

func step() -> void:
	if runner == null or grab_active or is_completed(): return
	if play_backup == null:
		if not _can_test_editor_goal(): return
		play_backup = runner.state.clone()
	if not runner.world_physics.reference_audio_clock.is_valid():
		# A manual Step advances one nominal interval; live Play uses elapsed time.
		runner.state.audio.external_clock=false
		runner.state.audio.update_origin=runner.state.audio.clock-preload("res://scripts/audio/audio_playback_state.gd").update_time(runner.state.tick)
	runner.step()
	changed.emit()

func _can_test_editor_goal() -> bool:
	if not is_editor() or runner.puzzle.authored_goals.is_empty(): return true
	var problem := AuthoredGoals.validate(runner.puzzle.authored_goals, Document.placed_goal_targets(runner))
	CampaignGoals.reset(runner.puzzle, runner.state)
	if problem.is_empty(): return true
	runner.state.goal.error = problem
	status = problem
	changed.emit()
	return false

func stop() -> void:
	if runner == null: return
	_pull_presented_audio()
	if not retain_completion_audio: audio_reset_requested.emit()
	if play_backup != null:
		var enabled := runner.state.audio.enabled
		runner.restore_construction_arrangement(play_backup)
		runner.state.audio.set_enabled(enabled)
		runner.state.running = false
		play_backup = null
	tick_accumulator = 0.0
	status = "Your arrangement is restored."
	changed.emit()

func reset(solution: bool = false) -> void:
	_cancel_grab()
	if runner == null: return
	_pull_presented_audio()
	if is_editor():
		if solution:
			stop()
			status="Home Toons already shows the authored solution."
			changed.emit()
			return
		# Reset returns to the loaded editor baseline. Drop newly-created factory
		# records too, so the definition and restored runtime keep identical indices.
		runner.puzzle.parts.clear()
		for p in runner.initial_state.parts: runner.puzzle.parts.append(p.definition)
		runner.puzzle.authored_goals = _loaded_goals.duplicate(true)
	audio_reset_requested.emit()
	play_backup = null
	if solution: runner.place_solution()
	else: runner.reset()
	selected_index = -1
	tick_accumulator = 0.0
	changed.emit()

func nuke() -> void:
	# DOS 1000:5D06 removes every unpinned placed object, preserving settings.
	if runner==null or play_backup!=null or runner.state.running: return
	_cancel_grab()
	var removed: Array[int]=[]
	for p in runner.state.parts:
		if p.placed and not p.spawned and not (p.flags&0x8000): removed.append(p.index)
	_return_parts(removed,"Player-placed gadgets returned to inventory.")

func _return_parts(removed: Array[int], message: String) -> void:
	# Flush and Nuke share removal semantics without temporarily pinning every
	# other gadget (which used to alter untouched inventory records too).
	# 1000:5D49 / 2F9C:266A: removing either end also removes its mate.
	for id in removed.duplicate():
		var partner:=_tunnel_partner(id)
		if partner>=0 and not removed.has(partner): removed.append(partner)
	for rope in runner.state.ropes.duplicate():
		var detach:=removed.has(int(rope.owner))
		for id in rope.route: detach=detach or removed.has(int(id))
		if detach:
			RopeEditor.clear_graph(runner.state,rope)
			runner.state.ropes.erase(rope)
			if not removed.has(int(rope.owner)): removed.append(int(rope.owner))
	for belt in runner.state.belts.duplicate():
		if removed.has(int(belt.owner)) or removed.has(int(belt.ends[0])) or removed.has(int(belt.ends[1])):
			for id in belt.ends: runner.state.parts[id].flags08 &= ~2
			runner.state.belts.erase(belt)
			if not removed.has(int(belt.owner)): removed.append(int(belt.owner))
	for id in removed:
		var p:=runner.state.parts[id]
		if p.part_type==46:
			var partner:=_tunnel_partner(id)
			p.target_part=-1
			# DOS frees the second record, retaining one inventory entry per pair.
			# Keep an inactive reusable arena slot so existing indices stay stable.
			if partner>=0:
				runner.state.parts[partner].target_part=-1
				runner.state.parts[partner].active=false
				# If this is the selected end in Flush, it remains the bin owner.
				p.active=true
		p.placed=false
		p.flags=(p.flags&~0xb000)|0x800
		p.chain_override=-1
		runner.world_physics.reactions.insert_chain(runner.state,p,runner.world_physics)
	selected_index=-1
	GearConnections.rebuild(runner.state)
	status=message
	changed.emit()

func _pull_presented_audio() -> void:
	# Reward/UI cues can start after the last physics snapshot. A construction
	# restore retains that process state instead of overwriting it with the old
	# simulation copy. Reference clocks are owned by the differential runner.
	if runner!=null and audio_state_provider.is_valid() and not runner.world_physics.reference_audio_clock.is_valid():
		runner.state.audio.restore(audio_state_provider.call())

func advance(delta: float) -> void:
	if runner == null: return
	if not runner.world_physics.reference_audio_clock.is_valid():
		# The sound driver keeps running between updates and during construction.
		# Physics remains fixed-step; an overloaded update must not freeze audio.
		runner.state.audio.external_clock=true
		runner.state.audio.advance_microseconds(maxi(0,roundi(delta*1000000.0)))
	if not runner.state.running: return
	tick_accumulator += minf(delta, 0.25)
	var interval := 1.0 / preload("res://scripts/audio/audio_playback_state.gd").SIMULATION_HZ
	while tick_accumulator >= interval and runner.state.running:
		tick_accumulator -= interval
		runner.step()
	changed.emit()

func _begin_grab(index: int) -> void:
	if not can_edit_part(index): return
	if runner==null or play_backup!=null or runner.state.running: return
	if index < 0 or index >= runner.state.parts.size(): return
	if grab_active: return
	var p:=runner.state.parts[index]
	if is_editor() and p.flags0a&0x40: return
	selected_index=index
	if not p.definition.is_in_parts_bin() and runner.puzzle.construction_context!="home_toons":
		status="This part is pinned to the level."
		return
	if p.part_type==1:
		belt_editor.begin(runner,index)
		grab_active=true
		status="Belt: choose a free starting attachment. Right-click cancels."
		return
	if p.part_type==14:
		rope_editor.begin(runner,index)
		grab_active=true
		status="Rope: choose a starting attachment. Right-click returns it to inventory."
		return
	grab_backup=runner.state.clone()
	grab_definitions.assign(runner.puzzle.parts)
	if not p.placed and p.part_type in [35,47,48,49,50,51,84]:
		#298D:5D59 clears inventory mirrors;4704 restores factory extents.
		#Keep the serialized solution and cancellation backup untouched.
		p.flip_x=false
		p.flip_y=false
		p.editor_mirror_x=false
		p.editor_mirror_y=false
		p.appearance=0
		if p.part_type!=35:
			var extent: Array=runner.world_physics.data.geometry[str(p.part_type)].factory_extent
			p.width=int(extent[0])
			p.height=int(extent[1])
			p.reaction_data["construction_extent"]=Vector2i(p.width,p.height)
		runner.world_physics.initialize_geometry(p)
		runner.set_native_construction_selector(p.index,p.appearance,"298D:5D59 inventory factory reset")
	grab_index=index
	grab_active=true
	status="Holding %s — left-click to place; right-click to cancel." % type_names.get(p.part_type,"part")

func _cancel_grab() -> void:
	native_grab=false
	placement_invalid=false
	resize_side=""
	if belt_editor.active():
		belt_editor.cancel()

	if rope_editor.active():
		rope_editor.cancel()

	if grab_backup!=null and runner!=null:
		runner.state=grab_backup
		if not grab_definitions.is_empty(): runner.puzzle.parts.assign(grab_definitions)
		if tunnel_pair_first>=0: selected_index=tunnel_pair_first

	grab_backup=null
	grab_definitions.clear()
	tunnel_pair_first=-1
	grab_index=-1
	grab_active=false
	status="Ready — take an inventory item or click a movable part."

func _move_grab(position: Vector2i) -> void:
	if belt_editor.active():
		belt_editor.hover(position)
		status="Belt: "+str(belt_editor.candidate.get("reason","Choose attachment"))

		return
	if rope_editor.active():
		rope_editor.hover(position)
		status="Rope: %s. Right-click cancels." % rope_editor.candidate.get("reason", "Choose an attachment")

		return
	if grab_index<0 or runner==null or play_backup!=null or runner.state.running: return
	if not resize_side.is_empty():
		_resize_native(position)
		return
	if native_grab:
		position=DosRules.drag_position(position,grab_anchor,(runner.state.parts[grab_index].flags0a&8)!=0)
	var current:=runner.transform(grab_index)
	runner.set_transform(grab_index,position,int(current.rotation),bool(current.flip_x),bool(current.flip_y))
	RopeEditor.refresh_connected(runner,grab_index)
	var error:=RopeEditor.movement_error(runner,grab_index)
	if error.is_empty(): error=belt_editor.movement_error(runner.state,grab_index)
	placement_invalid=native_grab and DosRules.blocked(runner,grab_index)
	if placement_invalid: error="This placement overlaps another gadget."
	status=error+" Move elsewhere or right-click to cancel." if not error.is_empty() else "Holding part: click to place; right-click to cancel."

func _take_rope_endpoint(owner: int, side: int) -> void:
	if not can_edit_part(owner): return
	if runner==null or play_backup!=null or runner.state.running or (rope_editor.active() or belt_editor.active()): return
	var source:=runner.state.parts[owner].definition
	if not source.is_in_parts_bin() and runner.puzzle.construction_context!="home_toons":
		status="This rope is pinned to the puzzle."
		return
	for rope in runner.state.ropes:
		if rope.owner==owner:
			rope_editor.detach(runner,rope,side)
			grab_active=true
			status="Rope endpoint taken: choose Pulleys or a new endpoint; right-click returns rope to inventory."

			return

func _on_board_clicked(position: Vector2i) -> void:
	if belt_editor.active():
		var done: bool=belt_editor.click(position)
		grab_active=not done
		status="Belt connected." if done else "Belt: "+str(belt_editor.candidate.get("reason","Choose attachment"))

		return
	if rope_editor.active():
		var done:=rope_editor.click(position)
		grab_active=not done
		status="Rope connected. Click either knot to take its endpoint." if done else "Rope: "+str(rope_editor.candidate.get("reason","Choose next attachment"))

		return
	if grab_index<0: return
	_move_grab(position)
	if placement_invalid: return
	var error:=RopeEditor.movement_error(runner,grab_index)
	if error.is_empty(): error=belt_editor.movement_error(runner.state,grab_index)
	if not error.is_empty():
		status=error+" Placement refused; move elsewhere or right-click."
		return
	if runner.state.parts[grab_index].part_type==46 and _continue_tunnel_pair(position): return
	grab_backup=null
	grab_definitions.clear()
	tunnel_pair_first=-1
	grab_index=-1
	grab_active=false
	native_grab=false
	resize_side=""
	status="Placed — click the item to take it again."

func _tunnel_partner(index: int) -> int:
	if runner==null or index<0 or index>=runner.state.parts.size(): return -1
	var p:=runner.state.parts[index]
	var other:=p.target_part
	if p.part_type!=46 or other<0 or other>=runner.state.parts.size() or other==index: return -1
	var mate:=runner.state.parts[other]
	return other if mate.part_type==46 and mate.active and mate.target_part==index else -1

func inventory_visible(index: int) -> bool:
	var p:=runner.state.parts[index]
	if not p.active or p.spawned or p.definition==null: return false
	# Serialized solutions have two records; the original bin represents a pair
	# with one icon/count, creating its second record after the first drop.
	var other:=_tunnel_partner(index)
	return not (other>=0 and not p.placed and not runner.state.parts[other].placed and other<index)

func _continue_tunnel_pair(pointer: Vector2i) -> bool:
	if tunnel_pair_first>=0: return false
	var first:=runner.state.parts[grab_index]
	var partner:=_tunnel_partner(grab_index)
	if partner>=0 and runner.state.parts[partner].placed: return false # Moving an existing end.
	var partner_goal_id := runner.state.parts[partner].definition.goal_id if partner >= 0 else ""
	tunnel_pair_first=grab_index
	# 2F9C:23E6..2411 clones the just-dropped Tunnel, pairs +B1 both ways,
	# and changes the held selection to the clone. Never steal another pair.
	if partner<0:
		partner=runner.state.parts.size()
		for old in runner.state.parts:
			if old.index!=grab_index and old.part_type==46 and not old.active and not old.placed:
				partner=old.index
				break
	var definition:=PartDefinition.new()
	runner.puzzle.assign_goal_id(definition, partner_goal_id)
	for key in Document.FIELDS: definition.set(key,first.definition.get(key))
	definition.construction_context=runner.puzzle.construction_context
	definition.tunnel_partner=-1
	definition.flags_1=(first.flags&~0x8000)|0x800
	definition.flags_2=first.flags08
	definition.flags_3=first.flags0a&~0x40
	definition.appearance=first.appearance
	definition.width_1=first.width
	definition.height_1=first.height
	definition.list_index=partner
	var mate:=first.copy()
	mate.index=partner
	mate.definition=definition
	mate.list_next=-1
	mate.target_part=first.index
	mate.placed=false
	mate.active=true
	mate.flags=definition.flags_1
	mate.flags0a=definition.flags_3
	if partner==runner.state.parts.size():
		runner.state.parts.append(mate)
		runner.puzzle.parts.append(definition)
	else:
		runner.state.parts[partner]=mate
		# Keep the serialized developer solution unchanged in campaign mode.
		if is_editor(): runner.puzzle.parts[partner]=definition
	first.target_part=partner
	runner.world_physics.reactions.insert_chain(runner.state,mate,runner.world_physics)
	grab_index=partner
	selected_index=partner
	_move_grab(pointer)
	status="Tunnel pair: place the second Tunnel. Right-click cancels both."
	return true

func _rotate_selected() -> void:
	if runner == null or selected_index < 0:
		return
	var current := runner.transform(selected_index)
	_apply_transform(int(current.get("rotation", 0)) + 1, bool(current.get("flip_x", false)), bool(current.get("flip_y", false)))

func _flip_x_selected() -> void:
	if runner == null or selected_index < 0:
		return
	var current := runner.transform(selected_index)
	_apply_transform(int(current.get("rotation", 0)), not bool(current.get("flip_x", false)), bool(current.get("flip_y", false)))

func _flip_y_selected() -> void:
	if runner == null or selected_index < 0:
		return
	var current := runner.transform(selected_index)
	_apply_transform(int(current.get("rotation", 0)), bool(current.get("flip_x", false)), not bool(current.get("flip_y", false)))

func _flip_native_selected(axis: int) -> bool:
	if not can_edit_part(selected_index): return true
	if selected_index>=runner.state.parts.size(): return false
	var p:=runner.state.parts[selected_index]
	if p.part_type not in [3,41,63] or (p.part_type in [3,41] and axis!=1): return false
	if play_backup!=null or runner.state.running or (not p.placed and grab_index<0): return true
	if (is_editor() and p.flags0a&0x40) or (not p.definition.is_in_parts_bin() and not is_editor()):
		status="This part is pinned to the level."
		return true
	var before:=runner.state.clone()
	if not runner.flip_native_construction(selected_index,axis): return true
	RopeEditor.refresh_connected(runner,selected_index)
	var error:=RopeEditor.movement_error(runner,selected_index)
	if error.is_empty(): error=belt_editor.movement_error(runner.state,selected_index)
	if not error.is_empty() and grab_index<0:
		runner.state=before
		status=error+" Transform refused."
	return true

func _apply_transform(rotation: int, flip_x: bool, flip_y: bool) -> void:
	if not can_edit_part(selected_index): return
	if (rope_editor.active() or belt_editor.active()): return
	if runner == null or selected_index < 0 or selected_index >= runner.state.parts.size():
		return
	var part: SimulationState.SimPart = runner.state.parts[selected_index]
	if is_editor() and part.flags0a&0x40: return
	if play_backup!=null or runner.state.running or (not part.placed and grab_index<0): return
	if not part.definition.is_in_parts_bin() and runner.puzzle.construction_context != "home_toons":
		status = "This part is pinned to the level."
		return
	var before:=runner.state.clone()
	runner.set_transform(selected_index, Vector2i(part.x_fixed >> SimulationRunner.FIXED_SHIFT, part.y_fixed >> SimulationRunner.FIXED_SHIFT), rotation, flip_x, flip_y)
	RopeEditor.refresh_connected(runner,selected_index)
	var error:=RopeEditor.movement_error(runner,selected_index)
	if error.is_empty(): error=belt_editor.movement_error(runner.state,selected_index)
	if not error.is_empty() and grab_index<0:
		runner.state=before

		status=error+" Transform refused."
		return

func _take_belt_endpoint(owner: int, side: int) -> void:
	if not can_edit_part(owner): return
	if runner==null or play_backup!=null or runner.state.running or rope_editor.active() or belt_editor.active(): return
	if not runner.state.parts[owner].definition.is_in_parts_bin() and runner.puzzle.construction_context!="home_toons":
		status="This Belt is pinned to the puzzle."
		return
	for belt in runner.state.belts:
		if belt.owner==owner:
			belt_editor.detach(runner,belt,side)
			grab_active=true

			status="Belt endpoint taken. Choose a free attachment; right-click cancels."
			return
