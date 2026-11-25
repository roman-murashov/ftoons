class_name RopePhysics
extends RefCounted

const PartTransform = preload("res://scripts/simulation/part_transform.gd")
# 5C75:0000, original EXE bytes at 0x4D022; verified against live DS:0632.
# The packaged resident table snapshot does not retain this low-DS overlay data.
const TEETER_ANCHORS = [
	[Vector2i(8,27),Vector2i(68,4)],
	[Vector2i(11,16),Vector2i(72,16)],
	[Vector2i(14,4),Vector2i(75,29)],
]

static func refresh_anchors(p: SimulationState.SimPart, tables: ReactionTables) -> void:
	var points: Array
	match p.part_type:
		3:
			points=TEETER_ANCHORS[clampi(p.appearance,0,2)].duplicate()
		20:
			# 7977:0000: trigger follows the firing frame, including native X flip.
			var frame:=clampi(p.appearance,0,4)
			var x:=tables.u8(0x47dd+frame*4)
			points=[Vector2i(p.width-x if p.flip_x else x,tables.u8(0x47df+frame*4)),Vector2i.ZERO]
		60:
			# 5F7A:0000: breaking Piano attachment follows each frame.
			var frame:=clampi(p.appearance,0,7)
			points=[Vector2i(tables.u8(0x2427+frame*2),tables.u8(0x2428+frame*2)),Vector2i.ZERO]
		44:
			# 5E0E:0000: the crank's knot moves independently of sprite offsets.
			var offset: int=(0x1cbe if p.flip_y else 0x1cb6)+clampi(p.appearance,0,3)*2
			points=[Vector2i(tables.s8(offset),tables.s8(offset+1)),Vector2i.ZERO]
		43:
			# 5EDC:0000, resident 440F:2010. The plunger extends beyond the
			# idle logical width, then returns to its original rope attachment.
			var x:=tables.u8(0x2010+clampi(p.appearance,0,6))
			points=[Vector2i(p.width-x if p.flip_x else x,14),Vector2i.ZERO]
		42:
			# 5F1E:0000: knot coordinates are an animation table, not the
			# sprite's offset or the initial serialized attachment.
			points=[Vector2i(25,tables.s8(0x2183+clampi(p.appearance,0,6))),Vector2i.ZERO]
		_:
			return
	for slot in 2:
		points[slot]=PartTransform.point(points[slot],Vector2i(p.width,p.height),p.rotation,p.editor_mirror_x,p.editor_mirror_y)
	p.reaction_data["rope_anchors"]=points

## Ordered attachment graph, 298D:5142 / 1000:533D / 7B83.
## Length uses the original integer norm, not Euclidean distance.
static func distance(v: Vector2i) -> int:
	var small := mini(absi(v.x),absi(v.y))
	return maxi(absi(v.x),absi(v.y)) + (small>>2) + (small>>3)

static func xy(p: SimulationState.SimPart) -> Vector2i:
	return Vector2i(p.x_fixed>>15,p.y_fixed>>15)

static func anchors(p: SimulationState.SimPart) -> Array:
	return p.reaction_data.get("rope_anchors",[Vector2i.ZERO,Vector2i.ZERO])

static func point(state: SimulationState, index: int, slot: int) -> Vector2i:
	return xy(state.parts[index])+Vector2i(anchors(state.parts[index])[slot])

static func initialize(state: SimulationState) -> void:
	state.ropes.clear()
	var tables:=ReactionTables.new()
	for p in state.parts:
		var d: PartDefinition=p.definition
		p.reaction_data["rope_previous_draw_origin"]=xy(p)+p.frame_offset
		p.reaction_data["rope_older_draw_origin"]=xy(p)+p.frame_offset
		p.reaction_data["rope_anchors"]=[Vector2i(d.rope_1_connect_pos_x,d.rope_1_connect_pos_y),Vector2i(d.rope_2_connect_pos_x,d.rope_2_connect_pos_y)]
		refresh_anchors(p,tables)
	for p in state.parts:
		if p.part_type!=14 or not p.placed: continue
		var d: PartDefinition=p.definition
		if d.rope_slots.is_empty(): continue
		var ends: Array=d.rope_slots[0].ends
		if ends[0]<0 or ends[1]<0 or ends[0]>=state.parts.size() or ends[1]>=state.parts.size(): continue
		var slots: Array=d.rope_slots[0].slots.duplicate()
		var route: Array=[int(ends[0])]
		var previous: int=ends[0]
		var next: int=state.parts[previous].links[int(slots[0])]
		while next>=0 and next<state.parts.size() and not route.has(next):
			route.append(next)
			if next==ends[1]: break
			var node:=state.parts[next]
			if node.part_type!=17: break
			var following: int=node.links[0] if node.links[0]!=previous else node.links[1]
			previous=next
			next=following
		if route.back()!=ends[1]: continue
		if route.any(func(id): return not state.parts[id].placed): continue
		var rope: Dictionary={"owner":p.index,"route":route,"slots":slots,"lengths":[0,0]}
		state.ropes.append(rope)
		for side in 2:
			rope.lengths[side]=distance(end_delta(state,rope,side))
			var end:=state.parts[int(ends[side])]
			if end.part_type==61: end.appearance=1
		rope["previous_lengths"]=rope.lengths.duplicate()
		rope["older_lengths"]=rope.lengths.duplicate()
		refresh_event_points(state,rope)
		seed_point_history(rope)

	# Disconnected inventory routes must not retain authored live neighbors.
	for p in state.parts:
		for slot in 2:
			var neighbor: int=p.links[slot]
			if (p.definition.rope_slots.size()>slot and p.definition.rope_slots[slot].present) or p.part_type==17 or (neighbor>=0 and state.parts[neighbor].part_type==17):
				var attached := false
				for rope in state.ropes:
					if rope.route.has(p.index): attached = true
				if not attached: p.links[slot] = -1

static func refresh_lengths(state: SimulationState, index: int) -> void:
	for rope in state.ropes:
		if not rope.route.has(index): continue
		for side in 2: rope.lengths[side] = distance(end_delta(state,rope,side))
		rope.previous_lengths = rope.lengths.duplicate()
		rope.older_lengths = rope.lengths.duplicate()
		refresh_event_points(state,rope)
		seed_point_history(rope)

static func seed_point_history(rope: Dictionary) -> void:
	# 533D initialization and79F3 cutting seed the block's +1C/+24 caches,
	# independently of the controller's current/previous/older length words.
	rope["previous_event_points"]=rope.event_points.duplicate()
	rope["older_event_points"]=rope.event_points.duplicate()

static func neighbor_slot(p: SimulationState.SimPart, other: int) -> int:
	return 0 if p.links[0]==other else 1

## 1000:769F. Convert endpoint movement to the far endpoint's rope event.
## downward selects the source movement; Pulley rims change the received axes.
static func direction_bits(state: SimulationState, rope: Dictionary, side: int, downward: bool) -> int:
	var route: Array=rope.route
	var other:=1-side
	var cached: Array=rope.get("event_points",[])
	var source: Vector2i=cached[side] if cached.size()==4 else point(state,int(route[0] if side==0 else route.back()),int(rope.slots[side]))
	var target: Vector2i=cached[other] if cached.size()==4 else point(state,int(route.back() if side==0 else route[0]),int(rope.slots[other]))
	var source_neighbor:=target
	var target_neighbor:=source
	if route.size()>2:
		# The event helper uses the Pulley's opposite rim from the drawn segment.
		source_neighbor=cached[2+side] if cached.size()==4 else point(state,int(route[1] if side==0 else route[route.size()-2]),other)
		target_neighbor=cached[2+other] if cached.size()==4 else point(state,int(route[route.size()-2] if side==0 else route[1]),side)
	var horizontal:=8 if target_neighbor.x<target.x else 0x10
	if not downward:
		if source_neighbor.y<source.y: return 1
		return horizontal | (4 if target.y<=target_neighbor.y else 2)
	if source.y<source_neighbor.y: return 1
	return horizontal | (4 if target.y<target_neighbor.y else 2)

static func refresh_event_points(state: SimulationState, rope: Dictionary) -> void:
	var route: Array=rope.route
	var a:=point(state,int(route[0]),int(rope.slots[0]))
	var b:=point(state,int(route.back()),int(rope.slots[1]))
	rope["event_points"]=[a,b,
		point(state,int(route[1]),1) if route.size()>2 else b,
		point(state,int(route[route.size()-2]),0) if route.size()>2 else a]

static func end_delta(state: SimulationState, rope: Dictionary, side: int) -> Vector2i:
	var route: Array=rope.route
	var end: int=route[0] if side==0 else route.back()
	var neighbor: int=route[1] if side==0 else route[route.size()-2]
	var node:=state.parts[neighbor]
	var slot:=neighbor_slot(node,end)
	if node.part_type==17: slot=1-slot # 8549 uses the opposite rim.
	return point(state,end,int(rope.slots[side]))-point(state,neighbor,slot)

static func relink(state: SimulationState, rope: Dictionary) -> void:
	var route: Array=rope.route
	for i in route.size():
		var p:=state.parts[int(route[i])]
		while p.links.size()<4: p.links.append(-1)
		if i==0: p.links[int(rope.slots[0])]=route[1]
		elif i==route.size()-1: p.links[int(rope.slots[1])]=route[i-1]
		else:
			p.links[0]=route[i+1]
			p.links[1]=route[i-1]

static func has_primary_connection(state: SimulationState,p: SimulationState.SimPart) -> bool:
	for rope in state.ropes:
		var side:=0 if rope.route[0]==p.index else (1 if rope.route.back()==p.index else -1)
		if side>=0 and int(rope.slots[side])==0: return true
	return false

static func constrain(state: SimulationState, p: SimulationState.SimPart, world) -> bool:
	var corrected:=false
	for rope in state.ropes:
		var route: Array=rope.route
		var side: int=0 if route[0]==p.index else (1 if route.back()==p.index else -1)
		if side<0: continue
		var other:=state.parts[int(route.back() if side==0 else route[0])]
		var opposite:=1-side
		var via_pulley: bool=route.size()>2
		var delta:=end_delta(state,rope,side)
		var length:=distance(delta)
		var other_distance:=distance(end_delta(state,rope,opposite))
		var excess: int=length-int(rope.lengths[side])
		var incoming_budget: int=int(rope.lengths[side])
		var other_excess: int=other_distance-int(rope.lengths[opposite])
		# 7B83 captures vertical direction before any radial correction.
		var movement:=xy(p).y-p.previous_position.y
		if p.part_type!=76:
			if via_pulley:
				excess+=other_excess
				other_excess=0
				rope.lengths[side]=length-excess
				rope.lengths[opposite]=other_distance
				# 1000:7CCD..7D0B writes the new controller budgets first,
				# then returns AX=0 when the incoming negative budget exactly
				# cancels this segment length. Do not snap to the Pulley or
				# erase velocity on this transient overdrawn-rope update.
				if excess>=length and -incoming_budget==length:
					return false
			if excess>0 and other_excess<0:
				var sum:=excess+other_excess
				excess=maxi(0,sum)
				other_excess=mini(0,sum)
				rope.lengths[side]=length-excess
				rope.lengths[opposite]=other_distance-other_excess
		# 1000:7D81..7F30: a heavier mover can draw rope from a lighter
		# mover's end. Constrain that recipient recursively, then collision-
		# check it before crediting only the length it actually surrendered.
		# Merely projecting the heavier endpoint freezes hanging weights.
		if excess>0 and other.flags&0x1000 and p.part_type!=76 and other.part_type!=76 and p.collision_weight>other.collision_weight:
			var transfer: int=mini(absi(int(rope.lengths[opposite])),maxi(1,world.kernel.divide(absi(excess)*(p.collision_weight-other.collision_weight)+p.collision_weight,p.collision_weight)))
			if transfer!=0:
				rope.lengths[opposite]-=transfer
				var shortened: int=rope.lengths[opposite]
				constrain(state,other,world)
				other.flags&=~15
				var other_body=world.current_body(other)
				other_body.ox=other.previous_position.x
				other_body.oy=other.previous_position.y
				world.detect_contacts(other,other_body,state)
				world._sync_to_sim(other,other_body)
				other_distance=distance(end_delta(state,rope,opposite))
				other_excess=other_distance-shortened
				if other_excess!=0:
					rope.lengths[opposite]+=other_excess
					transfer-=other_excess
				if transfer!=0:
					rope.lengths[side]+=transfer
					excess=length-int(rope.lengths[side])
		# A falling weight draws a free end through the pulleys (7Fxx).
		if other.part_type==76 and p.part_type!=76:
			if via_pulley:
				rope.lengths[opposite]-=excess
				if rope.lengths[opposite]<0:
					excess+=int(rope.lengths[opposite])
					var removed_index: int=1 if opposite==0 else route.size()-2
					var removed:=state.parts[int(route[removed_index])]
					removed.links[0]=-1
					removed.links[1]=-1
					route.remove_at(removed_index)
					relink(state,rope)
					# 7844 reads cached block coordinates, refreshed after the mover phase.
					var cached_delta:=end_delta(state,rope,opposite)+other.previous_position-xy(other)
					if route.size()==2: cached_delta-=p.previous_position-xy(p)
					rope.lengths[opposite]=distance(cached_delta)
				rope.lengths[side]+=excess
			continue
		if excess<=0 or length==0:
			# 84B4..8533:42/43 receive motion even without a correction.
			# Subpixel movement falls back to signed +39, not rounded pixels.
			if p.part_type!=76 and other.part_type in [42,43] and (movement!=0 or p.vy_fixed!=0):
				var downward:=movement>0 if movement!=0 else p.vy_fixed>0
				world.reactions._rope_receive(p,other,direction_bits(state,rope,side,downward),0,p.momentum)
			continue
		corrected=true # Original7B83 sets its return flag before radial correction.
		var budget: int=maxi(0,int(rope.lengths[side]))
		# Signed division truncates toward zero, as DOS IDIV does.
		var correction:=Vector2i(int(float(delta.x*budget)/length)-delta.x,int(float(delta.y*budget)/length)-delta.y)
		var position:=xy(p)+correction
		p.x_fixed=position.x<<15
		p.y_fixed=position.y<<15
		var speed_limit: int=world.kernel.types.environment(p.part_type,world.reactions.puzzle.pressure,world.reactions.puzzle.gravity).speed_limit_q9
		# 7B83 -> 7B3F shifts the WORD +37 before27B3 clamps it. A new
		# free end still has previous X=0, so the signed16 wrap is observable.
		p.vx_fixed=clampi(world.kernel.s16((position.x-p.previous_position.x)<<9),-speed_limit,speed_limit)<<6
		# 7B83 tests X, deliberately not Y, before clearing vertical speed.
		if position.x==p.previous_position.x: p.vy_fixed=0
		# 7B83 -> 769F -> 60A6:011D. Only dispatch when motion produced
		# tension; static gadget updates consume the request on the next tick.
		# Constraint correction can erase movement; use the integrated endpoint.
		if other.part_type==3 and p.part_type!=76 and movement!=0:
			# 1000:7B83 queues a Teeter update directly; this is distinct from
			# its recursive +134 rope callback. Preserve endpoint selection,
			# zero requests at the travel limit and source impact momentum.
			var bits:=direction_bits(state,rope,side,movement>0)
			var slot:=int(rope.slots[opposite])
			var direction:=0
			if bits&4:
				if slot==0 and other.appearance>0: direction=-1
				elif slot!=0 and other.appearance<2: direction=1
			else:
				if slot==0 and other.appearance<2: direction=1
				elif slot!=0 and other.appearance>0: direction=-1
			if world.reactions.enqueue_update(p,other):
				world.reactions.request(other,direction,"rope tension moves Teeter-Totter",p)
				other.momentum=p.momentum
		elif p.part_type!=76 and movement!=0:
			# 82AC..82E8 invokes the recipient's +134 callback, not a list
			# limited to Pistols/Trap Doors. The native call supplies slot0.
			world.reactions._rope_receive(p,other,direction_bits(state,rope,side,movement>0),0,p.momentum)
	return corrected

static func finish(state: SimulationState) -> void:
	if state.ropes.is_empty(): return
	# 20F2:2311..239A visits static then mover chains before88BC shifts
	# position histories. Returning to the two-updates-old pose restores the
	# WHOLE connection's older endpoint cache, even if its other end moved.
	var order: Array=[]
	for chain in [0x2000,0x1000]:
		order.append_array(state.query_chains.get(chain,[]))
		if state.query_chains.is_empty():
			# Standalone editor/geometry callers need not have scheduled a step.
			for p in state.parts:
				var membership:=p.chain_override if p.chain_override>=0 else (0x2000 if p.flags&0x6000 else 0x1000 if p.flags&0x1000 else 0)
				if p.placed and membership==chain: order.append(p.index)
	for rope in state.ropes:
		if not rope.has("event_points"):
			refresh_event_points(state,rope)
			seed_point_history(rope)
	var marked: Dictionary={}
	var attached: Dictionary={}
	for rope in state.ropes:
		attached[int(rope.route[0])]=true
		attached[int(rope.route.back())]=true
	var erased_regions: Array[Rect2i]=[]
	for index in order:
		var p:=state.parts[int(index)]
		if not p.placed or not p.active or p.flags08&0x2000: continue
		var old_pose:=xy(p)==p.older_position and p.appearance==p.older_appearance
		var previous_pose:=xy(p)==p.previous_position and p.appearance==p.previous_appearance
		if not old_pose:
			# 7644 -> 6B2B/6BBF queues the two-updates-old sprite area.
			# Keep its origin independently: animated frame offsets can change.
			marked[p.index]=true
			var origin: Vector2i=p.reaction_data.get("rope_older_draw_origin",p.older_position+p.frame_offset)
			if p.older_frame_size.x>0 and p.older_frame_size.y>0:
				# 6BBF aligns erased sprite spans to eight screen pixels.
				var screen_x:=origin.x-state.dos_view_origin.x
				var size:=p.older_frame_size
				size.x=(size.x+(screen_x&7)+7)&~7
				origin.x=(screen_x&~7)+state.dos_view_origin.x
				erased_regions.append(Rect2i(origin,size))
		for rope in state.ropes:
			if not rope.route.has(p.index) or p.part_type==17: continue
			if not old_pose:
				# 5E43 tests the controller's dirty byte &7F, independently
				# of the endpoint's byte. A later cache restoration does not
				# clear it, so another endpoint/overlap cannot refresh twice.
				if not marked.has(int(rope.owner)):
					refresh_event_points(state,rope)
					marked[int(rope.owner)]=true
			elif not previous_pose:
				var older: Array=rope.get("older_event_points",rope.event_points)
				for side in 2: rope.event_points[side]=older[side]
	# 705B -> 5E43(81h) -> 533D: repainting an otherwise unchanged
	# sprite also refreshes its attached ropes. This follows cache restoration;
	# HARD24's passing Al overlaps a Teeter-Totter after its pose has settled.
	# Do not refresh every rope unconditionally: changed sprites/controllers
	# already carry native dirty bits and skip this overlap branch.
	for index in order:
		var p:=state.parts[int(index)]
		if not p.placed or not p.active or p.flags08&0x2000 or marked.has(p.index): continue
		if not attached.has(p.index): continue
		if p.part_type in [1,14,17,76]: continue
		var bounds:=Rect2i(xy(p)+p.frame_offset,p.frame_size)
		if bounds.size.x<=0 or bounds.size.y<=0: continue
		var redraw:=false
		for region in erased_regions:
			# 705B uses a strict test on left/top and inclusive right/bottom.
			if region.position.x<bounds.end.x and bounds.position.x<region.end.x and region.position.y<bounds.end.y and bounds.position.y<region.end.y:
				redraw=true
				break
		if redraw:
			for rope in state.ropes:
				if rope.route[0]==p.index or rope.route.back()==p.index:
					if not marked.has(int(rope.owner)):
						refresh_event_points(state,rope)
						marked[int(rope.owner)]=true
	for p in state.parts:
		p.reaction_data["rope_older_draw_origin"]=p.reaction_data.get("rope_previous_draw_origin",p.previous_position+p.frame_offset)
		p.reaction_data["rope_previous_draw_origin"]=xy(p)+p.frame_offset
	for rope in state.ropes:
		rope["older_event_points"]=rope.get("previous_event_points",rope.event_points).duplicate()
		rope["previous_event_points"]=rope.event_points.duplicate()
		rope["older_reaction_count"]=int(rope.get("previous_reaction_count",0))
		rope["previous_reaction_count"]=int(rope.get("reaction_count",0))
		rope.older_lengths=rope.previous_lengths.duplicate()
		rope.previous_lengths=rope.lengths.duplicate()

static func segments(state: SimulationState, rope: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary]=[]
	var route: Array=rope.route
	for i in route.size()-1:
		var a:=state.parts[int(route[i])]
		var b:=state.parts[int(route[i+1])]
		var slot_a: int=int(rope.slots[0]) if i==0 else neighbor_slot(a,b.index)
		var slot_b: int=int(rope.slots[1]) if i==route.size()-2 else neighbor_slot(b,a.index)
		# 26B1:0EFD: outgoing Pulley rim1, incoming rim0.
		if a.part_type==17: slot_a=1-slot_a
		if b.part_type==17: slot_b=1-slot_b
		var start:=point(state,a.index,slot_a)
		var end:=point(state,b.index,slot_b)
		var slack:=0
		if i==0: slack=maxi(0,int(rope.lengths[0])-distance(end_delta(state,rope,0)))
		elif i==route.size()-2: slack=maxi(0,int(rope.lengths[1])-distance(end_delta(state,rope,1)))
		result.append({"a":start,"b":end,"slack":slack,"edge":i})
	return result

static func cut(state: SimulationState, scissors: SimulationState.SimPart, reactions) -> void:
	# 79F3:01DB splits an intersected segment, preserving each routed half.
	# 79F3:015A selects DS:1BD8/1BE0: a horizontal blade at y=17.
	var blade_left: int=24 if scissors.flip_x else 0
	var blade_right: int=43 if scissors.flip_x else 18
	for rope in state.ropes.duplicate():
		for segment in segments(state,rope):
			var a: Vector2i=segment.a-xy(scissors)
			var b: Vector2i=segment.b-xy(scissors)
			if a.y==b.y or 17<mini(a.y,b.y) or 17>maxi(a.y,b.y): continue
			var x:=int(float(a.x*(b.y-a.y)+(17-a.y)*(b.x-a.x))/(b.y-a.y))
			if x<blade_left or x>blade_right or x<mini(a.x,b.x) or x>maxi(a.x,b.x): continue
			var crossing:=xy(scissors)+Vector2i(x,17)
			var first=reactions.spawn(76,crossing)
			var second=reactions.spawn(76,crossing)
			var controller=reactions.spawn(14,Vector2i.ZERO)
			for endpoint in [first,second]:
				# 79F3 inserts these into the mover list explicitly, preserving
				# descriptor0800|spawned0010 rather than changing raw flags.
				endpoint.flags=reactions.tables.u16(0x620+76*16)|0x10
				endpoint.chain_override=0x1000
				endpoint.flags08=4
				endpoint.collision_enabled=false
				endpoint.reaction_data["rope_anchors"]=[Vector2i.ZERO,Vector2i.ZERO]
				reactions.insert_chain(state,endpoint,reactions.world)
			# Fresh298D:47BA controller, then explicit static insertion79F3:03A7.
			controller.flags=reactions.tables.u16(0x620+14*16)|0x10
			controller.flags08=0
			controller.chain_override=0x2000
			controller.collision_enabled=false
			reactions.insert_chain(state,controller,reactions.world)
			var edge: int=segment.edge
			var route: Array=rope.route
			var left: Array=route.slice(0,edge+1)
			left.append(first.index)
			var right: Array=[second.index]
			right.append_array(route.slice(edge+1))
			var split: Dictionary={"owner":controller.index,"route":right,"slots":[0,rope.slots[1]],"lengths":[0,0],"previous_lengths":[0,0],"older_lengths":[0,0]}
			rope.route=left
			rope.slots=[rope.slots[0],0]
			state.ropes.append(split)
			for half in [rope,split]:
				relink(state,half)
				for side in 2: half.lengths[side]=distance(end_delta(state,half,side))
				refresh_event_points(state,half)
				seed_point_history(half)
				# 79F3:01DB rebuilds current lengths/anchors, leaving the old
				# controller's history intact and the new controller's zeroed.
				# finish() performs the normal completed-update history shift.
			reactions.event("rope_cut",scissors,{"endpoints":[first.index,second.index],
				"controller":controller.index, "cut_rope":rope.owner})
			break
