extends RefCounted
## JSON keeps the executable goal, original part IDs and generator witnesses.
## Native LEV stores the construction and the goal text. DOS selects compiled
## campaign callbacks externally; a custom LEV is judged by its player.
const Document := preload("res://scripts/io/home_toons_document.gd")
const Reader := preload("res://scripts/io/level_reader.gd")
var error := ""

func encode(document: Dictionary, extension: String) -> PackedByteArray:
	error = ""
	var format := extension.trim_prefix(".").to_lower()
	var codec := Document.new()
	var puzzle := codec.decode(document, "generated.json")
	if puzzle == null:
		error = codec.error
		return PackedByteArray()
	match format:
		"json":
			return (JSON.stringify(document, "\t") + "\n").to_utf8_buffer()
		"lev":
			return _native_level(document, puzzle)
	error = "Choose a .json or .lev file."
	return PackedByteArray()

func save_file(path: String, document: Dictionary, overwrite := false) -> bool:
	var bytes := encode(document, path.get_extension())
	if bytes.is_empty(): return false
	if FileAccess.file_exists(path) and not overwrite:
		error = "A file with this name already exists."
		return false
	var destination := ProjectSettings.globalize_path(path)
	if DirAccess.make_dir_recursive_absolute(destination.get_base_dir()) != OK:
		error = "Could not create the export folder."
		return false
	var temporary := "%s.%d-%d.tmp" % [destination, OS.get_process_id(), Time.get_ticks_usec()]
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		error = "Could not open the export file for writing."
		return false
	file.store_buffer(bytes)
	file.flush()
	var complete := file.get_error() == OK and file.get_position() == bytes.size()
	file.close()
	if complete and DirAccess.rename_absolute(temporary, destination) == OK:
		return true
	DirAccess.remove_absolute(temporary)
	error = "Could not finish writing the export file."
	return false

func _native_level(document: Dictionary, puzzle: PuzzleDefinition) -> PackedByteArray:
	# All generated names and instructions are English. Reject a non-ASCII
	# string instead of silently losing characters in the DOS text fields.
	for value: String in [puzzle.title, puzzle.instructions]:
		for i in value.length():
			var code := value.unicode_at(i)
			if code == 0 or code > 127:
				error = "LEV text requires DOS-compatible ASCII characters."
				return PackedByteArray()
	for transform: Dictionary in puzzle.editor_transforms:
		if transform.rotation != 0 or transform.mirror_x or transform.mirror_y:
			error = "Use JSON to preserve Godot-only rotations and mirrors."
			return PackedByteArray()
	# DOS consumes two consecutive record lists. Pin state is an independent
	# field: an unpinned fixed gadget still belongs in the static list.
	var statics: Array[int] = []
	var movers: Array[int] = []
	for i in puzzle.parts.size():
		if puzzle.parts[i].flags_1 & 0x6000:
			statics.append(i)
		else:
			movers.append(i)
	var order := statics + movers
	var new_index := {-1: -1}
	for i in order.size():
		new_index[order[i]] = i
	var pulley_owners := {}
	for rope in document.ropes:
		for pulley in rope.route.slice(1, -1):
			pulley_owners[int(pulley)] = new_index[int(rope.owner)]
	var objects := []
	for original_index in order:
		var part := puzzle.parts[original_index]
		var row := {
			"type": part.part_type, "flags_1": part.flags_1 | (0x2000 if part.flags_1 & 0x6000 else 0),
			"flags_2": part.flags_2, "flags_3": part.flags_3, "flipped": part.initial_flip_x(),
			"flipped_y": part.initial_flip_y(), "appearance": part.appearance, "unknown_10": part.unknown_10,
			"width": part.width_1, "height": part.height_1, "width_2": part.width_2, "height_2": part.height_2,
			"x": part.pos_x, "y": part.pos_y, "behavior": part.behavior, "version_byte": 0,
			"wire_terminal": part.wire_terminal, "belt_present": int(not part.belt_endpoints.is_empty()),
			"belt_anchor_x": part.belt_connect_pos_x, "belt_anchor_y": part.belt_connect_pos_y,
			"belt_line_distance": part.belt_line_distance, "belt_endpoints": [],
			"rope_slots": [{"present": 0, "x": part.rope_1_connect_pos_x, "y": part.rope_1_connect_pos_y},
				{"present": 0, "x": part.rope_2_connect_pos_x, "y": part.rope_2_connect_pos_y}],
			"pulley_rope_owner": pulley_owners.get(original_index, -1),
		}
		for field in Document.LINKS:
			row[field] = new_index[part.get(field)]
		for endpoint in part.belt_endpoints:
			row.belt_endpoints.append(new_index[endpoint])
		if not part.rope_slots.is_empty():
			var rope: Dictionary = part.rope_slots[0]
			row.rope_slots[0].merge({"present": 1, "ends": [new_index[rope.ends[0]], new_index[rope.ends[1]]],
					"slots": rope.slots}, true)
		elif part.part_type == 17:
			row.rope_slots[0].merge({"present": 1, "ends": [-1, -1], "slots": [0, 0]}, true)
		objects.append(row)
	# The two -8 header words and 0x0106 version match original Home Toons saves.
	var packed := {"format": "sid-and-al-level-v2", "source_name": "Generated LEV",
		"version": 0x0106, "title": puzzle.title, "instructions": puzzle.instructions,
		"pressure": puzzle.pressure, "gravity": puzzle.gravity, "music": puzzle.music,
		"unknown_4": -8, "unknown_6": -8, "fixed_count": statics.size(), "moving_count": movers.size(),
		"object_list": objects}
	var reader := Reader.new(null)
	var bytes := reader.encode_export(packed)
	if bytes.is_empty():
		error = "Could not encode the native LEV records. " + reader.last_error
	return bytes
