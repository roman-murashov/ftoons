class_name PlacementObjective
extends RefCounted

## Iteration 5 adapter. The exact DOS victory predicate is still unresolved;
## this keeps the playable slice deterministic and makes that boundary visible.
const BOARD := Rect2(0, 0, 552, 400)
const FIXED_SHIFT := 15

func evaluate(puzzle: PuzzleDefinition, state: SimulationState) -> Dictionary:
	var inventory_count := 0
	var placed_count := 0
	var invalid_reason := ""
	var occupied: Array[Rect2] = []
	for index in puzzle.parts.size():
		var source: PartDefinition = puzzle.parts[index]
		var part: SimulationState.SimPart = state.parts[index]
		if source.is_in_parts_bin():
			inventory_count += 1
			if not part.placed:
				continue
			placed_count += 1
			var rect := _rect_for(source, part)
			if not BOARD.encloses(rect):
				invalid_reason = "part %d is outside the board" % index
				break
			if _overlaps_any(rect, occupied):
				invalid_reason = "part %d overlaps another placed part" % index
				break
			occupied.append(rect)
		elif source.is_fixed():
			var fixed_rect := source.rect()
			if fixed_rect.size.x > 0 and fixed_rect.size.y > 0:
				occupied.append(fixed_rect)
	if invalid_reason.is_empty() and placed_count == inventory_count and state.tick > 0:
		return {"status": "won", "message": "Placement accepted. Completion recorded."}
	if not invalid_reason.is_empty():
		return {"status": "invalid", "message": invalid_reason}
	if placed_count < inventory_count:
		return {"status": "incomplete", "message": "%d/%d inventory parts placed" % [placed_count, inventory_count]}
	return {"status": "incomplete", "message": "Run the simulation before completing"}

func _rect_for(source: PartDefinition, part: SimulationState.SimPart) -> Rect2:
	var x := part.x_fixed >> FIXED_SHIFT
	var y := part.y_fixed >> FIXED_SHIFT
	var w := source.placement_width()
	var h := source.placement_height()
	if part.rotation % 2 == 1:
		var swap := w
		w = h
		h = swap
	return Rect2(x, y, w, h)

func _overlaps_any(rect: Rect2, others: Array[Rect2]) -> bool:
	for other in others:
		if rect.intersects(other):
			return true
	return false
