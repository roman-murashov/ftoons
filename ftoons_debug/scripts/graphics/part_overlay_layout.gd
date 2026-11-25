class_name PartOverlayLayout
extends RefCounted

## Original five-byte neighbor tables and 198D:3504 destination calculation.
## The offsets describe sprite top-left pixels, not centers or pivots.
var _data: Dictionary = {}
var _width_codes := PackedInt32Array()
var _height_codes := PackedInt32Array()

func _init() -> void:
	var file := FileAccess.open("res://assets/original/part_overlay_tables.json", FileAccess.READ)
	if file != null:
		var parsed = JSON.parse_string(file.get_as_text())
		if parsed is Dictionary:
			_data = parsed
			# JSON numbers are floats; normalize before integer membership checks.
			_width_codes = PackedInt32Array(parsed.get("second_neighbor_add_width", []))
			_height_codes = PackedInt32Array(parsed.get("second_neighbor_add_height", []))

func draw_commands(part_type: int, rect: Rect2, neighbors: Vector2i) -> Array[Dictionary]:
	var commands: Array[Dictionary] = []
	var table: Dictionary = _data.get("tables", {}).get(str(part_type), {})
	var entries: Array = table.get("entries", [])
	for slot in range(2):
		var code: int = neighbors[slot]
		if code <= 0 or code >= entries.size():
			continue
		var entry: Dictionary = entries[code]
		var destination := rect.position + Vector2(entry.x, entry.y)
		if slot == 1:
			if code in _width_codes:
				destination.x += rect.size.x
			elif code in _height_codes:
				destination.y += rect.size.y
		commands.append({"code": code, "frame": int(entry.frame), "position": destination})
	return commands

func supports(part_type: int) -> bool:
	return _data.get("tables", {}).has(str(part_type))
