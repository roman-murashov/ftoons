extends RefCounted

## Construction frame choices recovered from DOS, separate from animation.
## Callers own the links and the saved selector; this helper does not rewrite
## comparison output or infer live state from an animated sprite.

static func source_selector(source: PartDefinition) -> int:
	# 298D:5D59 clears +99/+0E before returning unpinned campaign gadgets to
	# the bin. Conveyor resize799D:0173 updates only extents; it does not
	# restore factory47F5's frame4. Pinned and Home Toons sources keep theirs.
	if source.part_type == 0 and source.construction_context == "campaign" and source.is_in_parts_bin():
		return 0
	return source.appearance

static func refresh_switch(part: SimulationState.SimPart) -> void:
	if part.part_type != 2:
		return
	# 7917:0082: bit2 chooses the outlet orientation; bits0/1 are the two
	# occupied electrical sockets. Godot uses -1 for a null near link, so a
	# valid authored record0 must count as occupied. Rebuilding attachment
	# membership is a separate construction operation owned by the caller.
	part.appearance &= 4
	for slot in range(2, mini(4, part.links.size())):
		if part.links[slot] >= 0:
			part.appearance |= 1 << (slot - 2)

static func initially_connected_to_primary(source: PartDefinition, puzzle: PuzzleDefinition) -> bool:
	var identity := puzzle.parts.find(source)
	if identity < 0 or source.is_in_parts_bin():
		return false
	for owner: PartDefinition in puzzle.parts:
		if owner.part_type != 14 or owner.is_in_parts_bin() or owner.rope_slots.is_empty():
			continue
		var block: Dictionary = owner.rope_slots[0]
		var ends: Array = block.get("ends", [])
		var slots: Array = block.get("slots", [])
		if ends.size() != 2 or slots.size() != 2:
			continue
		var valid := true
		for endpoint in ends:
			if endpoint < 0 or endpoint >= puzzle.parts.size() or puzzle.parts[int(endpoint)].is_in_parts_bin():
				valid = false
		if not valid:
			continue
		for side in 2:
			if int(ends[side]) == identity and int(slots[side]) == 0:
				return true
	return false

static func anvil_initial_extent(source: PartDefinition, puzzle: PuzzleDefinition, geometry: Dictionary) -> Vector2i:
	#Home Toons JSON capture writes logical+41/+43 explicitly. Retain that
	#authoring history even if the attached drawing frame is two pixels taller.
	if puzzle.authored_logical_extents:
		return Vector2i(source.placement_width(),source.placement_height())
	# The packed width1/height1 are FRAME+4D/+4F, not logical+41/+43.
	# Campaign construction first removes inventory-dependent Ropes. A hanging
	# source whose Rope is removed is constructed as frame0 before the player
	# restores that Rope;61E9/6212 retains this first logical extent thereafter.
	if source.part_type != 61:
		return Vector2i(source.placement_width(), source.placement_height())
	var selector := source.appearance
	if source.is_in_parts_bin() or not initially_connected_to_primary(source, puzzle):
		selector = 0
	var sizes: Array = geometry.get("frame_sizes", [])
	if sizes.is_empty():
		sizes = geometry.get("sprite_frame_sizes", [])
	if selector < 0 or selector >= sizes.size():
		return Vector2i(source.placement_width(), source.placement_height())
	return Vector2i(int(sizes[selector][0]), int(sizes[selector][1]))
