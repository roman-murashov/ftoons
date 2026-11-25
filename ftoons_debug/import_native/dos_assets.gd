extends RefCounted
## Recover the actual DOS resource archive and editable campaign documents.
## All writes are to the caller's unpublished staging directory. Existing
## Godot graphics/font decoders consume the archive payloads without conversion.

const Reader := preload("res://scripts/io/level_reader.gd")
const Goals := preload("res://scripts/data/original_goal_catalog.gd")
const TYPES := "res://port_data/original/part_type_names.json"
const EXE_SHA := "cc37575f7bf1f36ac1b2083f82095930fc2d132881f9b619de46452210c30fc1"
const ARCHIVE_SHA := "30bb21ea0cd1fc87ceb83dc804639f86cf115e815e1de301d561d2ec3be4b87e"
const ADLIB_SHA := "f1d093291b4395e485e9d19cb6684ffecf3c5dab31f2462264bf6fd4f15907af"
const PROGRAM_FIELDS := {
	20: "ammo_count", 22: "boulder_count", 38: "programmed_time",
	39: "programmed_count", 59: "banana_setting", 69: "egg_count",
}

var error := ""

## Return counts on success or a player-facing error on failure.
func import_dos(source_directory: String, staging_root: String) -> Dictionary:
	error = ""
	var sources := {}
	for leaf in DirAccess.get_files_at(source_directory):
		sources[leaf.to_upper()] = source_directory.path_join(leaf)
	for pair in [["TOONS.EXE", EXE_SHA], ["RESOURCE.001", ARCHIVE_SHA], ["ADL.DRV", ADLIB_SHA]]:
		if not sources.has(pair[0]):
			return _failed("The selected DOS folder is missing %s." % pair[0])
		if FileAccess.get_sha256(sources[pair[0]]) != pair[1]:
			return _failed("The DOS revision of %s is unsupported." % pair[0])
	var type_info: Variant = JSON.parse_string(FileAccess.get_file_as_string(TYPES))
	if not type_info is Dictionary or not type_info.get("types") is Array:
		return _failed("Missing part type labels in the debug project.")
	var labels := {}
	var separator := RegEx.create_from_string("[^a-z0-9]+")
	for entry in type_info.types:
		var id := int(entry.id)
		labels[id] = separator.sub(entry.name.to_lower(), "_", true).trim_suffix("_") if entry.name is String else "type_%d" % id
	var original := staging_root.path_join("assets/original")
	var payloads := original.path_join("payloads")
	var levels := staging_root.path_join("assets/levels")
	for folder in [payloads, levels]:
		if DirAccess.make_dir_recursive_absolute(folder) != OK:
			return _failed("Cannot create %s." % folder)
	var archive := FileAccess.get_file_as_bytes(sources["RESOURCE.001"])
	var entries := []
	var seen := {}
	var offset := 0
	var level_count := 0
	var reader := Reader.new(null)
	var valid_name := RegEx.create_from_string("^[A-Z0-9_&-]{1,8}\\.[A-Z0-9]{1,3}$")
	while offset < archive.size():
		if offset + 17 > archive.size():
			return _failed("Truncated DOS archive header.")
		var name := archive.slice(offset, offset + 13).get_string_from_ascii()
		var start := offset + 17
		var length := archive.decode_u32(offset + 13)
		if valid_name.search(name) == null or seen.has(name) or start + length > archive.size():
			return _failed("Invalid resource at byte %d of RESOURCE.001." % offset)
		var data := archive.slice(start, start + length)
		var relative := "assets/original/payloads/" + name + ".bin"
		if not _write(staging_root.path_join(relative), data):
			return _failed(error)
		var digest := HashingContext.new()
		digest.start(HashingContext.HASH_SHA256)
		digest.update(data)
		entries.append({
			"archive": "RESOURCE.001", "name": name, "type": name.get_extension(),
			"asset_path": "res://" + relative, "offset": offset, "payload_offset": start,
			"size": length, "sha256": digest.finish().hex_encode(),
		})
		if name.get_extension() == "LEV":
			var level := reader.parse_bytes(name, data, "campaign")
			if not level.scan_error.is_empty():
				return _failed("Cannot decode %s: %s" % [name, level.scan_error])
			if not _json(levels.path_join(name.get_basename() + ".json"), _level_document(level, labels)):
				return _failed(error)
			level_count += 1
		seen[name] = true
		offset = start + length
	var exe := FileAccess.get_file_as_bytes(sources["TOONS.EXE"])
	var table_offset := (exe.decode_u16(8) + 0x340f) * 16
	if not _write(original.path_join("reaction_tables.bin"), exe.slice(table_offset, table_offset + 65536)):
		return _failed(error)
	if not _json(original.path_join("resource_index.json"), {
		"format": "sid_al_resource_index_v1", "source_archive": "RESOURCE.001",
		"entry_count": entries.size(), "entries": entries,
	}):
		return _failed(error)
	return {"ok": true, "resources": entries.size(), "levels": level_count}


func _failed(message: String) -> Dictionary:
	return {"ok": false, "error": message}


func _write(path: String, bytes: PackedByteArray) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null or not f.store_buffer(bytes):
		error = "Could not write %s. Check permissions and available disk space." % path
		return false
	f.flush()
	if f.get_error() != OK:
		error = "Could not finish writing " + path
		return false
	return true


func _json(path: String, document: Dictionary) -> bool:
	return _write(path, (JSON.stringify(document, "  ", false) + "\n").to_utf8_buffer())


## Write readable v3 objects from the game's normal level parser, preserving
## raw flag bits and trailing bytes for lossless round trips through LevelReader.
func _level_document(p: PuzzleDefinition, labels: Dictionary) -> Dictionary:
	var doc := {
		"format": "sid-and-al-level-v3", "source_name": p.source_name, "construction_context": "campaign",
		"version": p.format_version, "title": p.title, "instructions": p.instructions,
	}
	if Goals.level_index(p.source_name) >= 0:
		doc.goals = {"version": 1, "original": p.source_name}
	for field in Reader.HEADER_WORDS:
		doc[field] = p.get(field)
	var objects := []
	for part in p.parts:
		objects.append(_part_document(part, labels, p.format_version))
	doc.object_list = objects
	if not p.tail.is_empty():
		doc.trailing_bytes = Array(p.tail)
	return doc


func _part_document(part: PartDefinition, labels: Dictionary, version: int) -> Dictionary:
	var category := "unclassified"
	var category_bit := 0
	for pair in [[0x0800, "parts-bin"], [0x4000, "fixed"], [0x1000, "moving"]]:
		if part.flags_1 & int(pair[0]):
			category = pair[1]
			category_bit = pair[0]
			break
	var row := {
		"type": labels[part.part_type], "x": part.pos_x, "y": part.pos_y,
		"flipped": part.initial_flip_x(), "flipped_y": part.initial_flip_y(), "category": category,
		"uses_appearance_state": bool(part.flags_2 & 4096), "campaign_keep_on_stage": bool(part.flags_3 & 64),
		"appearance": part.appearance, "unmapped_word_at_offset_10": part.unknown_10,
		"width": part.width_1, "height": part.height_1, "stored_width": part.width_2, "stored_height": part.height_2,
	}
	if part.flags_1 & ~category_bit: row.additional_object_bits = part.flags_1 & ~category_bit
	if part.flags_2 & ~4144: row.additional_display_bits = part.flags_2 & ~4144
	if part.flags_3 & ~64: row.additional_state_bits = part.flags_3 & ~64
	row.behavior = part.behavior
	row.belt_present = part.unknown_26
	row.belt_anchor_x = part.belt_connect_pos_x
	row.belt_anchor_y = part.belt_connect_pos_y
	row.belt_line_distance = part.belt_line_distance
	if part.unknown_26: row.belt_endpoints = part.belt_endpoints
	row.rope_slots = []
	for slot in part.rope_slots:
		var rope := {"present": slot.present, "x": slot.anchor.x, "y": slot.anchor.y}
		if slot.present:
			rope.ends = slot.ends
			rope.slots = slot.slots
		row.rope_slots.append(rope)
	for field in ["connected_1", "connected_2", "outlet_plugged_1", "outlet_plugged_2"]:
		row[field] = part.get(field)
	if part.part_type == 17: row.pulley_rope_owner = part.pulley_rope_owner
	if part.part_type == 46: row.tunnel_partner = part.tunnel_partner
	if version > 261: row.version_byte = part.raw_record[part.wire_fields.version_byte]
	var setting := part.wire_terminal
	if PROGRAM_FIELDS.has(part.part_type):
		row[PROGRAM_FIELDS[part.part_type]] = setting & 255 if part.part_type in [38, 39] else setting
		if part.part_type == 38 and (setting & ~255):
			row.additional_program_bits = setting & ~255
		if part.part_type == 39:
			row.reverse_count_direction = bool(setting & 0x4000)
			if setting & ~0x40ff: row.additional_program_bits = setting & ~0x40ff
	elif part.part_type == 42:
		row.letter = String.chr(setting & 255)
		if setting >> 8: row.setting_high_byte = setting >> 8
	else:
		row.wire_terminal = setting
	return row
