class_name SpecialReactions
extends RefCounted

## Native contact/state/field-effect translations. See PHYSICAL_REACTIONS_ANALYSIS.
const K = preload("res://scripts/simulation/bearing_physics.gd")
const Tables = preload("res://scripts/simulation/reaction_tables.gd")
const Actors = preload("res://scripts/simulation/actor_reactions.gd")
const AudioStatus = preload("res://scripts/simulation/simulation_audio_status.gd")
const NativeState = preload("res://scripts/simulation/native_state_contract.gd")
var tables := Tables.new()
var actors := Actors.new(tables)
var state: SimulationState
var puzzle: PuzzleDefinition
var world # Set only during a step, cleared afterwards (no RefCounted cycle).
var events: Array[Dictionary] = []
var rope_dispatch_stack: Array[int] = []

func begin(definition: PuzzleDefinition, runtime: SimulationState, host, output: Array[Dictionary]) -> void:
	puzzle=definition
	state=runtime
	state.audio.advance_to_tick(state.tick)
	AudioStatus.sync(state)
	world=host
	events=output
	rope_dispatch_stack.clear()
	if state.query_chains.is_empty():
		for p in state.parts: insert_chain(state,p,world)
	for p in state.parts:
		if membership(p) in [0x1000,0x2000]: p.flags08 &= ~0x640
		p.older_appearance=p.previous_appearance
		p.previous_appearance=p.appearance

func finish() -> void:
	world=null
	state=null
	puzzle=null
	events=[]
	rope_dispatch_stack.clear()

func part(index: int):
	return state.parts[index] if state!=null and index>=0 and index<state.parts.size() else null

static func xy(p: SimulationState.SimPart) -> Vector2i:
	return Vector2i(p.x_fixed>>15,p.y_fixed>>15)

static func vx(p: SimulationState.SimPart) -> int: return K.s16(p.vx_fixed>>6)
static func vy(p: SimulationState.SimPart) -> int: return K.s16(p.vy_fixed>>6)
static func set_vx(p: SimulationState.SimPart,v: int) -> void: p.vx_fixed=K.s16(v)<<6
static func set_vy(p: SimulationState.SimPart,v: int) -> void: p.vy_fixed=K.s16(v)<<6
static func position(p: SimulationState.SimPart,v: Vector2i) -> void:
	p.x_fixed=v.x<<15
	p.y_fixed=v.y<<15

func frame_size(p: SimulationState.SimPart) -> Vector2i:
	if world==null: return Vector2i(p.width,p.height)
	return world.frame_geometry(p).size

func shape_rect(p: SimulationState.SimPart) -> Rect2i:
	# +45/+47 and +4D/+4F are current sprite extents from 6212, not
	# min/max vertices of the collision outline. Queries such as Dragon fire
	# and Vacuum must include protruding animation components.
	if world!=null:
		var frame: Rect2i=world.frame_geometry(p)
		return Rect2i(xy(p)+frame.position,frame.size)
	return Rect2i(xy(p),Vector2i(p.width,p.height))

func center(p: SimulationState.SimPart) -> Vector2i:
	return shape_rect(p).get_center()

func event(kind: String,p: SimulationState.SimPart,values: Dictionary={}) -> void:
	var row: Dictionary={"kind":kind,"part_index":p.index,"type":p.part_type,"name":tables.metadata.get("type_names",{}).get(str(p.part_type),"Unknown")}
	row.merge(values,true)
	if kind == "sound_effect":
		if world!=null and world.reference_audio_clock.is_valid() and int(row.get("sound_id",0))>0:
			_advance_reference_audio_clock(String(row.get("action","play")),int(row.sound_id))
		# Dispatch now, before later callbacks can query playback or draw RNG.
		# Runner delivers presentation signals after the world update completes.
		row["audio_clock"] = state.audio.clock
		row["audio_enabled"] = state.audio.enabled
		row["audio_dispatch"] = state.audio.handle_event(row)
		AudioStatus.sync(state)
	events.append(row)

func sound_effect(p: SimulationState.SimPart,sound_id: int,dos_source: String) -> void:
	event("sound_effect",p,{"action":"play","sound_id":sound_id,"dos_source":dos_source,"event_context":_sound_context(p)})

func audio_playing(sound_id: int) -> bool:
	if world!=null and world.reference_audio_clock.is_valid():
		_advance_reference_audio_clock("query",sound_id)
	if world!=null and world.reference_audio_query.is_valid():
		return bool(world.reference_audio_query.call(state.tick,sound_id))
	return AudioStatus.playing(state,sound_id)

func _advance_reference_audio_clock(kind: String,sound_id: int) -> void:
	var time=world.reference_audio_clock.call(kind,sound_id)
	if time is Dictionary: state.audio.advance_elapsed_cycles(int(time.cycles))
	else: state.audio.advance_elapsed_pit(int(time))

func sound_stop(p: SimulationState.SimPart,sound_id: int,dos_source: String) -> void:
	event("sound_effect",p,{"action":"stop","sound_id":sound_id,"dos_source":dos_source,"event_context":_sound_context(p)})

func _sound_context(p: SimulationState.SimPart) -> Dictionary:
	# Runner signals are delivered after the complete world step. Preserve the
	# callback's actual inputs before later animation/consumption changes them.
	return {"captured_at":"sound_request","state":p.state,"appearance":p.appearance,
		"previous_appearance":p.previous_appearance,"reaction_state":p.reaction_state,
		"trigger_state":p.trigger_state,"settings":p.settings,"aux_a5":p.aux_a5,
		"target_part":p.target_part,"scratch61":p.scratch61,"active":p.active,"placed":p.placed,
		"animation_tick":p.animation_tick,"contact_part":p.contact_part,"contact_edge":p.contact_edge,
		"position_px":[p.x_fixed>>15,p.y_fixed>>15],"velocity_q9":[vx(p),vy(p)]}

func sound_loop(p: SimulationState.SimPart,sound_id: int,enabled: bool,dos_source: String) -> void:
	var key: String="audio_loop_%d" % sound_id
	if bool(p.reaction_data.get(key,false))==enabled: return
	p.reaction_data[key]=enabled
	event("sound_effect",p,{"action":"start" if enabled else "stop_loop","sound_id":sound_id,"dos_source":dos_source,"event_context":_sound_context(p)})

func request(p: SimulationState.SimPart,value: int,reason: String,source=null,store: bool=false) -> void:
	var old:=p.trigger_state
	p.trigger_state=K.s16(value)
	p.triggered=value!=0
	if store and source!=null: p.target_part=source.index
	if old!=p.trigger_state or store:
		event("reaction_request",p,{"request":p.trigger_state,"producer":source.index if source!=null else -1,"reason":reason,"state":p.state})

func deactivate(p: SimulationState.SimPart,reason: String,source=null) -> void:
	if not p.active: return
	p.active=false
	p.flags08 |= 0x2000
	var cause := {"reason":reason,"producer":source.index if source!=null else -1}
	if source != null and source.part_type == 75:
		cause.blast_source = source.reaction_data.get("source", -1)
	event("deactivate",p,cause)

func face(p: SimulationState.SimPart,left: bool) -> void:
	p.flip_x=left
	p.flags08=(p.flags08&~0x10)|(0x10 if left else 0)

func freeze(p: SimulationState.SimPart) -> void:
	set_vx(p,0)
	set_vy(p,0)
	p.chain_override=-1
	p.flags=(p.flags&~0x1000)|0x2000
	if state!=null: insert_chain(state,p,world)

func release(p: SimulationState.SimPart) -> void:
	set_vx(p,0)
	set_vy(p,0)
	p.chain_override=-1
	p.flags=(p.flags&~0x6000)|0x1000
	if state!=null: insert_chain(state,p,world)

static func membership(p: SimulationState.SimPart) -> int:
	if p.placed and p.chain_override>=0: return p.chain_override
	return 0x800 if not p.placed else 0x2000 if p.flags&0x6000 else 0x1000 if p.flags&0x1000 else 0

func insert_chain(runtime: SimulationState,p: SimulationState.SimPart,host) -> void:
	# 1000:5AD1 inserts by signed descriptor F4 ascending, then saved
	# +97 Y / +95 X descending. Current flight coordinates do not reorder it.
	for key in runtime.query_chains: runtime.query_chains[key].erase(p.index)
	var key:=membership(p)
	if not runtime.query_chains.has(key): runtime.query_chains[key]=[]
	var chain: Array=runtime.query_chains[key]
	var slot:=chain.size()
	if host!=null and key!=0x800:
		var descriptor=host.kernel.types.descriptor(p.part_type)
		if descriptor!=null:
			for i in chain.size():
				var other: SimulationState.SimPart=runtime.parts[int(chain[i])]
				var other_descriptor=host.kernel.types.descriptor(other.part_type)
				if other_descriptor==null: continue
				var weight: int=K.s16(descriptor.collision_weight)
				var other_weight: int=K.s16(other_descriptor.collision_weight)
				var before: bool=weight<other_weight
				if weight==other_weight:
					before=p.part_type in [14,76] or (i>0 and runtime.parts[int(chain[i-1])].part_type in [14,76]) or other.list_position.y<p.list_position.y or (other.list_position.y==p.list_position.y and other.list_position.x<p.list_position.x)
				if before:
					slot=i
					break
	chain.insert(slot,p.index)
	# Retain actual +00 links, including when the currently executing object
	# migrates between lists. DOS static passes read next AFTER the updater;
	# mover passes save it BEFORE. A whole-list snapshot implements neither.
	for list_key in runtime.query_chains:
		var ordered: Array=runtime.query_chains[list_key]
		for i in ordered.size():
			runtime.parts[int(ordered[i])].list_next=int(ordered[i+1]) if i+1<ordered.size() else -1

func walk_chain(key: int,visitor: Callable,save_next: bool=true) -> void:
	var chain: Array=state.query_chains.get(key,[])
	var index: int=int(chain[0]) if not chain.is_empty() else -1
	while index>=0:
		var p:=state.parts[index]
		var next:=p.list_next
		visitor.call(p)
		index=next if save_next else p.list_next

func enqueue_update(source: SimulationState.SimPart,target: SimulationState.SimPart) -> bool:
	# 8769: descending signed 32-bit +3D; reject equal/weaker requests for
	# the same target. A stronger request adds a node; the old node remains.
	for row in state.pending_updates:
		if int(row.target)==target.index and source.momentum<=int(row.momentum): return false
	var slot:=0
	if not state.pending_updates.is_empty() and source.momentum<=int(state.pending_updates[0].momentum):
		slot=1
		while slot<state.pending_updates.size() and int(state.pending_updates[slot].momentum)>source.momentum: slot+=1
	state.pending_updates.insert(slot,{"target":target.index,"momentum":source.momentum,"serial":state.pending_updates.size()})
	return true

func update_statics() -> void:
	# 20F2 / 8738: consume pending nodes first, then three static phases.
	var row: Dictionary=state.pending_updates[0] if not state.pending_updates.is_empty() else {}
	while not row.is_empty():
		var p=part(int(row.target))
		if p!=null and not p.flags08&0x40: scheduled_update(p,"queued")
		var next:=state.pending_updates.find(row)+1
		row=state.pending_updates[next] if next<state.pending_updates.size() else {}
	state.pending_updates.clear()
	for phase in ["priority","gears","remaining"]:
		walk_chain(0x2000,func(p: SimulationState.SimPart):
			if not p.placed or not p.active: return
			var eligible:=false
			match phase:
				"priority": eligible=p.flags08&0x800!=0 and p.flags08&0x2040==0
				"gears": eligible=p.part_type==18 and p.flags08&0x2040==0
				"remaining": eligible=p.flags08&0x2840==0
			if eligible: scheduled_update(p,phase)
		,false)

func scheduled_update(p: SimulationState.SimPart,phase: String) -> void:
	update_one(p)
	geometry_event(p,phase)

func geometry_event(p: SimulationState.SimPart,phase: String) -> void:
	if world.trace_geometry:
		var shape: Dictionary=world.collider(p.definition,p)
		event("geometry_update",p,{"tick":state.tick,"phase":phase,"appearance":p.appearance,
			"flags06":p.flags,"flags08":p.flags08,"flags0a":p.flags0a,"settings":p.settings,"request":p.trigger_state,
			"offset":[p.frame_offset.x,p.frame_offset.y],"size":[p.frame_size.x,p.frame_size.y],
			"stored_extent":[p.stored_extent.x,p.stored_extent.y],"points":shape.points,
			"point_count":shape.point_count,"support_x":p.frame_offset.x+(p.stored_extent.x>>1),
			"contact":p.contact_part,"edge":p.contact_edge,"angle":p.contact_angle,
			"support_bits":[p.contact_status_8f,p.contact_status_90],"velocity_q9":[vx(p),vy(p)]})

func clamp_velocity(p: SimulationState.SimPart) -> void:
	if world==null or puzzle==null: return
	var limit: int=world.kernel.types.environment(p.part_type,puzzle.pressure,puzzle.gravity).speed_limit_q9
	set_vx(p,clampi(vx(p),-limit,limit))
	set_vy(p,clampi(vy(p),-limit,limit))

func query(source: SimulationState.SimPart,relative: Rect2i,mask: int=0x3000) -> Array[SimulationState.SimPart]:
	var result: Array[SimulationState.SimPart]=[]
	for row in query_details(source,relative,mask): result.append(row.part)
	return result

static func query_delta(origin: Vector2i,r: Rect2i) -> Vector2i:
	# 1000:3303: nearest EDGE, ties choose right/bottom. Interior X is
	# cleared only when dy != 0. Clamping the center into the rect is wrong.
	var dx: int=(r.end.x if absi(origin.x-r.end.x)<=absi(origin.x-r.position.x) else r.position.x)-origin.x
	var dy: int=(r.end.y if absi(origin.y-r.end.y)<=absi(origin.y-r.position.y) else r.position.y)-origin.y
	if r.position.y<origin.y and origin.y<r.end.y: dy=0
	if r.position.x<origin.x and origin.x<r.end.x and dy!=0: dx=0
	return Vector2i(K.s16(dx),K.s16(dy))

func query_details(source: SimulationState.SimPart,relative: Rect2i,mask: int=0x3000) -> Array[Dictionary]:
	# Local records replace +7F/+81/+83: nested queries cannot corrupt a scan.
	var result: Array[Dictionary]=[]
	if state==null: return result
	var box:=Rect2i(xy(source)+relative.position,relative.size)
	var from:=xy(source)+Vector2i(source.width>>1,source.height>>1)
	# 616A/61AC: static chain before movers, keeping order within each chain.
	# Separate linked-list order from IDs; 5AD1 can reorder loaded/spawned parts.
	for chain in [0x2000,0x1000,0x800]:
		if not mask&chain: continue
		var candidates: Array=[]
		if state.query_chains.has(chain):
			for index in state.query_chains[chain]:
				var candidate=part(int(index))
				if candidate!=null: candidates.append(candidate)
		else: candidates.assign(state.parts)
		for candidate: SimulationState.SimPart in candidates:
			if candidate==source or not candidate.active or candidate.flags08&0x2000: continue
			if membership(candidate)!=chain: continue
			var r:=shape_rect(candidate)
			if r.position.x>box.end.x or box.position.x>r.end.x or r.position.y>box.end.y or box.position.y>r.end.y: continue
			var delta:=query_delta(from,r)
			var distance: int=delta.x*delta.x+delta.y*delta.y
			var slot:=result.size()
			for i in result.size():
				if distance<int(result[i].distance_squared):
					slot=i
					break
			result.insert(slot,{"part":candidate,"dx":delta.x,"dy":delta.y,"distance_squared":distance})
	return result

func spawn(type_id: int,where: Vector2i,velocity: Vector2i=Vector2i.ZERO,flip: bool=false,native_flags: int=-1,producer: int=-1):
	if state==null or world==null: return null
	# Only these callers use 32F3:7273. Explosion/Rope factories use47BA;
	# split walls use5F4A. Both routes allocate fresh, without this pool.
	var shared_factory:=type_id in [4,6,21,55] or (type_id==36 and native_flags>=0)
	var p: SimulationState.SimPart
	if shared_factory:
		# 298D:473B searches the actual mover chain, not the parts array or
		# descriptor membership. Its flags are the eligibility predicates.
		for identity in state.query_chains.get(0x1000,[]):
			var candidate: SimulationState.SimPart=state.parts[int(identity)]
			if candidate.part_type==type_id and candidate.flags08&0x2000 and candidate.flags&0x10:
				p=candidate
				break
	var reused:=p!=null
	if reused:
		p.reset_for_reuse()
	else:
		p=SimulationState.SimPart.new()
		p.index=state.parts.size()
	p.part_type=type_id
	p.spawned=true
	# Original factory clears all four near-link fields. Empty portable arrays
	# are not null links: rope endpoint traversal must be able to read either slot.
	p.links.assign([-1,-1,-1,-1])
	p.placed=true
	p.flags=tables.u16(0x620+type_id*16)|0x1010
	if type_id in [4,6,21,55]:
		# 32F3:7273 inserts fresh projectiles and Hen Eggs into the mover list
		# explicitly; descriptor0800 is not replaced with moving bit1000.
		p.flags=tables.u16(0x620+type_id*16)|0x10
		p.chain_override=0x1000
		# Type4 fresh factory retains0400;7273 preserves descriptor/list bits.
		if type_id==4: p.flags|=0x400
	elif type_id==75:
		# 298D:4630 preserves descriptor0800;7887:05C0 adds0010 and
		# explicitly inserts into the static list with5AD1. Static membership
		# does not make this internal effect a fixed object (flags6000).
		p.flags=tables.u16(0x620+type_id*16)|0x10
		p.chain_override=0x2000
	elif type_id==76: p.flags=(p.flags&~0x1800)|0x6000
	p.flags0a=tables.u16(0x622+type_id*16)
	p.flags08=0 if type_id in [4,6] else 0x1000
	# 32F3:7273 only clears3800/adds2000 for a FRESH static allocation.
	# A reusable Al in the mover chain stays there even for caller4000.
	# Al constructor adds0400; the caller subsequently supplies4000.
	if native_flags>=0:
		p.flags=tables.u16(0x620+type_id*16)|native_flags|0x410
		if not reused:
			p.flags=(p.flags&~0x3800)|0x2000
			p.chain_override=0x2000
	if reused: p.chain_override=0x1000
	var source:=PartDefinition.new()
	source.part_type=type_id
	source.list_index=p.index
	source.flags_1=p.flags
	source.flags_2=p.flags08
	source.flags_3=0x40
	source.construction_context="home_toons"
	var metadata: Dictionary=world.data.geometry.get(str(type_id),{})
	var sizes: Array=metadata.get("frame_sizes",[])
	if sizes.is_empty(): sizes=metadata.get("sprite_frame_sizes",[])
	var size_value:=Vector2i(tables.u16(0x624+type_id*16),tables.u16(0x626+type_id*16))
	if size_value==Vector2i.ZERO and not sizes.is_empty(): size_value=Vector2i(int(sizes[0][0]),int(sizes[0][1]))
	source.width_1=maxi(1,size_value.x)
	source.height_1=maxi(1,size_value.y)
	p.width=source.width_1
	p.height=source.height_1
	if type_id in [6,21] or native_flags>=0:
		# 4630 retains descriptor extent; 6212 fills zero logical extents
		# from frame0. Rock is 40x37 logically, with a 36x36 outline/extent.
		if not sizes.is_empty():
			p.width=int(sizes[0][0])
			p.height=int(sizes[0][1])
	p.definition=source
	position(p,where)
	p.previous_position=Vector2i.ZERO if type_id==75 else where
	p.older_position=Vector2i.ZERO if type_id==75 else where
	p.list_position=where
	if shared_factory or type_id==75:
		# 32F3:7273 inserts fresh records before writing flight coordinates.
		# Constructor +95/+97 remain -1 on fresh AND reused shared records;
		# 5AD1 uses those saved coordinates, not the caller's spawn pose.
		# 7887:05C0 likewise inserts an Explosion into the static chain
		# before assigning its position. Keep equal-weight effects in birth
		# order so a chained blast after the current node updates this pass.
		p.list_position=Vector2i(-1,-1)
	set_vx(p,velocity.x)
	set_vy(p,velocity.y)
	face(p,flip)
	if type_id==21:
		# 32F3:7273 applies caller facing AFTER 298D:47BA constructs the
		# Bullet's outline. 61E9 refreshes its frame, not its outline pointer.
		# A fresh left-moving Bullet therefore retains the unmirrored polygon.
		p.reaction_data["outline_flip_x"]=false
	world.initialize_geometry(p)
	# 2839 computes weighted speed from the preceding +3B before resetting
	# it to descriptor weight. Fresh32F3:7273 projectiles/Eggs start with zero +3B.
	if type_id in [4,6,14,21,55,75,76] or native_flags>=0: p.collision_weight=0
	if type_id in [4,21,55,75] or native_flags>=0:
		p.previous_frame_size=Vector2i.ZERO
		p.older_frame_size=Vector2i.ZERO
	if type_id in [14,76]:
		# These factory records have no sprite/body. Retain zero logical/frame
		# extents; a generic one-pixel/dummy30px box is not their native shape.
		p.width=0
		p.height=0
		# Fresh Rope14 retains the constructor's30x30 stored extent even
		# though it has no logical/drawing body. Verified at both CAKE20 cuts.
		p.stored_extent=Vector2i(30,30) if type_id==14 else Vector2i.ZERO
		p.frame_size=Vector2i.ZERO
		p.previous_frame_size=Vector2i.ZERO
		p.older_frame_size=Vector2i.ZERO
		source.width_1=0
		source.height_1=0
	if not reused:
		state.parts.append(p)
		insert_chain(state,p,world)
	var birth := {"position":[where.x,where.y], "velocity_q9":[velocity.x,velocity.y]}
	if producer >= 0: birth.producer = producer
	event("spawn",p,birth)
	return p

func consume(p: SimulationState.SimPart,source=null) -> void:
	if p.part_type==23:
		request(p,1,"Vacuum consumes Balloon",source)
	else:
		p.flags0a |= 0x100
		deactivate(p,"consumed",source)

func explode(p: SimulationState.SimPart,offset: Vector2i=Vector2i(-15,-19),source=null) -> void:
	if not p.active: return
	var effect=spawn(75,xy(p)+offset)
	if effect!=null:
		effect.reaction_data["source"]=p.index
	deactivate(p,"exploded",source)

func initialize(definition: PuzzleDefinition,runtime: SimulationState,host=null) -> void:
	runtime.query_chains.clear()
	runtime.pending_updates.clear()
	for p in runtime.parts:
		p.list_position=xy(p)
		insert_chain(runtime,p,host)
		# Saved +AD is authoritative, including an intentionally empty magazine.
		# Fresh DOS factory defaults (Ratapult/Hen=1, Pistol=6) are applied by
		# the editor, not substituted for a saved zero here.
		if p.part_type in [36,37]: p.trigger_state=-1
		if p.part_type==40 and p.settings==0:
			p.settings=clampi(K.divide(p.height-26,65),0,5)<<4
		if host!=null: host.initialize_geometry(p)
		# Keep all wire references; only validated in-range references participate.
		for i in p.links.size():
			if p.links[i]<0 or p.links[i]>=definition.parts.size(): p.links[i]=-1
		if p.part_type==46 and p.definition!=null:
			var paired:=p.definition.tunnel_partner
			if paired>=0 and paired<runtime.parts.size() and paired!=p.index and runtime.parts[paired].part_type==46:
				p.target_part=paired
				runtime.parts[paired].target_part=p.index

func contact(mover: SimulationState.SimPart,target: SimulationState.SimPart,body,own: bool=false) -> bool:
	var kind:=mover.part_type if own else target.part_type
	if kind in [36,37]:
		var a:=mover if mover.part_type==kind else target
		var other:=target if a==mover else mover
		actors.contact(self,a,other,body)
		return true
	match kind:
		3: return _teeter_contact(mover,target,body)
		13:
			if target.trigger_state!=0 and body.angle==0x8000:
				consume(mover,target)
				return false
		16: _scissors_contact(mover,target,body)
		18: _gear_contact(mover,target,body)
		19:
			if mover.part_type==21: explode(target)
		21:
			if mover.part_type==2: set_vx(target,vx(target)-1)
			elif mover.part_type==19: explode(mover)
			elif mover.part_type==23: request(mover,1,"projectile contact",target)
		22,35,69: request(target,1,"contact",mover)
		24:
			var x:=center(mover).x-xy(target).x
			if body.edge==0 and x>=0 and x<=target.width:
				request(target,1,"Air Mattress impact",mover)
				if absi(vx(mover))>0x3ff: set_vx(mover,vx(mover)>>1)
				mover.flags &= ~1
				mover.contact_part=-1
				body.contact=-1
				set_vy(mover,-absi(vy(mover))-0x400)
				clamp_velocity(mover)
				if mover.part_type in [8,9]: request(mover,1,"Air Mattress impact",target)
				return false
		25: _ant(target)
		39:
			var cx:=xy(mover).x+(mover.width>>1)
			if body.edge in [5,6,7] and vx(mover)>=0 and cx<xy(target).x+5:
				request(target,1,"counter side contact",mover)
			elif body.edge in [1,2,3] and vx(mover)<=0 and xy(target).x+target.width-5<cx:
				request(target,-1,"counter side contact",mover)
		40:
			if target.state==0 and body.edge in [2,0x1c]:
				request(target,1 if ((body.edge==2)!=target.flip_x) else -1,"Thumpulator contact",mover)
		42:
			if body.edge in [2,3]: request(target,1,"Message Machine contact",mover)
		43:
			if body.edge in [6,7] and (vx(mover)<0 if target.flip_x else vx(mover)>0): request(target,1,"Trans-Roto-Matic contact",mover)
		55:
			var egg:=mover if mover.part_type==55 else target
			var other:=target if egg==mover else mover
			if tables.branch("6058:008C",other.part_type)>=0 and vy(egg)>0xa00: request(egg,1,"Egg hard impact",other)
		60:
			var piano:=mover if mover.part_type==60 else target
			var other:=target if piano==mover else mover
			if vy(piano)-vy(other)>0x800 and tables.branch("5F7A:00D3",other.part_type)>=0:
				set_vx(piano,0)
				set_vy(piano,0)
				request(piano,1,"Piano broke",other)
		62:
			var bomb:=mover if mover.part_type==62 else target
			var other:=target if bomb==mover else mover
			if tables.branch("5F95:008C",other.part_type)<0 and absi(vy(bomb))>0xa00: request(bomb,1,"Bombshell impact",other)
		68: _elephant_contact(mover,target)
		77:
			if mover.part_type==36 and absi(center(mover).x-center(target).x)<5:
				request(mover,0x38,"Rug center contact",target)
				request(target,1,"Rug center contact",mover)
		78:
			if body.edge==(0 if target.flip_x else 2): request(target,1,"Trap Door contact",mover)
		80:
			if target.appearance==0 and target.target_part<0 and mover.part_type in [4,5,54,55,56,57,58,59]:
				if body.edge in ([1,2] if target.flip_x else [2,3]):
					target.target_part=mover.index
					set_vx(mover,0)
					set_vy(mover,0)
					request(target,1 if target.flip_x else -1,"Chow-Man accepts food",mover)
		2:
			var on: bool=((body.angle+0x4000)&0x8000)==0
			target.appearance=(target.appearance&3)|(4 if on else 0)
			#7917:0000 compares mutable saved+99, not serialized appearance
			#or run-latched+0C. Socket construction can change0 into1/2/3.
			var fallback: int=target.definition.appearance if target.definition!=null else target.previous_appearance
			var saved: int=NativeState.signed_word(int(target.reaction_data.get(NativeState.SAVED_SELECTOR_KEY,fallback)))
			request(target,int(target.appearance!=saved),"Electric Switch contact",mover)
			if mover.part_type==21: set_vx(mover,vx(mover)-1)
			# 7917:0070 issues this on contact, including an unchanged switch.
			sound_effect(target,3006,"7917:0000")
			return false
	return true

func _ant(p: SimulationState.SimPart) -> void:
	request(p,-1 if p.flip_x else 1,"Cliff Ant activated")
	p.reaction_state=100 # 60DA:0180, update counts rather than milliseconds.

func _elephant_contact(m: SimulationState.SimPart,t: SimulationState.SimPart) -> void:
	if t.trigger_state==5: return
	request(t,3,"Eunice contact",m)
	# 5FE7:00A4 uses logical +41 widths, not animated sprite extents.
	var target_x:=xy(t).x+(t.width>>1)
	var mover_x:=xy(m).x+(m.width>>1)
	if m.part_type==58 and t.state==2:
		request(t,5,"Peanut contact",m,true)
	elif (target_x<mover_x if t.flip_x else mover_x<target_x):
		request(t,1,"Eunice stores contacting object",m,true)
		set_vx(m,0)
		set_vy(m,0)

func _teeter_contact(m: SimulationState.SimPart,t: SimulationState.SimPart,body) -> bool:
	if t.flags08&0x200: return true
	var direction:=0
	if body.edge==2: direction=-1 if t.appearance!=0 else 0
	elif body.edge==6: direction=1 if t.appearance!=2 else 0
	elif body.edge==0:
		var x:=center(m).x-xy(t).x
		if x<37: direction=-1 if t.appearance!=0 else 0
		elif x>=44: direction=1 if t.appearance!=2 else 0
	if direction==0: return true
	if not enqueue_update(m,t): return true
	t.momentum=m.momentum
	request(t,direction,"Teeter-Totter impact",m)
	body.contact=-1
	m.contact_part=-1
	return false

func _gear_contact(m: SimulationState.SimPart,t: SimulationState.SimPart,body) -> void:
	var delta:=t.appearance-t.previous_appearance
	if delta>1: delta=-1
	elif delta< -1: delta=1
	if delta==0: return
	if m.part_type==23:
		request(m,1,"Gears pop Balloon",t)
		return
	var edge: int=(body.edge+4)&7 if delta<0 else body.edge
	# 7939:0000/001A/0038/0052. The negative helper compares to +amount,
	# exactly as in the conveyor callback; do not replace it with a clamp.
	if edge in [0,1,7]: _gear_push(m,true,0x1000 if edge==0 else 0x800,false)
	if edge in [3,4,5]: _gear_push(m,true,0x1000 if edge==4 else 0x800,true)
	if edge in [1,2,3]: _gear_push(m,false,0x1000 if edge==2 else 0x800,false)
	if edge in [5,6,7]: _gear_push(m,false,0x1000 if edge==6 else 0x800,true)

func _gear_push(p: SimulationState.SimPart,horizontal: bool,amount: int,negative: bool) -> void:
	var value:=K.s16((vx(p) if horizontal else vy(p))+(-amount if negative else amount))
	if negative and value<amount: value=-amount
	elif not negative and value>amount: value=amount
	if horizontal: set_vx(p,value)
	else: set_vy(p,value)

func _scissors_contact(m: SimulationState.SimPart,t: SimulationState.SimPart,body) -> void:
	var edge: int=body.edge
	if t.flip_x:
		var count: int=world.data.geometry.get("16",{}).get("point_count",0) if world!=null else 10
		if count-1!=edge: edge=count-edge-2
	if t.appearance!=0: return
	if m.part_type==23 and edge in [6,7,8,9]: request(m,1,"Scissors blade contact",t)
	if m.part_type in [36,37]:
		if (m.state==0x39 if m.part_type==36 else m.state==0x1e) and edge in [0,5,6]: request(t,1,"actor closes Scissors",m)
		elif absi((xy(m).x+(m.width>>1))-(xy(t).x+(t.width>>1)))<8: request(t,1,"actor closes Scissors",m)
	elif edge in [0,5,6]: request(t,1,"Scissors activation edge",m)

func update(group: int = -1) -> void:
	if group in [-1,0]: update_statics()
	if group in [-1,1]:
		walk_chain(0x1000,func(p: SimulationState.SimPart):
			if p.placed and p.active and not p.flags08&0x2000: scheduled_update(p,"mover")
		)

func update_one(p: SimulationState.SimPart) -> void:
	_update_part(p)
	RopePhysics.refresh_anchors(p,tables)
	p.animation_tick=p.reaction_state if p.part_type!=23 else p.state

func _update_part(p: SimulationState.SimPart) -> void:
	match p.part_type:
		36,37: actors.update(self,p)
		30: actors.sight.magnifier(self,p)
		35: _dragon(p)
		23: _balloon(p)
		75: _explosion(p)
		19:
			if p.trigger_state==0 and p.aux_a5>20: request(p,1,"Ball Bomb fuse")
			if p.trigger_state!=0:
				if p.state==0: sound_effect(p,3122,"7901:00AC")
				if p.state==20: explode(p)
				else:
					p.state+=1
					p.appearance=tables.u8(0x454d+p.state)
		62:
			if p.trigger_state!=0:
				sound_stop(p,9,"5F95:00D3")
				explode(p,Vector2i(10,-20))
			elif vy(p)<0x400:
				sound_stop(p,9,"5F95:00D3")
				p.appearance=0
			elif vy(p)<0x600:
				sound_effect(p,9,"5F95:00D3")
				p.appearance=1
			elif vy(p)<0x800: p.appearance=2
			elif vy(p)<0xa00: p.appearance=3
		55,60: _breakable(p)
		22: _ratapult(p)
		69: _hen(p)
		42: _message(p)
		8,9: _talking_ball(p)
		24:
			if p.trigger_state!=0:
				p.state+=1
				# 7A92:00EE reads ES=340F, offset 4C46 (not a DS global).
				p.appearance=tables.u8(0x4c46+p.state)
				if p.state==3: sound_effect(p,3002,"7A92:00D6")
				if p.state==14:
					p.trigger_state=0
					p.appearance=0
					p.state=0
		13: _vacuum(p)
		12: _steam(p)
		52: _dryer(p)
		68: _elephant(p)
		39: _counter(p)
		38: _timer(p)
		40: _thumpulator(p)
		43: _trans_roto(p)
		41: _electro_ramp(p)
		3: _teeter(p)
		16:
			if p.trigger_state!=0:
				if p.appearance==0:
					_cut_ropes(p)
					p.appearance=1
					sound_effect(p,3054,"79F3:015A")
				p.trigger_state=0
		77:
			if p.trigger_state!=0:
				if p.appearance==0:
					p.appearance=1
					release(p)
					position(p,xy(p)+Vector2i(13,-20))
				p.collision_enabled=false
		78: _trap_door(p)
		25:
			# 60DA:00AA transmits the OLD appearance/request, before advancing
			# or expiring the timer (including its final drive pulse).
			if p.appearance>2: _belt_drive(p,p.trigger_state)
			if p.trigger_state!=0:
				p.state+=1
				p.appearance=tables.u8(0x340a+p.state)-1
				if p.state==23:
					sound_effect(p,3003,"60DA:00AA")
					p.state=10
				p.reaction_state-=1
				if p.reaction_state<=0:
					p.trigger_state=0
					p.state=0
					p.appearance=tables.u8(0x340a)-1
		80: _chow_man(p)
		2: _power(p)
		18: _gears(p)
		0:
			p.settings=p.trigger_state
			# 799D:0116 passes literal ID 0; DOS rejects it before playback.
			if p.trigger_state!=0:
				p.appearance=posmod(p.appearance+signi(p.trigger_state),6)
				p.trigger_state=0
		20: _pistol(p)
		44: _bobbin(p)
		53:
			if p.trigger_state!=0:
				p.reaction_state+=1
				if p.reaction_state%3==0:
					p.state=mini(20,p.state+1)
					p.appearance=tables.u8(0x274a+p.state)-1 if p.state<20 else 0
				if p.appearance==4 and p.previous_appearance==3:
					sound_effect(p,3089,"5FD2:0077")
				if p.appearance==4 and p.previous_appearance==7:
					for actor in state.parts:
						if actor.active and actor.placed and actor.part_type in [36,37]: request(actor,0x2c if actor.part_type==36 else 0x13,"Lunch Whistle",p)
		4,21: _projectile(p)

func _dragon(p: SimulationState.SimPart) -> void:
	if p.trigger_state==0: return
	p.reaction_state+=1
	if p.reaction_state%2==0:
		if p.reaction_state<110: p.appearance=tables.u8(0x12bc+(p.reaction_state>>1))-1
		else:
			p.reaction_state=0
			p.appearance=0
			p.trigger_state=0
			p.triggered=false
	# 5CF7:00BC performs all sound tests inside the even-update block.
	# +10 is the previous appearance. Dispatcher argument 1 forces restart;
	# it does not turn the finite 3143 RAW sample into a continuous loop.
	if p.reaction_state%2==0:
		if p.reaction_state==2: sound_effect(p,3031,"5CF7:00BC")
		if p.appearance==4 and p.previous_appearance==3: sound_effect(p,3143,"5CF7:00BC")
		if p.appearance==0 and p.previous_appearance==9: sound_stop(p,3143,"5CF7:00BC")
	if p.reaction_state>24 and p.reaction_state<88:
		var x:=p.width+23 if p.flip_x else -100
		for other in query(p,Rect2i(x,-4,77,24)):
			match other.part_type:
				37: request(other,0x1c,"Dragon fire",p)
				36: request(other,2,"Dragon fire",p)
				68: request(other,3,"Dragon fire",p)
				12,19,23: request(other,1,"Dragon fire",p)

func _balloon(p: SimulationState.SimPart) -> void:
	if p.trigger_state==0: return
	p.flags08|=0x40
	if p.state==4: deactivate(p,"Balloon pop completed")
	else:
		# DOS callback 7855:014F plays 3040 when the balloon's current
		# appearance is frame zero, before advancing the pop animation.
		if p.appearance==0: sound_effect(p,3040,"7855:014F")
		if not p.links.is_empty() and not p.reaction_data.has("tether_replaced"):
			_replace_endpoint(p)
		p.state+=1
		p.appearance=tables.u8(0x4206+p.state)

func _breakable(p: SimulationState.SimPart) -> void:
	if p.trigger_state==0: return
	if p.reaction_state==0:
		if p.part_type==55:
			# DOS callback 6058:00E5 starts the egg-break sample at frame zero.
			sound_effect(p,3067,"6058:00E5")
			set_vx(p,0)
			set_vy(p,0)
		elif p.part_type==60:
			# DOS callback 5F7A:0121 starts the piano sample at frame zero.
			sound_effect(p,3074,"5F7A:0121")
	if p.reaction_state<0: return
	p.reaction_state+=1
	if p.reaction_state%2!=0: return
	var limit:=42 if p.part_type==55 else 14
	if p.reaction_state<limit:
		p.appearance=tables.u8((0x2df0 if p.part_type==55 else 0x2437)+(p.reaction_state>>1))-1
		if p.part_type==60: world.frame_geometry(p) # 5F7A:0186 calls constructor0000.
	elif p.part_type==55: deactivate(p,"Egg break completed")
	else: p.reaction_state=-1

func _talking_ball(p: SimulationState.SimPart) -> void:
	if p.trigger_state!=0:
		sound_effect(p,3086 if p.part_type==8 else 3002,"7821:025D")
		p.state=5
		# 7821:02A6 writes +0E; direction selector +9F is retained.
		p.appearance=p.trigger_state
		p.trigger_state=0
	if p.state>0:
		p.state-=1
		p.appearance=tables.u8((0x41c2 if p.reaction_state==1 else 0x41c7)+p.state)
	else: p.appearance=0

func _message(p: SimulationState.SimPart) -> void:
	if p.trigger_state==0: return
	p.reaction_state+=1
	if p.reaction_state<13:
		p.appearance=tables.u8(0x218a+p.reaction_state)-1
		if p.appearance==3 and p.previous_appearance!=3:
			sound_effect(p,3009,"5F1E:0068")
		world.frame_geometry(p) # 5F1E:0000 reconstructs the knot before sending.
		# 5F1E:0068 sends through the primary Rope on EVERY opening update.
		# Direction uses the preceding completed Rope cache, as769F does.
		_routed_rope_event(p,false,0x40000000)
	else:
		p.reaction_state=13
		p.trigger_state=0

func _ratapult(p: SimulationState.SimPart) -> void:
	if p.trigger_state!=0 and p.reaction_state==0 and p.settings!=0:
		sound_effect(p,3010,"5C57:0092")
		p.reaction_state=1
		p.settings-=1
	if p.reaction_state==0: return
	if p.settings==0 and p.appearance==13:
		p.reaction_state=0
		return
	p.appearance=tables.u8(0xfba+p.reaction_state)-1
	p.reaction_state+=1
	if p.reaction_state==29:
		p.appearance=0
		p.reaction_state=0
	if p.appearance==4:
		spawn(6,xy(p)+Vector2i(p.width-78 if p.flip_x else 42,-54),Vector2i(0xc00 if p.flip_x else -0xc00,-0x1400),p.flip_x)
	p.trigger_state=0

func _hen(p: SimulationState.SimPart) -> void:
	if p.trigger_state==0 and p.aux_a5!=0: p.aux_a5-=1
	if p.trigger_state==0 or p.aux_a5!=0 or p.settings==0: return
	if p.reaction_state==0:
		# 608B:005B draws from the shared DOS RNG once per laying sequence.
		var voice: int=state.next_random()%12
		sound_effect(p,[3026,3025,3062,3035][voice] if voice<4 else 3077,"608B:005B")
	p.reaction_state+=1
	if p.reaction_state%2!=0: return
	if p.reaction_state<34:
		p.appearance=tables.u8(0x3027+(p.reaction_state>>1))-1
		if p.appearance==3 and p.previous_appearance==2: spawn(55,xy(p)+Vector2i(23,35))
	else:
		p.reaction_state=0
		p.trigger_state=0
		p.settings-=1
		p.aux_a5=4

func _projectile(p: SimulationState.SimPart) -> void:
	if p.part_type==21:
		if p.appearance==2: deactivate(p,"type 21 projectile completed")
		elif p.appearance==0:
			if absi(vx(p))!=0x3000:
				# 78F0:00A3 clears +87, retaining the outline pointer. The DOS
				# detector still tests its first edge before checking that count.
				p.reaction_data["outline_count"]=0
				p.appearance=1
		else: p.appearance+=1
	elif p.appearance==0:
		if absi(vx(p))!=0x2000:
			sound_effect(p,3005,"5D1C:0041")
			set_vx(p,0)
			set_vy(p,0)
			p.collision_enabled=false
			p.appearance=1
			p.reaction_state=2
	elif p.appearance in [1,2]:
		p.reaction_state-=1
		if p.reaction_state==0:
			p.appearance+=1
			p.reaction_state=100 if p.appearance==3 else 2
	else:
		if p.reaction_state==0: deactivate(p,"type 4 projectile completed")
		else: p.reaction_state-=1

func _explosion(p: SimulationState.SimPart) -> void:
	if p.state==0:
		# 7887:0000 cycles the three original animation variants on first update.
		state.explosion_variant=(state.explosion_variant+1)%3
		p.aux_a5=state.explosion_variant
		sound_effect(p,[3007,3112,3113][p.aux_a5],"7887:0000")
	if p.state==8:
		deactivate(p,"explosion completed")
		return
	# 7887:0089 reads a far pointer from MAIN DS:1BCC, not animation DS.
	# Those pointers resolve to 340F:4351/4359/4361 in the original EXE.
	# Reading 1BCC from reaction_tables.bin produced appearance -1 and a
	# wrong blast center, changing every Marble's outgoing velocity in HARD4.
	var pointer:=0x4351+(p.aux_a5%3)*8
	p.appearance=tables.u8(pointer+p.state)-1
	p.state+=1
	if p.state!=2: return
	var origin:=center(p)
	var rel:=origin-xy(p)-Vector2i(75,65)
	for row in query_details(p,Rect2i(rel,Vector2i(150,130))):
		var o: SimulationState.SimPart=row.part
		match o.part_type:
			37: request(o,0x1a,"explosion",p)
			36: request(o,2,"explosion",p)
			23,69,78: request(o,1,"explosion",p)
			19: explode(o,Vector2i(-15,-19),p)
			25: _ant(o)
			26,27,28,29,82,83:
				# 7887:0148 tests the query's cached +81/+83 deltas, measured
				# from logical center, not a fresh closest-point-to-blast test.
				if absi(int(row.dx))<80 and absi(int(row.dy))<80: _split_wall(o,p)
			_:
				if o.flags&0x1000:
					var weight: int=world.kernel.types.descriptor(o.part_type).collision_weight
					var power:=_weight_impulse(weight,false)
					var delta:=center(o)-origin
					_radial_impulse(o,delta,power)
					event("explosion_impulse",o,{"producer":p.index,"weight":weight,"power":power})

func _radial_impulse(p: SimulationState.SimPart,delta: Vector2i,power: int) -> void:
	# 3C15 -> 430F:0008 -> 7ADF. The force helper writes sine to vx
	# and cosine to vy (angle zero points down), unlike the solver rotation.
	var angle: int=world.kernel.direction(delta.x,delta.y)
	set_vx(p,(power*world.kernel.sine(angle))>>14)
	set_vy(p,(power*world.kernel.cosine(angle))>>14)
	clamp_velocity(p)

static func _weight_impulse(weight: int,teeter: bool) -> int:
	var bands: Array=[2,6,10,21,121,151] if teeter else [2,6,10,21,121,151,201,1801]
	var values: Array=[0x1c00,0x1a00,0x1800,0x1600,0x1400,0x1200,0x1000] if teeter else [0x1800,0x1600,0x1400,0x1200,0x1000,0xe00,0xc00,0xa00,0x800]
	for i in bands.size():
		if weight<int(bands[i]): return int(values[i])
	return int(values.back())

func _split_wall(w: SimulationState.SimPart,blast: SimulationState.SimPart) -> void:
	# 7887:027B subtracts DS:4709/4707 BEFORE aligning to16. In the
	# original playfield, wall grid coordinates are x=5 mod16,y=8 mod16.
	var origin:=state.dos_view_origin
	var at:=center(blast)-origin
	var r:=Rect2i(xy(w)-origin,frame_size(w))
	var horizontal:=r.size.y<r.size.x
	var start: int=r.position.x if horizontal else r.position.y
	var length: int=r.size.x if horizontal else r.size.y
	var middle: int=at.x if horizontal else at.y
	var lo: int=K.s16((middle-64)&0xfff0)
	var hi: int=K.s16((middle+64)&0xfff0)
	var distance: int=absi(r.position.y+8-at.y) if horizontal else absi(r.position.x+8-at.x)
	if distance>48:
		lo+=32
		hi-=32
	var extent:=length
	if start<lo:
		if hi<start+length:
			var right:=start+length-hi
			if right>16:
				# The original keeps the left allocation even when it becomes
				# hidden, and clones the right remainder independently.
				var split=spawn(w.part_type,xy(w),Vector2i.ZERO,w.flip_x)
				if split==null: return
				split.flags=w.flags|0x10
				split.flags08=w.flags08
				split.flags0a=w.flags0a
				split.appearance=w.appearance
				split.width=r.size.x
				split.height=r.size.y
				split.stored_extent=w.stored_extent
				right=maxi(32,right)
				var at_right:=start+length-right
				position(split,Vector2i(at_right+origin.x,xy(w).y) if horizontal else Vector2i(xy(w).x,at_right+origin.y))
				_wall_extent(split,horizontal,right)
				# 5F4A calloc/selective copy leaves +95/+97 zero, unlike
				# 4630 shared factories (-1). 7887 inserts by these saved
				# words, never by the source or remainder pixel position.
				split.list_position=Vector2i.ZERO
				insert_chain(state,split,world)
			extent=lo-start
		elif lo<start+length: extent=lo-start
	elif hi<start+length:
		if start>=hi: return
		extent=start+length-hi
		# A17..31px right remainder expands inward from this cut boundary;
		# it is not pinned back to the old far edge (except for a new clone).
		position(w,Vector2i(hi+origin.x,xy(w).y) if horizontal else Vector2i(xy(w).x,hi+origin.y))
	elif start<hi and lo<start+length:
		deactivate(w,"wall destroyed by explosion",blast)
		return
	else: return
	if extent<17: deactivate(w,"wall destroyed by explosion",blast)
	_wall_extent(w,horizontal,extent if extent<17 else maxi(32,extent))
	w.reaction_data["wall_split"]=true
	event("wall_split",w,{"producer":blast.index,"width":w.width,"height":w.height})

func _wall_extent(w: SimulationState.SimPart,horizontal: bool,extent: int) -> void:
	if horizontal: w.width=extent
	else: w.height=extent
	w.reaction_data["wall_frame_extent"]=Vector2i(w.width,w.height)
	world.resize_geometry(w)
	world.frame_geometry(w)

func activate(source: SimulationState.SimPart,target: SimulationState.SimPart) -> void:
	# 32F3:73F0: mechanism-output activation is distinct from contact dispatch.
	match target.part_type:
		22,35,69: request(target,1,"mechanism output",source)
		25: _ant(target)
		68: request(target,3,"mechanism output",source)
		16:
			if (xy(source).x<xy(target).x and target.flip_x) or (xy(source).x>=xy(target).x and not target.flip_x): request(target,1,"mechanism closes Scissors",source)
		39:
			var direction:=1 if center(source).x<center(target).x else -1
			request(target,direction,"mechanism counter activation",source)
		43: request(target,1,"mechanism output",source)
		78: request(target,1,"mechanism output",source)

func _output(source: SimulationState.SimPart,rect: Rect2i,impulse: int) -> void:
	for other in query(source,rect):
		if other.flags&0x1000:
			set_vx(other,vx(other)+impulse)
			clamp_velocity(other)
			event("mechanism_impulse",other,{"producer":source.index,"vx_q9":vx(other)})
		else: activate(source,other)

func _dryer(p: SimulationState.SimPart) -> void:
	if p.trigger_state==0:
		p.state=0
		p.appearance=0
		return
	p.appearance=tables.u8(0x2588+p.state)-1
	p.state=(p.state+1)%3
	p.trigger_state=0
	for o in query(p,Rect2i(-120 if p.flip_x else frame_size(p).x,0,120,30)):
		if not o.flags&0x1000:
			if o.part_type==12: request(o,1,"Hair-Dryer airflow",p)
			elif o.part_type==25: _ant(o)
			elif o.part_type==68: request(o,3,"Hair-Dryer airflow",p)
			continue
		var old:=vx(o)
		set_vx(o,old+(-0x400 if p.flip_x else 0x400))
		clamp_velocity(o)
		if o.part_type==36:
			# 5FAC:0087: Al faces the nozzle. Restore his incoming VX even
			# when falling too fast to enter the inflation reaction.
			if absi(vy(o))<0x400:
				face(o,xy(o).x>=xy(p).x)
				request(o,0x33,"Hair-Dryer actor reaction",p,true)
			set_vx(o,old)
		elif o.part_type==37 and absi(vy(o))<0x400:
			face(o,xy(p).x>=xy(o).x)
			request(o,0x1d,"Hair-Dryer actor reaction",p,true)
			set_vx(o,old)

func _steam(p: SimulationState.SimPart) -> void:
	var activated:=p.trigger_state!=0
	if p.trigger_state==0:
		if p.appearance<6 and p.aux_a5!=0:
			p.aux_a5-=1
			p.appearance=tables.u8(0x4a9e+p.aux_a5)-1
	else:
		if p.appearance<6:
			p.appearance=tables.u8(0x4a9e+p.aux_a5)-1
			p.aux_a5+=1
			p.trigger_state=0
	if activated and p.appearance==4 and p.previous_appearance==3:
		sound_effect(p,3114,"7A5D:00A4")
	if p.appearance<=5 or p.aux_a5>=92:
		return
	p.appearance=tables.u8(0x4a9e+p.aux_a5)-1
	p.aux_a5+=1
	if p.aux_a5==92:
		p.appearance=0
		p.trigger_state=0
		p.aux_a5=0
	# The continuing steam path dispatches ID 0, not packed bank ID 4.
	var x:=p.width-97 if p.flip_x else 50
	for o in query(p,Rect2i(x,-16,47,45)):
		if not o.flags&0x1000:
			if o.part_type==12: request(o,1,"steam",p)
			elif o.part_type==25: _ant(o)
			elif o.part_type==68: request(o,3,"steam",p)
			continue
		if o.part_type in [36,37]:
			face(o,xy(o).x<xy(p).x if o.part_type==36 else xy(p).x>=xy(o).x)
			request(o,0x2b if o.part_type==36 else 0x1d,"steam actor reaction",p)
			if o.part_type==36: set_vy(o,-0x600)
		if not p.flip_x and vx(o)<0x600: set_vx(o,vx(o)+0x400)
		elif p.flip_x and vx(o)>-0x600: set_vx(o,vx(o)-0x400)
		if vy(o)>-0x600: set_vy(o,vy(o)-0x400)
		clamp_velocity(o)

func _vacuum(p: SimulationState.SimPart) -> void:
	# 7AA6:00B1 passes literal ID 0 for both playback and stop.
	if p.trigger_state==0:
		if p.state!=0:
			if p.state<7:
				p.state+=1
				p.appearance=tables.u8(0x4d12+p.state)
			else:
				p.appearance=0
				p.state=0
		return
	p.state+=1
	if p.state==8: p.state-=4
	p.appearance=tables.u8(0x4d12+p.state)
	var nozzle:=Vector2i(xy(p).x+(26 if p.flip_x else 76),xy(p).y+p.height)
	for o in query(p,Rect2i(nozzle-xy(p)-Vector2i(25,0),Vector2i(50,100)),0x1000):
		var cx:=xy(o).x+(o.width>>1)
		o.flags&=~1
		if xy(o).y<nozzle.y+3 and cx>nozzle.x-25 and cx<nozzle.x+25: consume(o,p)
		if vy(o)>-0x400: set_vy(o,maxi(-0x400,vy(o)-0x400))
		if cx<nozzle.x-4 and vx(o)<0x200: set_vx(o,mini(0x200,vx(o)+0x200))
		if cx>nozzle.x+4 and vx(o)>-0x200: set_vx(o,maxi(-0x200,vx(o)-0x200))
		if o.part_type==36:
			set_vy(o,vy(o)+0x400)
			if cx>nozzle.x-40 and cx<nozzle.x+40:
				request(o,0x26,"Vacuum actor pull",p)
				if tables.branch("7AA6:028F",o.state)==0x293:
					set_vx(o,0)
					set_vy(o,vy(o)+0x400)
					request(o,0x27,"Vacuum actor capture",p)
				elif absi(cx-nozzle.x)<8:
					request(o,0x28,"Vacuum center",p)
					set_vy(o,vy(o)-0x400)
				else: set_vy(o,vy(o)+0x400)
		elif o.part_type==37:
			var value:=0x2a
			if o.state==0x2b: value=0x2b
			elif absi(cx-nozzle.x)<8: value=0x2b if xy(o).y-nozzle.y>=51 and xy(o).y-nozzle.y<=83 else 0x2c
			request(o,value,"Vacuum actor pull",p)
			if value!=0x2c: set_vy(o,vy(o)+0x400)
		clamp_velocity(o)

func _elephant(p: SimulationState.SimPart) -> void:
	if p.settings!=0:
		p.settings=p.settings-1 if p.trigger_state==0 else mini(5,p.settings+1)
	if p.state==0:
		if p.trigger_state in [1,3]:
			if p.settings==0 or p.trigger_state==1:
				p.state=p.trigger_state
				p.reaction_state=0
				_elephant(p)
			p.settings=5
		elif actors.sight.elephant_acquire(self,p):
			_elephant(p)
		p.trigger_state=0
		return
	var old_phase:=p.aux_a5
	p.aux_a5+=1
	if old_phase%2!=0:
		# 5FE7:0126 checks Peanut contact outside the half-rate animation.
		_elephant_eat_request(p,p.state==2)
		p.trigger_state=0
		return
	var value:=p.state
	var first_frame:=p.reaction_state==0
	if first_frame:
		match value:
			1: sound_effect(p,3010,"5FE7:0126")
			4: sound_effect(p,3118,"5FE7:0126")
			5: sound_effect(p,3073,"5FE7:0126")
	var bases: Dictionary={1:0x2abf,2:0x2ac7,3:0x2adc,4:0x2afb,5:0x2b23}
	var limits: Dictionary={1:8,2:21,3:31,4:40,5:11}
	if not bases.has(value):
		p.trigger_state=0
		return
	p.appearance=tables.u8(int(bases[value])+p.reaction_state)-1
	if value==3 and p.appearance==10 and p.previous_appearance==9:
		# 5FE7:0126 dispatches the elephant call on the 09h -> 0Ah frame edge.
		sound_effect(p,3045,"5FE7:0126")
	p.reaction_state+=1
	if p.reaction_state==int(limits[value]):
		p.appearance=0
		p.state=0
	var target=part(p.target_part)
	if value==1 and target!=null and p.appearance==2:
		var sign_value: int=-1 if p.flip_x else 1
		if xy(p).y+(p.height>>1)<xy(target).y+(target.height>>1): sign_value=-sign_value
		set_vx(target,sign_value*0x600)
		set_vy(target,-0x1800)
		clamp_velocity(target)
		p.target_part=-1
		event("Eunice_launch",p,{"target":target.index})
	elif value==2 and p.appearance in [6,7]:
		for o in query(p,Rect2i(frame_size(p).x if p.flip_x else -200,0,200,frame_size(p).y),0x1000):
			set_vx(o,vx(o)+(-0x400 if p.flip_x else 0x400))
			set_vy(o,vy(o)+(0x400 if xy(o).y<xy(p).y+30 else -0x800))
			clamp_velocity(o)
	elif value==3 and p.reaction_state>5 and p.reaction_state<16:
		for o in query(p,Rect2i(p.width+8 if p.flip_x else -66,21,58,43),0x1000):
			set_vx(o,vx(o)+(0x400 if p.flip_x else -0x400))
			clamp_velocity(o)
	elif value==5 and target!=null and target.part_type==58:
		deactivate(target,"Eunice consumed Peanut",p)
		p.target_part=-1
	_elephant_eat_request(p,value==2)
	p.trigger_state=0

func _elephant_eat_request(p: SimulationState.SimPart,suction: bool) -> void:
	if p.trigger_state==5 and suction:
		p.state=5
		p.reaction_state=0
		# DOS immediately calls its update again, including the phase advance.
		_elephant(p)

func _counter(p: SimulationState.SimPart) -> void:
	if p.aux_a5==0 and p.trigger_state!=0 and p.scratch61>2: p.reaction_state=p.trigger_state
	p.scratch61=p.scratch61+1 if p.trigger_state==0 else 0
	if p.reaction_state==0: return
	if p.aux_a5==0: sound_effect(p,3017,"5DB1:0101")
	var delta:=signi(p.reaction_state)
	var offsets: Array=world.data.geometry.get(str(p.part_type),{}).get("frame_offsets",[])
	var offset:=Vector2i.ZERO
	if p.appearance>=0 and p.appearance<offsets.size(): offset=Vector2i(int(offsets[p.appearance][0]),int(offsets[p.appearance][1]))
	var push_x:=offset.x-tables.s16(0x1b34)-tables.s16(0x1b38) if delta<0 else offset.x+shape_rect(p).size.x+tables.s16(0x1b34)
	p.appearance=tables.u8((0x1b29 if delta<0 else 0x1b1e)+p.aux_a5)-1
	p.aux_a5+=1
	if p.aux_a5==5:
		var old:=p.settings
		if p.settings&0x4000 and delta>0: p.settings=K.s16(K.s16((p.settings&~0x4000)-1)|0x4000)
		else: p.settings=K.s16(p.settings+(delta if not p.settings&0x4000 else -delta))
		if p.settings<0: p.settings&=0x4063
		if (p.settings&255)>99: p.settings&=0x4000
		event("counter_value",p,{"from":old,"value":p.settings&255,"setting":p.settings})
	if p.aux_a5==11:
		p.trigger_state=0
		p.reaction_state=0
		p.aux_a5=0
	if p.appearance>=0 and p.appearance<offsets.size(): offset.y=int(offsets[p.appearance][1])
	_output(p,Rect2i(Vector2i(push_x,offset.y+tables.s16(0x1b36)),Vector2i(tables.s16(0x1b38),tables.u16(0x1b3a))),delta*0x1000)

func _timer(p: SimulationState.SimPart) -> void:
	if p.trigger_state!=0 and p.appearance<=12:
		sound_effect(p,15,"5D67:00D7")
		p.trigger_state=0
		p.reaction_state+=1
		if p.reaction_state%64==0 and p.settings&255: p.settings-=1
		if p.settings&255==0:
			p.appearance=13
			p.reaction_state=-1
		if p.reaction_state%4==0: p.settings^=0xf000
	elif p.settings&0xf000:
		sound_stop(p,15,"5D67:00D7")
		p.settings^=0xf000
	WorldPhysics.refresh_timer(p)
	if p.appearance>12 and p.appearance<16:
		# 5D67:00D7 always stops the ticking cue throughout expiration,
		# including the update that depleted the low-byte countdown.
		sound_stop(p,15,"5D67:00D7")
		sound_effect(p,3009,"5D67:00D7")
		p.reaction_state+=1
		if p.reaction_state%2==0: p.appearance+=1
		var rect:=shape_rect(p)
		# 5D67:01CF uses previous width+51, but CURRENT offset+45
		# and height+4F. Current width adds a spurious impulse as the
		# Timer grows (HARD10 update220). The flipped branch uses offset.
		_output(p,Rect2i(rect.position-xy(p)+Vector2i(0 if p.flip_x else p.previous_frame_size.x-1,0),Vector2i(1,rect.size.y)),-0x1000 if p.flip_x else 0x1000)

func _thumpulator(p: SimulationState.SimPart) -> void:
	var count: int=(p.settings&0xf0)>>4
	var level: int=p.settings&15
	if p.state==0:
		if p.trigger_state!=0 and p.reaction_state==0:
			sound_effect(p,3088,"5E33:0349")
			p.settings=(p.settings&~0x300)|(0x200 if p.trigger_state<0 else 0x100)
			p.state=1 if (p.settings&0x1c00)!=0 else 5
			# 5E33:0349: first extension starts at phase 5 and presses
			# the upper button even when the initiating hit was on the bottom.
			# Native OR preserves that lower-button press until section change.
			if p.state==5: p.settings|=0x100
		if p.reaction_state!=0: p.reaction_state+=1 if p.trigger_state!=0 else -1
		p.trigger_state=0
	else:
		p.state+=1
		var b:=tables.u8((0x1e3d if p.state<5 else 0x1e31)+p.state)
		p.settings=(p.settings&~0x1c00)|(b<<10)
		if p.state==5:
			if p.settings&0x100: level=0 if level+1==count else level+1
			else: level=(count if level==0 else level)-1
			# 5E33:0349: moving to another section releases both buttons.
			p.settings=(p.settings&~0x30f)|(level&15)
		if p.state>4:
			var offset:=tables.u8(0x1e42+b)
			var x:=p.width-offset if p.flip_x else offset
			_output(p,Rect2i(x,level*65+55,4,15),-0x800 if p.flip_x else 0x800)
		if p.state==11:
			p.state=0
			p.trigger_state=0
			p.reaction_state=4

func _trans_roto(p: SimulationState.SimPart) -> void:
	if p.trigger_state==0: return
	p.reaction_state+=1
	if p.reaction_state<8:
		p.appearance=tables.u8(0x2017+p.reaction_state)-1
		# 5EDC:0000 -> 533D refreshes this Rope's coordinates BEFORE the
		# outgoing event, unlike the Bobbin constructor's post-event refresh.
		RopePhysics.refresh_anchors(p,tables)
		for rope in state.ropes:
			if rope.route[0]==p.index or rope.route.back()==p.index:
				RopePhysics.refresh_event_points(state,rope)
		var frame:=shape_rect(p)
		if p.appearance<5:
			var offset: int=(frame.position.x if p.flip_x else frame.end.x)-xy(p).x
			_output(p,Rect2i(offset,0,1,15),-0x800 if p.flip_x else 0x800)
			var receiver=BeltConnections.opposite(state,p)
			if receiver!=null:
				# The explicit stop clears even a receiver masked with0800h.
				if p.appearance==4: request(receiver,0,"Trans-Roto-Matic Belt stop",p)
				elif not receiver.flags08&0x800: request(receiver,-1 if p.flip_x else 1,"Trans-Roto-Matic Belt pulse",p)
		_routed_rope_event(p,true,absi(p.momentum))
	else:
		p.reaction_state=0
		p.trigger_state=0
		p.appearance=0

func _electro_ramp(p: SimulationState.SimPart) -> void:
	if p.reaction_state==0:
		for o in query(p,Rect2i(48,p.height,49,48),0x1000):
			if vx(o)!=0:
				sound_effect(p,3123,"5D96:0098")
				p.reaction_state=45
				p.state=0
				p.aux_a5=1 if p.appearance==0 else -1
				break
	else:
		p.reaction_state-=1
		if p.aux_a5!=0:
			p.appearance=tables.u8((0x1800 if p.aux_a5<0 else 0x17fd)+p.state)-1
			p.state+=1
			if p.state==3: p.aux_a5=0

func _teeter(p: SimulationState.SimPart) -> void:
	if p.trigger_state==0: return
	p.flags08|=0x40
	var direction:=p.trigger_state
	# 5C75:01D0/05F5: test the routed endpoint, then commit once, before
	# changing the frame. Probe requests never pull a Pistol trigger.
	if not p.flags08&0x400:
		if _teeter_rope(p,true):
			p.flags08|=0x200
			p.trigger_state=0
			p.momentum=0
			return
		_teeter_rope(p,false)
	p.appearance=clampi(p.appearance+direction,0,2)
	# 5C75:01D0 sounds when leaving either end position, before applying
	# the impulse to objects balanced on the board.
	if p.appearance!=p.previous_appearance and p.previous_appearance in [0,2]:
		sound_effect(p,3082,"5C75:01D0")
	RopePhysics.refresh_anchors(p,tables)
	var middle:=center(p).x
	var affected: Array=_teeter_line_query(p) if p.appearance!=p.previous_appearance else []
	for o: SimulationState.SimPart in affected:
		if o.flags&0x2000: activate(p,o)
		else:
			# 5C75:01D0 tests only static bit2000, not mover bit1000.
			# Fresh factory Eggs/projectiles can be on the mover list with0810.
			var weight: int=world.kernel.types.descriptor(o.part_type).collision_weight
			var power:=_weight_impulse(weight,true)
			set_vx(o,(-1 if center(o).x<middle else 1)*(power>>2))
			set_vy(o,power*(-1 if ((center(o).x<middle)==(direction==1)) else 1))
			clamp_velocity(o)
			world.teeter_reposition(o,p,state)
	p.trigger_state=0
	p.momentum=0

func _teeter_line_query(source: SimulationState.SimPart) -> Array[SimulationState.SimPart]:
	# 1000:362A tests candidate OUTLINE EDGES against this segment, not a
	# broad rectangular neighborhood. 5C75's DS:064A table follows its knots
	# in the original EXE at4D03Ah (same overlay data provenance).
	const LINES=[[0,32,79,3],[0,17,79,17],[0,3,79,32]]
	var line: Array=LINES[clampi(source.appearance,0,2)]
	var result: Array[SimulationState.SimPart]=[]
	if world==null: return result
	var transform=preload("res://scripts/simulation/part_transform.gd")
	var a: Vector2i=transform.point(Vector2i(line[0],line[1]),Vector2i(source.width,source.height),source.rotation,source.editor_mirror_x,source.editor_mirror_y)
	var b: Vector2i=transform.point(Vector2i(line[2],line[3]),Vector2i(source.width,source.height),source.rotation,source.editor_mirror_x,source.editor_mirror_y)
	line=[a.x,a.y,b.x,b.y]
	for chain in [0x2000,0x1000]:
		for id in state.query_chains.get(chain,[]):
			var candidate:=state.parts[int(id)]
			if candidate==source or not candidate.active or not candidate.placed: continue
			var shape: Dictionary=world.collider(candidate.definition,candidate)
			var points: Array=shape.points
			if points.is_empty(): continue
			var offset:=xy(candidate)-xy(source)
			var count: int=maxi(1,int(shape.point_count))
			for edge in count:
				var end: int=1 if edge==0 and points.size()>1 else ((edge+1)%count)
				if edge>=points.size() or end>=points.size(): break
				var segment: Array=[int(points[edge][0])+offset.x,int(points[edge][1])+offset.y,int(points[end][0])+offset.x,int(points[end][1])+offset.y]
				if K.intersection(line,segment).ok:
					result.push_front(candidate)
					break
	return result

func _teeter_rope(p: SimulationState.SimPart,probe: bool,initiator=null,force: int=-1) -> bool:
	if p.flags08&0x200: return true
	for rope in state.ropes:
		var route: Array=rope.route
		var side:=0 if route[0]==p.index else (1 if route.back()==p.index else -1)
		if side<0: continue
		var receiver=part(int(route.back() if side==0 else route[0]))
		if receiver==null or receiver==initiator or not receiver.active or not receiver.placed: continue
		var downward: bool=(int(rope.slots[side])!=0)==(p.trigger_state>0)
		var bits:=RopePhysics.direction_bits(state,rope,side,downward)
		if _rope_receive(p,receiver,bits | (0x8000 if probe else 0),int(rope.slots[1-side]),p.momentum if force<0 else force):
			return true
	return false

func _trap_door(p: SimulationState.SimPart) -> void:
	if p.trigger_state!=0 and p.state==0:
		sound_effect(p,3082,"60A6:0137")
		p.state=9 if p.trigger_state<1 else 1
	if p.state==0: return
	var s:=p.state
	p.appearance=tables.u8((0x3256 if s>=9 else 0x3266)+s)-1
	if s!=8 and s!=16:
		p.reaction_data["constructed_appearance"]=p.appearance
		world.frame_geometry(p) # 60A6 constructor runs only on nonterminal frames.
		p.state+=1
		var anchor := Vector2i(tables.s8(0x3241+p.appearance*2),tables.s8(0x3242+p.appearance*2))
		if p.flip_x: anchor.x=p.width-anchor.x
		var points: Array=RopePhysics.anchors(p).duplicate()
		points[0]=anchor
		p.reaction_data["rope_anchors"]=points
	# 60A6:0137 sends a reciprocal routed event using cached coordinates,
	# then consumes the accumulated impact momentum.
	_routed_rope_event(p,true,absi(p.momentum))
	p.momentum=0

func _chow_man(p: SimulationState.SimPart) -> void:
	# 60F6:0142 sends the current request before advancing the animation.
	if p.appearance>4:
		sound_effect(p,3041,"60F6:0142")
		_belt_drive(p,p.trigger_state)
	if p.trigger_state==0: return
	var food=part(p.target_part)
	if food!=null:
		set_vx(food,0)
		set_vy(food,0)
		if p.appearance==1:
			sound_effect(p,3104,"60F6:0142")
			deactivate(food,"Chow-Man consumed food",p)
			p.target_part=-1
	p.state+=1
	p.appearance=tables.u8(0x3774+p.state)-1
	if p.state>123:
		p.state=0
		p.trigger_state=0
		p.appearance=tables.u8(0x3774)-1

func _pistol(p: SimulationState.SimPart) -> void:
	if p.trigger_state==0 or p.settings==0 or p.state>=18: return
	p.state+=1
	p.appearance=tables.u8(0x47f1+p.state)-1
	if p.state==18:
		p.state=0
		p.trigger_state=0
		p.appearance=0
		p.settings-=1
	elif p.state==12:
		spawn(21,xy(p)+Vector2i(5 if p.flip_x else 35,7),Vector2i(-0x3000 if p.flip_x else 0x3000,0),p.flip_x,-1,p.index)
	if p.state==1: sound_effect(p,3008,"7977:00BA")

func _power(p: SimulationState.SimPart) -> void:
	p.flags08|=0x40
	for i in range(2,mini(4,p.links.size())):
		var receiver=part(p.links[i])
		if receiver!=null and receiver.active and receiver.placed: request(receiver,p.trigger_state,"outlet power",p)

func _belt_drive(p: SimulationState.SimPart,value: int) -> void:
	var receiver = BeltConnections.opposite(state,p)
	if receiver != null and not receiver.flags08 & 0x800:
		request(receiver,value,"belt drive",p)

func _gear_neighbor(p: SimulationState.SimPart,slot: int):
	var receiver=part(p.links[slot]) if slot<4 else BeltConnections.opposite(state,p)
	return receiver if receiver!=null and receiver.active and receiver.placed else null

func _gears(p: SimulationState.SimPart) -> void:
	# 7939:021E -> 027F (assign/check component), then 0347 (consume).
	if p.trigger_state==0: return
	p.flags08|=0x40
	var conflict:=false
	for slot in 4:
		var receiver=_gear_neighbor(p,slot)
		if receiver!=null: conflict=_gear_propagate(p,receiver,false,conflict)
	if conflict: p.trigger_state=0
	_gear_finish(p,conflict)

func _gear_propagate(source: SimulationState.SimPart,target: SimulationState.SimPart,belt: bool,conflict: bool) -> bool:
	if target.trigger_state==0:
		request(target,source.trigger_state if belt else -source.trigger_state,"Gear Belt drive" if belt else "touching Gears",source)
	elif (target.trigger_state!=source.trigger_state if belt else target.trigger_state==source.trigger_state):
		conflict=true
	if target.part_type==18 and not target.flags08&0x40:
		target.flags08|=0x40
		for slot in 5:
			var receiver=_gear_neighbor(target,slot)
			if receiver!=null and not receiver.flags08&0x800:
				conflict=_gear_propagate(target,receiver,slot==4,conflict)
	return conflict

func _gear_finish(p: SimulationState.SimPart,conflict: bool) -> void:
	p.appearance+=p.trigger_state
	if p.appearance== -1: p.appearance=3
	elif p.appearance==4: p.appearance=0
	p.trigger_state=0
	p.triggered=false
	for slot in 5:
		var receiver=_gear_neighbor(p,slot)
		if receiver==null or receiver.trigger_state==0 or receiver.flags08&0x800: continue
		if conflict:
			receiver.trigger_state=0
			receiver.triggered=false
		if receiver.part_type==18: _gear_finish(receiver,conflict)

func _bobbin(p: SimulationState.SimPart) -> void:
	# 5E0E:011D: motion table is a direction selector, not an event mask.
	if p.trigger_state==0: return
	p.reaction_state=K.s16(p.reaction_state+1)
	var even:=p.reaction_state%2==0
	if even: p.appearance=posmod(p.appearance+(1 if p.trigger_state>0 else -1),4)
	var offset: int=(0x1cc6 if p.trigger_state>0 else 0x1cce)+p.appearance*2
	_routed_rope_event(p,tables.u16(offset)!=0,0x40000000)
	# The event reads the preceding completed-update coordinates. Rebuild
	# the displayed knot/outline only after it has been sent.
	if even: RopePhysics.refresh_anchors(p,tables)
	p.trigger_state=0
	p.triggered=false

func _routed_rope_event(source: SimulationState.SimPart,downward: bool,force: int=0) -> void:
	for rope in state.ropes:
		var route: Array=rope.route
		var side:=0 if route[0]==source.index else (1 if route.back()==source.index else -1)
		if side<0 or int(rope.slots[side])!=0: continue # these constructors use +6F
		var receiver=part(int(route.back() if side==0 else route[0]))
		if receiver==null or not receiver.active or not receiver.placed: continue
		var bits:=RopePhysics.direction_bits(state,rope,side,downward)
		var slot:=int(rope.slots[1-side])
		event("routed_rope_event",source,{"receiver":receiver.index,"slot":slot,"bits":bits,"force":force,"owner":rope.owner})
		_rope_receive(source,receiver,bits,slot,force)

func _rope_event(source: SimulationState.SimPart,bits: int) -> void:
	# The recovered seven +134 recipients use these event bits. Unresolved
	# tension calculations are retained as diagnostics, not invented forces.
	var pending: Array[int]=source.links.duplicate()
	var visited: Dictionary={source.index:true}
	while not pending.is_empty():
		var id: int=pending.pop_front()
		var receiver=part(id)
		if receiver==null or visited.has(id) or not receiver.active or not receiver.placed: continue
		visited[id]=true
		match receiver.part_type:
			14,15,17,76:
				for next in receiver.links: pending.append(next)
			_:
				_rope_receive(source,receiver,bits)

func _rope_receive(source: SimulationState.SimPart,receiver: SimulationState.SimPart,bits: int,slot: int=0,force: int=0) -> bool:
	if receiver.part_type==23:
		# 7855:029F: a neutral event counts the primary Rope block. Other
		# events compare the caller's force with native weighted speed.
		if bits==1:
			var rope:=_endpoint_rope(receiver,0)
			if not rope.is_empty(): rope["reaction_count"]=K.s16(int(rope.get("reaction_count",0))+1)
			return false
		var resistance: int=receiver.momentum*(1 if source.part_type==3 else 2)&0xffffffff
		if resistance&0x80000000: resistance-=0x100000000
		return resistance>force
	if receiver.part_type==20:
		# 7977:01D6: reverse-direction resistance applies to probes too;
		# only a committed horizontal pull can start the firing sequence.
		if bits==1: return false
		var accepted:=0x10 if receiver.flip_x else 8
		if bits&0x18==(8 if receiver.flip_x else 0x10): return true
		if bits&0x8018==accepted and receiver.trigger_state==0:
			request(receiver,1,"rope pulls Pistol trigger",source)
		return false
	if receiver.part_type==3: return _teeter_receive(source,receiver,bits,slot,force)
	if receiver.part_type==43:
		# 5EDC:0148 also accepts the original probe's directional event.
		if bits==1:
			var rope:=_endpoint_rope(receiver,0)
			if not rope.is_empty(): rope["reaction_count"]=K.s16(int(rope.get("reaction_count",0))+1)
		elif bits&0x18==(8 if receiver.flip_x else 16): request(receiver,1,"rope pulls Trans-Roto-Matic",source)
		return false
	if receiver.part_type==42:
		# 5F1E:017F does not discard the high probe bit. Low bits1 count
		# the selected block's probe;2 queues opening, for either endpoint slot.
		if bits&3==1:
			var rope:=_endpoint_rope(receiver,slot)
			if not rope.is_empty(): rope["reaction_count"]=K.s16(int(rope.get("reaction_count",0))+1)
		elif bits&3==2: request(receiver,1,"rope event",source)
		return false
	if bits&0x8000: return false
	match receiver.part_type:
		53:
			if bits&4: request(receiver,1,"rope event",source)
		78:
			if bits&4: request(receiver,-1,"rope event",source)
	return false

func _endpoint_rope(p: SimulationState.SimPart,slot: int) -> Dictionary:
	for rope in state.ropes:
		var side:=0 if rope.route[0]==p.index else (1 if rope.route.back()==p.index else -1)
		if side>=0 and int(rope.slots[side])==slot: return rope
	return {}

func _teeter_receive(source: SimulationState.SimPart,p: SimulationState.SimPart,bits: int,slot: int,force: int) -> bool:
	# 5C75:04D9/05F5: endpoint-specific return motion, far-end resistance,
	# and per-rope suppression counts. Never bounce a signal to its sender.
	var rope:=_endpoint_rope(p,slot)
	if rope.is_empty(): return false
	var action:=bits&7
	var probe:=bits&0x8000!=0
	var count:=int(rope.get("reaction_count",0))
	if action!=1 and count!=0:
		if not probe: rope["reaction_count"]=K.s16(count-1)
		return false
	var blocked:=false
	var direction:=0
	if action==4:
		blocked=p.appearance==(0 if slot==0 else 2)
		direction=-1 if slot==0 else 1
	elif action==2:
		blocked=p.appearance==(2 if slot==0 else 0)
		direction=1 if slot==0 else -1
	if not blocked and action!=1:
		if rope_dispatch_stack.has(p.index):
			event("unresolved_rope_constraint",p,{"reason":"cyclic Teeter-Totter force graph","producer":source.index,"slot":slot,"force":force})
			return true
		var saved:=p.trigger_state
		request(p,direction,"rope moves Teeter-Totter",source)
		rope_dispatch_stack.append(p.index)
		blocked=_teeter_rope(p,probe,source,force)
		rope_dispatch_stack.pop_back()
		if probe: p.trigger_state=saved
		elif not blocked: p.flags08|=0x400
	if blocked: p.flags08|=0x200
	if p.flags08&0x200: return true
	if bits&0x8007==1: rope["reaction_count"]=K.s16(count+1)
	return false

func _replace_endpoint(p: SimulationState.SimPart) -> void:
	var attached:=false
	for link in p.links:
		if part(link)!=null: attached=true
	if not attached: return
	var endpoint=spawn(76,xy(p))
	if endpoint==null: return
	# 7855:014F transfers the rope block's cached world knot into the new
	# free endpoint. Its local knot is zero and it joins the mover list.
	for rope in state.ropes:
		var side: int=0 if int(rope.route[0])==p.index else (1 if int(rope.route.back())==p.index else -1)
		if side<0: continue
		var points: Array=rope.get("event_points",[])
		position(endpoint,points[side] if points.size()>=2 else RopePhysics.point(state,p.index,int(rope.slots[side])))
		break
	# 7855:014F preserves descriptor0800 and explicitly inserts into the mover list.
	endpoint.flags=tables.u16(0x620+76*16)|0x10
	endpoint.chain_override=0x1000
	endpoint.previous_position=Vector2i.ZERO
	endpoint.older_position=Vector2i.ZERO
	endpoint.flags08=4
	endpoint.reaction_data["rope_anchors"]=[Vector2i.ZERO,Vector2i.ZERO]
	endpoint.collision_enabled=false
	endpoint.links=p.links.duplicate()
	insert_chain(state,endpoint,world)
	for other in state.parts:
		if other==p or other==endpoint: continue
		for i in other.links.size():
			if other.links[i]==p.index: other.links[i]=endpoint.index
	# Portable routes represent the original rope block's endpoint pointers.
	# Transfer those as well as +63/+65, otherwise the popped Balloon remains
	# constrained and the free end is never actually substituted in the route.
	for rope in state.ropes:
		for i in rope.route.size():
			if int(rope.route[i])==p.index: rope.route[i]=endpoint.index
	p.links.assign([-1,-1,-1,-1])
	p.reaction_data["tether_replaced"]=endpoint.index
	event("tether_endpoint_replaced",p,{"endpoint":endpoint.index})

func _cut_ropes(p: SimulationState.SimPart) -> void:
	RopePhysics.cut(state,p,self)
