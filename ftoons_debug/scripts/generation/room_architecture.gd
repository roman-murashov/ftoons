extends RefCounted
## Compose native, collidable scenery around a solved mechanism. Keep existing
## slots stable because native cables, tunnels and goal selectors use them.
const Document = preload("res://scripts/io/home_toons_document.gd")
const WALLS := [26, 27, 28, 29, 82, 83]
const PITCH := 16
const GRID := Rect2i(5, 8, 544, 384)
const THEMES := [
	{"name":"Foundry", "beam":26, "post":28, "roof":48},
	{"name":"Timber Mill", "beam":27, "post":29, "roof":50},
	{"name":"Quarry", "beam":28, "post":27, "roof":49},
	{"name":"Trading Post", "beam":29, "post":27, "roof":48},
	{"name":"Fossil Hall", "beam":82, "post":28, "roof":84},
	{"name":"Sweet Shop", "beam":83, "post":27, "roof":47},
]

static func compose(document: Dictionary, rng: RandomNumberGenerator, reserved_areas: Array = []) -> Dictionary:
	var occupied: Array[Rect2i] = []
	var platforms: Array[Rect2i] = []
	var editable: Array[Dictionary] = []
	var palettes := THEMES.duplicate()
	for row: Dictionary in document.parts:
		if int(row.part_type) in [1, 14, 76]: continue
		var bounds := _bounds(row)
		if not bounds.has_area(): continue
		occupied.append(bounds)
		if not int(row.part_type) in WALLS or not int(row.flags_3) & 0x40: continue
		platforms.append(bounds)
		if GRID.encloses(bounds) and (bounds.size.x == PITCH or bounds.size.y == PITCH):
			editable.append(row)
	# Give an existing building material a say in the new set's art direction.
	if not editable.is_empty():
		var accent := int(editable[rng.randi_range(0, editable.size() - 1)].part_type)
		for theme: Dictionary in THEMES:
			if theme.beam == accent: palettes.append_array([theme, theme, theme])
	var theme: Dictionary = palettes[rng.randi_range(0, palettes.size() - 1)]
	_reserve_links(document, occupied)
	# Native goal variants can provide swept areas from a successful replay.
	# Keep gaps along those routes open even when they start the puzzle empty.
	occupied.append_array(reserved_areas)
	var style := rng.randi_range(0, 2)
	var width := 2 * rng.randi_range(2, 4)
	var height := rng.randi_range(4 if style == 0 else 3, 5)
	var site := _find_site(occupied, platforms, Vector2i(width, height), rng)
	if not site.has_area():
		width = 4
		height = 3
		if style == 0: style = 1
		site = _find_site(occupied, platforms, Vector2i(width, height), rng)
	if not site.has_area():
		style = 3
		width = 2
		height = 3
		site = _find_site(occupied, platforms, Vector2i(width, height), rng)
	if not site.has_area(): return {}

	# An edge-of-stage building gets its own sill. Buildings on an existing
	# floor instead leave their lower story open to the original platform.
	var sill := site.end.y == GRID.end.y and (height >= 4 or style == 2)
	if sill and style == 0 and height == 4: style = 1
	if sill: height -= 1
	var pieces := _members(style, width, height, theme, rng.randi_range(0, 1) == 1)
	if sill:
		pieces.append({"type":theme.beam, "cells":Rect2i(0, height, width, 1)})
	var added_walls := 0
	var added_accents := 0
	for member: Dictionary in pieces:
		var cells: Rect2i = member.cells
		var bounds := Rect2i(site.position + cells.position * PITCH, cells.size * PITCH)
		var row := _make_part(document.parts.size(), member.type, bounds, member.get("flip", false))
		document.parts.append(row)
		if int(row.part_type) in WALLS: added_walls += 1
		else: added_accents += 1
	occupied.append(site)
	var rebuilt := _extend_wall(editable, occupied, rng)
	return {"theme":theme.name, "layout":["Roofed passage", "Loading dock", "Ramp terrace", "Ladder landing"][style],
		"added_walls":added_walls, "added_accents":added_accents, "rebuilt_walls":rebuilt}

static func _bounds(row: Dictionary) -> Rect2i:
	return Rect2i(int(row.pos_x), int(row.pos_y), int(row.width_1), int(row.height_1))

static func _reserve_links(document: Dictionary, occupied: Array[Rect2i]) -> void:
	# The connector's own serialized coordinates do not locate its visible line.
	for graph: Dictionary in document.ropes + document.belts:
		var route: Array = graph.get("route", graph.get("ends", []))
		for i in range(1, route.size()):
			var a := _anchor(document, graph, route, i - 1)
			var b := _anchor(document, graph, route, i)
			var steps := maxi(1, ceili(a.distance_to(b) / 8.0))
			for step in range(steps + 1):
				var at := Vector2i(a.lerp(b, float(step) / steps))
				occupied.append(Rect2i(at - Vector2i(4, 4), Vector2i(8, 8)))

static func _anchor(document: Dictionary, graph: Dictionary, route: Array, i: int) -> Vector2:
	var row: Dictionary = document.parts[int(route[i])]
	if graph.has("ends"):
		return Vector2(int(row.pos_x) + int(row.belt_connect_pos_x), int(row.pos_y) + int(row.belt_connect_pos_y))
	if i == 0 or i == route.size() - 1:
		var key := "rope_%d_connect_pos_" % (1 + int(graph.slots[0 if i == 0 else 1]))
		return Vector2(int(row.pos_x) + int(row[key + "x"]), int(row.pos_y) + int(row[key + "y"]))
	return Vector2(_bounds(row).get_center())

static func _find_site(occupied: Array[Rect2i], platforms: Array[Rect2i], cells: Vector2i,
		rng: RandomNumberGenerator) -> Rect2i:
	var best := Rect2i()
	var high_score := -1.0
	var size := cells * PITCH
	for y in range(GRID.position.y, GRID.end.y - size.y + 1, PITCH):
		for x in range(GRID.position.x, GRID.end.x - size.x + 1, PITCH):
			var box := Rect2i(Vector2i(x, y), size)
			# Every set stands on an existing ledge or reaches the stage floor.
			var left_foot := false
			var right_foot := false
			for platform in platforms:
				if platform.position.y != box.end.y: continue
				left_foot = left_foot or (platform.position.x <= x and platform.end.x >= x + PITCH)
				right_foot = right_foot or (platform.position.x <= box.end.x - PITCH and platform.end.x >= box.end.x)
			var grounded := left_foot and right_foot
			if not grounded and box.end.y != GRID.end.y: continue
			if not _clear(box, occupied): continue
			var score := rng.randf() + (1.0 if grounded else 0.0)
			if score > high_score:
				high_score = score
				best = box
	return best

static func _clear(area: Rect2i, occupied: Array[Rect2i]) -> bool:
	for obstacle in occupied:
		if area.intersects(obstacle): return false
	return true

static func _members(style: int, w: int, h: int, theme: Dictionary, flip: bool) -> Array:
	var members: Array
	@warning_ignore("integer_division")
	var half := w / 2
	match style:
		0: # Pitched roof, load-bearing piers and an open doorway.
			members = [
				{"type":theme.roof, "cells":Rect2i(0, 0, half, 2), "flip":true},
				{"type":theme.roof, "cells":Rect2i(half, 0, half, 2)},
				{"type":theme.beam, "cells":Rect2i(0, 2, w, 1)},
			]
			members.append({"type":theme.post, "cells":Rect2i(0, 3, 1, h - 3)})
			members.append({"type":theme.post, "cells":Rect2i(w - 1, 3, 1, h - 3)})
		1: # An accessible mezzanine, with a ladder under the open end.
			members = [
				{"type":theme.beam, "cells":Rect2i(0, 0, w, 1)},
				{"type":theme.post, "cells":Rect2i(0, 1, 1, h - 1)},
				{"type":45, "cells":Rect2i(w - 2, 1, 2, h - 1)},
			]
		2: # The upper walk connects to a lower landing via a native incline.
			members = [
				{"type":theme.beam, "cells":Rect2i(0, 0, w - 3, 1)},
				{"type":theme.post, "cells":Rect2i(0, 1, 1, h - 1)},
				{"type":theme.roof, "cells":Rect2i(w - 3, 0, 2, 2)},
				{"type":theme.beam, "cells":Rect2i(w - 1, 1, 1, 1)},
			]
			if h > 2: members.append({"type":theme.post, "cells":Rect2i(w - 1, 2, 1, h - 2)})
		_: # A narrow platform can still fit between packed campaign machinery.
			members = [
				{"type":theme.beam, "cells":Rect2i(0, 0, 2, 1)},
				{"type":45, "cells":Rect2i(0, 1, 2, h - 1)},
			]
	if flip:
		for item: Dictionary in members:
			var rect: Rect2i = item.cells
			rect.position.x = w - rect.end.x
			item.cells = rect
			if item.type == theme.roof: item.flip = not item.get("flip", false)
	return members

static func _make_part(index: int, type: int, bounds: Rect2i, flip: bool) -> Dictionary:
	var row := Document.factory_row(type, "room-member-%d" % index)
	row.flags_2 = (int(row.flags_2) & ~0x10) | (0x10 if flip else 0)
	row.flags_3 = int(row.flags_3) | 0x40
	_set_bounds(row, bounds)
	if type in [47, 48, 49, 50, 84]:
		row.appearance = (bounds.size.x >> 4) - 1
		row.height_2 = PITCH
	return row

static func _set_bounds(row: Dictionary, bounds: Rect2i) -> void:
	row.pos_x = bounds.position.x
	row.pos_y = bounds.position.y
	row.width_1 = bounds.size.x
	row.width_2 = bounds.size.x
	row.height_1 = bounds.size.y
	row.height_2 = bounds.size.y

static func _extend_wall(walls: Array[Dictionary], occupied: Array[Rect2i], rng: RandomNumberGenerator) -> int:
	if walls.is_empty(): return 0
	var start := rng.randi_range(0, walls.size() - 1)
	for i in walls.size():
		var wall: Dictionary = walls[(start + i) % walls.size()]
		var original := _bounds(wall)
		var horizontal := original.size.y == PITCH
		var forward := rng.randi_range(0, 1) == 1
		var length := PITCH * rng.randi_range(1, 3)
		for side in 2:
			for distance in range(length, 0, -PITCH):
				var size := Vector2i(distance, PITCH) if horizontal else Vector2i(PITCH, distance)
				var offset := Vector2i(original.size.x if forward else -distance, 0)
				if not horizontal: offset = Vector2i(0, original.size.y if forward else -distance)
				var addition := Rect2i(original.position + offset, size)
				if GRID.encloses(addition) and _clear(addition, occupied):
					_set_bounds(wall, original.merge(addition))
					return 1
			forward = not forward
	return 0
