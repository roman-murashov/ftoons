extends RefCounted
const Belts = preload("res://scripts/simulation/belt_connections.gd")
var runner: SimulationRunner
var backup: SimulationState
var owner := -1
var start := -1
var cursor := Vector2i.ZERO
var candidate: Dictionary = {}
func active() -> bool:
	return owner>=0
static func occupied(state: SimulationState,id: int) -> bool:
	for belt in state.belts:
		if belt.ends.has(id): return true
	return false
static func within(a: SimulationState.SimPart,b: SimulationState.SimPart) -> bool:
	var d: Vector2i=(Belts.anchor(a)-a.frame_offset)-(Belts.anchor(b)-b.frame_offset)
	return d.x*d.x+d.y*d.y<=19600
static func movement_error(state: SimulationState,id: int) -> String:
	for belt in state.belts:
		if belt.ends.has(id) and not within(state.parts[belt.ends[0]],state.parts[belt.ends[1]]):
			return "Belt exceeds the 140-pixel attachment limit."
	return ""
func begin(host: SimulationRunner,index: int) -> void:
	runner=host
	backup=host.state.clone()
	SimulationRunner.take_inventory_connection(host.state.parts[index])
	owner=index
	start=-1
	candidate={}
func detach(host: SimulationRunner,belt: Dictionary,side: int) -> void:
	begin(host,belt.owner)
	start=belt.ends[1-side]
	host.state.belts.erase(belt)
	host.state.parts[belt.ends[side]].flags08 &= ~2
	host.state.parts[owner].placed=false
	cursor=Belts.anchor(host.state.parts[belt.ends[side]])
	hover(cursor)
func hover(position: Vector2i) -> void:
	cursor=position
	candidate={"ok":false,"reason":"Point at a free Belt-compatible gadget."}
	for id in range(runner.state.parts.size()-1,-1,-1):
		var p:=runner.state.parts[id]
		if not p.active or not p.placed or p.part_type in [1,14,76]: continue
		var frame:=runner.world_physics.frame_geometry(p)
		if not Rect2i(Vector2i(p.x_fixed>>15,p.y_fixed>>15)+frame.position,frame.size).has_point(position): continue
		if not p.flags08&1: return
		if id==start or occupied(runner.state,id):
			candidate.reason="This Belt attachment is occupied."
			return
		if start>=0 and not within(runner.state.parts[start],p):
			candidate.reason="Beyond the 140-pixel attachment limit."
			return
		candidate={"ok":true,"id":id,"reason":"Attach start" if start<0 else "Attach end"}
		return
func click(position: Vector2i) -> bool:
	hover(position)
	if not candidate.get("ok",false): return false
	var id: int=candidate.id
	runner.state.parts[id].flags08 |= 2
	if start<0:
		start=id
		hover(position)
		return false
	runner.state.belts.append({"owner":owner,"ends":[start,id]})
	Belts.refresh(runner.state,start)
	var p:=runner.state.parts[owner]
	p.placed=true
	p.active=true
	p.collision_enabled=false
	runner.world_physics.reactions.insert_chain(runner.state,p,runner.world_physics)
	owner=-1
	backup=null
	return true
func cancel() -> void:
	if not active(): return
	runner.state=backup
	for belt in runner.state.belts.duplicate():
		if belt.owner==owner:
			for id in belt.ends: runner.state.parts[id].flags08 &= ~2
			runner.state.belts.erase(belt)
	var p:=runner.state.parts[owner]
	p.placed=false
	runner.world_physics.reactions.insert_chain(runner.state,p,runner.world_physics)
	owner=-1
	backup=null
