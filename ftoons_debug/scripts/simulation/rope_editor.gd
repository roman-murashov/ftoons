class_name RopeEditor
extends RefCounted
const NativeState = preload("res://scripts/simulation/native_state_contract.gd")

## Construction graph separate from the complete, simulatable rope list.
## DOS: 1000:4709, 5103; 2F9C:206F, 2533, 2609.
var runner: SimulationRunner
var backup: SimulationState
var owner: int = -1
var route: Array = []
var slots: Array = [0,0]
var cursor := Vector2i.ZERO
var candidate: Dictionary = {}
var editing_existing := false

func active() -> bool:
	return owner>=0

static func occupied(state: SimulationState, id: int, slot: int, except_owner: int=-1) -> bool:
	for rope in state.ropes:
		if rope.owner==except_owner: continue
		if state.parts[id].part_type==17 and rope.route.has(id): return true
		if rope.route[0]==id and rope.slots[0]==slot: return true
		if rope.route.back()==id and rope.slots[1]==slot: return true
	return false

static func clear_graph(state: SimulationState, rope: Dictionary) -> void:
	var nodes: Array=rope.route
	for i in nodes.size():
		var p:=state.parts[int(nodes[i])]
		if i==0: p.links[int(rope.slots[0])]=-1
		elif i==nodes.size()-1: p.links[int(rope.slots[1])]=-1
		else:
			p.links[0]=-1
			p.links[1]=-1
		if p.part_type in [60,61] and p.appearance<2:
			p.appearance=0

func begin(host: SimulationRunner, index: int) -> void:
	runner=host
	backup=runner.state.clone()
	SimulationRunner.take_inventory_connection(host.state.parts[index])
	owner=index
	route=[]
	slots=[0,0]
	editing_existing=false
	candidate={}

func detach(host: SimulationRunner, rope: Dictionary, side: int) -> void:
	begin(host,int(rope.owner))
	editing_existing=true
	route=rope.route.duplicate()
	slots=rope.slots.duplicate()
	clear_graph(host.state,rope)
	host.state.ropes.erase(rope)
	if side==0:
		route.reverse()
		slots.reverse()
	var detached_point:=RopePhysics.point(host.state,int(route.back()),int(slots[1]))
	route.pop_back()
	host.state.parts[owner].placed=false
	_relink_partial()
	hover(detached_point)

func _relink_partial() -> void:
	for i in route.size():
		var p:=runner.state.parts[int(route[i])]
		if i==0:
			p.links[int(slots[0])]=int(route[1]) if route.size()>1 else -1
			if p.part_type in [60,61] and p.appearance<2:
				p.appearance=1
		else:
			p.links[1]=route[i-1]
			p.links[0]=int(route[i+1]) if i+1<route.size() else -1

func target(position: Vector2i) -> Dictionary:
	var state:=runner.state
	for id in range(state.parts.size()-1,-1,-1):
		var p:=state.parts[id]
		if not p.active or not p.placed or p.part_type in [14,76]: continue
		var frame:=runner.world_physics.frame_geometry(p)
		if not Rect2i(RopePhysics.xy(p)+frame.position,frame.size).has_point(position): continue
		if not (p.flags08&4): return {"ok":false,"reason":"This part does not accept rope."}
		if route.has(id): return {"ok":false,"reason":"A rope cannot connect back to its own route."}
		if p.part_type==17 and route.is_empty(): return {"ok":false,"reason":"Start on an endpoint, then add Pulleys."}
		var slot:=0
		if p.flags08&8 and p.part_type!=17:
			var a:=position-RopePhysics.point(state,id,0)
			var b:=position-RopePhysics.point(state,id,1)
			slot=0 if absi(a.x)+absi(a.y)<absi(b.x)+absi(b.y) else 1
		if occupied(state,id,slot): return {"ok":false,"reason":"That rope attachment is occupied."}
		if not route.is_empty() and p.part_type!=17:
			for rope in state.ropes:
				if rope.route[0]==id and rope.route.back()==route[0]:
					return {"ok":false,"reason":"These endpoints are already connected."}
				if rope.route[0]==route[0] and rope.route.back()==id:
					return {"ok":false,"reason":"These endpoints are already connected."}
		return {"ok":true,"id":id,"slot":slot,"reason":"Add Pulley" if p.part_type==17 else ("Attach starting knot" if route.is_empty() else "Attach finishing knot")}
	return {"ok":false,"reason":"Point at a part that accepts rope."}

func hover(position: Vector2i) -> void:
	cursor=position
	candidate=target(position)
	refresh_pulleys(runner.state,route,slots,runner.world_physics.kernel,cursor,true)

func click(position: Vector2i) -> bool:
	hover(position)
	if not candidate.get("ok",false): return false
	var id: int=candidate.id
	if route.is_empty(): slots[0]=candidate.slot
	route.append(id)
	if route.size()==1 or runner.state.parts[id].part_type==17:
		_relink_partial()
		hover(position)
		return false
	slots[1]=candidate.slot
	var rope: Dictionary={"owner":owner,"route":route.duplicate(),"slots":slots.duplicate(),"lengths":[0,0]}
	runner.state.ropes.append(rope)
	RopePhysics.relink(runner.state,rope)
	refresh_pulleys(runner.state,rope.route,rope.slots,runner.world_physics.kernel)
	for end in [route[0],route.back()]:
		var p:=runner.state.parts[int(end)]
		if p.part_type in [60,61] and p.appearance<2:
			p.appearance=1
	for end in [route[0],route.back()]:
		var endpoint:=runner.state.parts[int(end)]
		if endpoint.part_type in [60,61]: runner.world_physics.frame_geometry(endpoint)
	RopePhysics.refresh_lengths(runner.state,id)
	var controller:=runner.state.parts[owner]
	controller.placed=true
	controller.active=true
	controller.collision_enabled=false
	runner.world_physics.reactions.insert_chain(runner.state,controller,runner.world_physics)
	owner=-1
	backup=null
	return true

func cancel() -> void:
	if not active(): return
	runner.state=backup
	if editing_existing:
		for rope in runner.state.ropes.duplicate():
			if rope.owner==owner:
				clear_graph(runner.state,rope)
				runner.state.ropes.erase(rope)
		var p:=runner.state.parts[owner]
		p.placed=false
		runner.world_physics.reactions.insert_chain(runner.state,p,runner.world_physics)
	owner=-1
	backup=null

static func refresh_pulleys(state: SimulationState, nodes: Array, ends: Array, kernel, pointer:=Vector2i.ZERO, unfinished:=false) -> void:
	for i in range(1,nodes.size() if unfinished else nodes.size()-1):
		var p:=state.parts[int(nodes[i])]
		if p.part_type!=17: continue
		var before:=state.parts[int(nodes[i-1])]
		var a:=RopePhysics.xy(before) if before.part_type==17 else RopePhysics.point(state,before.index,int(ends[0]))
		var b:=pointer
		if i+1<nodes.size():
			var after:=state.parts[int(nodes[i+1])]
			b=RopePhysics.xy(after) if after.part_type==17 else RopePhysics.point(state,after.index,int(ends[1]))
		var da:=RopePhysics.xy(p)-a
		var db:=RopePhysics.xy(p)-b
		# Kernel.direction includes 1000:1406's X negation; 4FC6 calls
		# 430F:0008 directly, so undo that wrapper here.
		var first: int=(kernel.direction(-da.x,da.y)+0x2000)&65535
		var second: int=(kernel.direction(-db.x,db.y)+0x2000)&65535
		var difference: int=(second-first)&65535
		var span:=difference
		if span>0x7fff:
			first=second
			span=(-span)&65535
		var quadrant:=((first+(span>>1))&65535)>>14
		var positive:=difference<0x8000
		var anchors: Array
		if quadrant in [0,2]:
			var y:=10 if quadrant==0 else 13
			anchors=[Vector2i(1,y),Vector2i(23,y)] if (quadrant==0 and positive) or (quadrant==2 and not positive) else [Vector2i(23,y),Vector2i(1,y)]
		else:
			var x:=13 if quadrant==1 else 9
			anchors=[Vector2i(x,1),Vector2i(x,23)] if (quadrant==1 and positive) or (quadrant==3 and not positive) else [Vector2i(x,23),Vector2i(x,1)]
		p.appearance=quadrant
		if state.tick==0: NativeState.write_saved_selector(p,quadrant,"1000:5103 Pulley route construction")
		p.reaction_data["rope_anchors"]=anchors

static func refresh_connected(host: SimulationRunner, moved: int) -> void:
	var part:=host.state.parts[moved]
	if part.part_type!=17 and part.definition!=null:
		var d:=part.definition
		var points: Array=[Vector2i(d.rope_1_connect_pos_x,d.rope_1_connect_pos_y),Vector2i(d.rope_2_connect_pos_x,d.rope_2_connect_pos_y)]
		for slot in 2:
			points[slot]=host.world_physics.PartTransform.point(points[slot],Vector2i(part.width,part.height),part.rotation,part.flip_x!=d.initial_flip_x(),part.flip_y!=d.initial_flip_y())
		part.reaction_data["rope_anchors"]=points
		RopePhysics.refresh_anchors(part,host.world_physics.reactions.tables)
	for rope in host.state.ropes:
		if rope.route.has(moved):
			refresh_pulleys(host.state,rope.route,rope.slots,host.world_physics.kernel)
	RopePhysics.refresh_lengths(host.state,moved)

static func movement_error(host: SimulationRunner, moved: int) -> String:
	var attached:=false
	for rope in host.state.ropes:
		if not rope.route.has(moved): continue
		attached=true
		for i in rope.route.size():
			var p:=host.state.parts[int(rope.route[i])]
			if not p.active or not p.placed or not (p.flags08&4): return "The rope needs placed, compatible attachments."
		for segment in RopePhysics.segments(host.state,rope):
			if segment.a==segment.b: return "Rope attachments cannot coincide."
	if not attached: return ""
	# 2F9C:2431 -> 1000:3C9F: refuse an attached gadget overlapping a solid.
	var p:=host.state.parts[moved]
	var shape:=host.world_physics.collider(p.definition,p)
	var polygon:=PackedVector2Array()
	for v in shape.points: polygon.append(Vector2(v[0],v[1])+Vector2(RopePhysics.xy(p)))
	if polygon.size()<3: return ""
	for other in host.state.parts:
		if other.index==moved or not other.active or not other.placed or other.flags08&0x2000: continue
		var other_shape:=host.world_physics.collider(other.definition,other)
		var other_polygon:=PackedVector2Array()
		for v in other_shape.points: other_polygon.append(Vector2(v[0],v[1])+Vector2(RopePhysics.xy(other)))
		if other_polygon.size()>=3 and not Geometry2D.intersect_polygons(polygon,other_polygon).is_empty():
			return "The connected part overlaps another solid part."
	return ""
