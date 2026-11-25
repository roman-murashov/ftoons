extends RefCounted
## UI generation shares the main thread with rendering, including on Web.
const Controls = preload("res://scripts/ui/construction_controls.gd")
const FRAME_BUDGET_MS := 8
var tree: SceneTree
var frame_deadline: int
var frame_budget_ms := 20 if OS.has_feature("web") else FRAME_BUDGET_MS

func _init(active_tree: SceneTree = null) -> void:
	tree = active_tree
	frame_deadline = Time.get_ticks_msec() + frame_budget_ms

func yield_if_needed() -> void:
	if tree != null and Time.get_ticks_msec() >= frame_deadline:
		await tree.process_frame
		frame_deadline = Time.get_ticks_msec() + frame_budget_ms

func place_inventory(controls: Controls, by_id: Dictionary, placements: Array, omit := "") -> bool:
	for drop in placements:
		if drop.part == omit: continue
		var index := int(by_id[drop.part])
		if controls.runner.state.parts[index].placed: return false
		if drop.has("belt_ends"):
			if not _connect_belt(controls, by_id, index, drop.belt_ends, omit): return false
			continue
		if drop.has("rope_route"):
			if not _connect_rope(controls, by_id, index, drop.rope_route, drop.rope_slots, omit): return false
			continue
		controls.take_native(index)
		if controls.grab_index != index: return false
		var position := Vector2i(int(drop.top_left[0]), int(drop.top_left[1]))
		controls._on_board_clicked(position + controls.grab_anchor)
		if controls.grab_active or RopePhysics.xy(controls.runner.state.parts[index]) != position: return false
	return true

func _connect_belt(controls: Controls, by_id: Dictionary, owner: int, ends: Array, omit: String) -> bool:
	# If an endpoint was withheld, its dependent belt remains in the bin as well.
	if ends.has(omit): return true
	controls.take_native(owner)
	if controls.belt_editor.owner != owner: return false
	for endpoint: String in ends:
		var index := int(by_id[endpoint])
		var p := controls.runner.state.parts[index]
		var frame := controls.runner.world_physics.frame_geometry(p)
		var point := RopePhysics.xy(p) + frame.get_center()
		controls.belt_editor.hover(point)
		if controls.belt_editor.candidate.get("id", -1) != index: return false
		controls._on_board_clicked(point)
	return not controls.grab_active and controls.runner.state.parts[owner].placed

func _connect_rope(controls: Controls, by_id: Dictionary, owner: int, route: Array, slots: Array, omit: String) -> bool:
	if route.has(omit): return true
	controls.take_native(owner)
	if controls.rope_editor.owner != owner: return false
	for node in route.size():
		var index: int = by_id[route[node]]
		var slot := int(slots[1] if node == route.size()-1 else slots[0] if node == 0 else 0)
		var p := controls.runner.state.parts[index]
		var rect := controls.runner.world_physics.frame_geometry(p)
		rect.position += RopePhysics.xy(p)
		var knot := RopePhysics.point(controls.runner.state, index, slot)
		var point := Vector2i(clampi(knot.x, rect.position.x, rect.end.x-1),
				clampi(knot.y, rect.position.y, rect.end.y-1))
		var candidate := controls.rope_editor.target(point)
		if not candidate.ok or candidate.id != index or candidate.slot != slot: return false
		controls._on_board_clicked(point)
	return not controls.grab_active and controls.runner.state.parts[owner].placed
