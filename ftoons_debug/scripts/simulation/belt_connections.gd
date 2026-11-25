class_name BeltConnections
extends RefCounted

## 1000:7675: mechanical drive follows the belt, not ordinary neighbor links.
static func opposite(state: SimulationState, source: SimulationState.SimPart):
	if not source.active or not source.placed: return null
	for belt in state.belts:
		var owner: SimulationState.SimPart = state.parts[belt.owner]
		if not owner.active or not owner.placed: continue
		var ends: Array = belt.ends
		var index: int = ends[1] if ends[0] == source.index else (ends[0] if ends[1] == source.index else -1)
		if index < 0 or index >= state.parts.size(): continue
		var receiver: SimulationState.SimPart = state.parts[index]
		if receiver.active and receiver.placed: return receiver
	return null

## Original 298D:5142 graph and 1000:521C two-line construction.
static func initialize(state: SimulationState) -> void:
	state.belts.clear()
	for owner in state.parts:
		if owner.part_type != 1 or not owner.placed or owner.definition == null: continue
		var ends: Array[int] = owner.definition.belt_endpoints
		if ends.size() != 2: continue
		if ends[0] < 0 or ends[1] < 0 or ends[0] >= state.parts.size() or ends[1] >= state.parts.size(): continue
		if not state.parts[ends[0]].placed or not state.parts[ends[1]].placed: continue
		state.belts.append({"owner":owner.index,"ends":ends.duplicate()})
	refresh(state)

## 521C runs during setup/editing. 5E43 deliberately does not reconstruct
## Belt lines during play, even when a Bobbin's sprite bounds change.
static func refresh(state: SimulationState, moved: int=-1) -> void:
	for belt in state.belts:
		if moved<0 or belt.ends.has(moved): belt["segments"]=_construct_segments(state,belt)

static func anchor(p: SimulationState.SimPart) -> Vector2i:
	var d := p.definition
	var offset := Vector2i(d.belt_connect_pos_x,d.belt_connect_pos_y)
	# 60F6:0000 rebuilds the motor anchor for its live facing.
	if p.part_type == 80: offset = Vector2i(22 if p.flip_x else 26,46)
	if p.part_type == 44: offset = Vector2i(4,2 if p.flip_y else 74)
	if p.part_type == 43: offset = Vector2i(40 if p.flip_x else 48,31)
	return Vector2i(p.x_fixed >> 15,p.y_fixed >> 15) + p.frame_offset + offset

static func segments(state: SimulationState, belt: Dictionary) -> Array[Dictionary]:
	var a: SimulationState.SimPart = state.parts[belt.ends[0]]
	var b: SimulationState.SimPart = state.parts[belt.ends[1]]
	if not a.active or not b.active or not a.placed or not b.placed or not state.parts[belt.owner].placed: return []
	var result: Array[Dictionary]=[]
	if belt.has("segments"): result.assign(belt.segments)
	else: result=_construct_segments(state,belt)
	return result

static func _construct_segments(state: SimulationState, belt: Dictionary) -> Array[Dictionary]:
	var a: SimulationState.SimPart = state.parts[belt.ends[0]]
	var b: SimulationState.SimPart = state.parts[belt.ends[1]]
	var p := anchor(a)
	var q := anchor(b)
	var da: int = a.definition.belt_line_distance
	var db: int = b.definition.belt_line_distance
	if absi(p.x-q.x) < absi(p.y-q.y):
		return [{"a":p+Vector2i(0,da>>1),"b":q+Vector2i(0,db>>1)},
			{"a":p+Vector2i(da,da>>1),"b":q+Vector2i(db,db>>1)}]
	return [{"a":p+Vector2i(da>>1,0),"b":q+Vector2i(db>>1,0)},
		{"a":p+Vector2i(da>>1,da),"b":q+Vector2i(db>>1,db)}]
