class_name LevelReader
extends RefCounted

const ResourceCatalog = preload("res://scripts/io/resource_catalog.gd")
const PartDefinition = preload("res://scripts/data/part_definition.gd")
const PuzzleDefinition = preload("res://scripts/data/puzzle_definition.gd")
const OriginalGoals = preload("res://scripts/data/original_goal_catalog.gd")
const WindowsPuzzles = preload("res://scripts/io/head_to_head_library.gd")

const LEVEL_FOLDER := "res://assets/levels"
const ADD_ON_FOLDER := "res://dlc_win_data"
const ADD_ON_FLAG := "--dlc-win-data"
const HEADER_WORDS := ["pressure", "gravity", "unknown_4", "unknown_6", "music", "fixed_count", "moving_count"]

var catalog: ResourceCatalog
var last_error: String = ""
var _windows_puzzles: WindowsPuzzles

func _windows() -> WindowsPuzzles:
	if _windows_puzzles == null:
		_windows_puzzles = WindowsPuzzles.new()
	return _windows_puzzles

func _init(resource_catalog: ResourceCatalog) -> void:
	catalog = resource_catalog

func list_levels() -> Array:
	var result: Array = []
	var groups: Array = [[], [], [], [], []]
	var campaign_prefixes := ["CAKE", "BRAN", "HARD", "LOON"]
	# ResourceCatalog stores the extension without the leading dot ("LEV").
	# The previous ".LEV" filter returned an empty list, leaving the Puzzles
	# tab with no selected level and no inventory controls to operate.
	for entry in catalog.entries():
		if String(entry.get("type", "")) in ["LEV", "ITL"]:
			var name := String(entry.get("name", ""))
			var group := campaign_prefixes.size()
			if name.get_extension().to_upper() == "LEV" and String(entry.get("construction_context", "")) != "home_toons":
				var basename := name.get_basename().to_upper()
				for index in campaign_prefixes.size():
					var prefix: String = campaign_prefixes[index]
					if basename.begins_with(prefix) and basename.substr(prefix.length()).is_valid_int():
						group = index
						break
			groups[group].append(name)
	for group in groups:
		group.sort_custom(func(a: String, b: String) -> bool: return a.naturalnocasecmp_to(b) < 0)
		result.append_array(group)
	var folders := [preload("res://scripts/io/home_toons_document.gd").default_folder()]
	if OS.get_cmdline_user_args().has(ADD_ON_FLAG):
		folders.append(ADD_ON_FOLDER.path_join("levels"))
	for folder: String in folders:
		if not DirAccess.dir_exists_absolute(folder):
			continue
		var custom: Array[String] = []
		for file in DirAccess.get_files_at(folder):
			if file.get_extension().to_lower() == "json":
				custom.append(folder.path_join(file))
		custom.sort_custom(func(a: String, b: String): return a.naturalnocasecmp_to(b) < 0)
		result.append_array(custom)
	# Keep authored puzzles accessible at the front of Home Toons. The Windows
	# importer orders its PLAY entries by puzzle number.
	for entry: Dictionary in _windows().levels:
		result.append(entry.source)
	return result

## The Piggy Bank can display Windows titles from their imported index.
## Verify and decode the binary board when the player chooses Load.
func menu_entry(source: String) -> Dictionary:
	if source.get_extension() == "H2H":
		var entry: Dictionary = _windows().entries_by_source.get(source, {})
		if entry.is_empty(): return {}
		return {"source": source, "title": entry.title}
	var puzzle := read_level(source)
	return {"source": source, "title": puzzle.title} if puzzle != null else {}

func read_level(name: String) -> PuzzleDefinition:
	last_error = ""
	if name.get_extension() == "H2H":
		var library := _windows()
		var entry: Dictionary = library.entries_by_source.get(name, {})
		if entry.is_empty():
			last_error = "Unknown Windows puzzle: " + name
			return null
		var windows_puzzle := library.load_puzzle(int(entry.number))
		last_error = library.error
		return windows_puzzle
	var path := name
	if name.get_extension().to_upper() == "LEV":
		path = LEVEL_FOLDER.path_join(name.get_file().get_basename().to_upper() + ".json")
	if path.get_base_dir() == LEVEL_FOLDER and FileAccess.file_exists(path):
		return _read_export(path)
	if name.get_extension().to_lower()=="json":
		var codec:=preload("res://scripts/io/home_toons_document.gd").new()
		var puzzle:=codec.load_file(name)
		last_error=codec.error
		return puzzle
	var bytes := catalog.read_asset(name)
	if bytes.is_empty():
		last_error = "missing level resource: %s" % name
		return null
	var entry := catalog.get_entry(name)
	return parse_bytes(name, bytes, String(entry.get("construction_context", "")))

func _read_export(path: String) -> PuzzleDefinition:
	last_error = "invalid level JSON: %s" % path
	var doc = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not doc is Dictionary or doc.get("format") not in ["sid-and-al-level-v1", "sid-and-al-level-v2", "sid-and-al-level-v3"]:
		return null
	for key in ["source_name", "construction_context", "title", "instructions"]:
		if not doc.get(key) is String:
			return null
	var packaged_source := path.get_file().get_basename().to_upper() + ".LEV"
	var is_campaign_export: bool = (path.get_base_dir() == LEVEL_FOLDER
		and doc.construction_context == "campaign" and String(doc.source_name).to_upper() == packaged_source)
	var goal_index := -1
	if doc.has("goals"):
		var reference: Variant = doc.goals
		if (not is_campaign_export or not reference is Dictionary or reference.size() != 2
			or not _valid_word(reference.get("version"), 1, 1)
			or not reference.get("original") is String or reference.original != packaged_source):
			last_error = "Invalid original goal reference in %s." % path
			return null
		goal_index = OriginalGoals.level_index(reference.original)
		if goal_index < 0 or OriginalGoals.dos_spec(goal_index).is_empty():
			last_error = "Unknown original goal reference in %s." % path
			return null
	elif is_campaign_export:
		# Packaged exports produced before explicit references used the resource name.
		goal_index = OriginalGoals.level_index(packaged_source)
	var bytes := encode_export(doc)
	if bytes.is_empty():
		return null
	last_error = ""
	return _parse_bytes(doc.source_name, bytes, doc.construction_context, goal_index)

## Shared LEV serializer for packaged level JSON and generated constructions.
func encode_export(doc: Dictionary) -> PackedByteArray:
	var records := PackedByteArray()
	if doc.format != "sid-and-al-level-v1":
		var stream := StreamPeerBuffer.new()
		if not _write_objects(doc, stream):
			return PackedByteArray()
		records = stream.data_array
	else:
		if not doc.get("records_hex") is String:
			return PackedByteArray()
		records = String(doc.records_hex).hex_decode()
		if records.hex_encode() != String(doc.records_hex).to_lower():
			return PackedByteArray()
	var bytes := PackedByteArray([0xee, 0xac, 0, 0])
	if not _valid_word(doc.get("version"), 0, 65535):
		return PackedByteArray()
	bytes.encode_u16(2, int(doc.version))
	for key in ["title", "instructions"]:
		bytes.append_array(String(doc[key]).to_ascii_buffer())
		bytes.append(0)
	for key in HEADER_WORDS:
		if not _valid_word(doc.get(key), -32768, 32767):
			return PackedByteArray()
		var offset := bytes.size()
		bytes.resize(offset + 2)
		bytes.encode_s16(offset, int(doc[key]))
	bytes.append_array(records)
	return bytes

static var _object_ids := {}

func _write_objects(doc: Dictionary, stream: StreamPeerBuffer) -> bool:
	if _object_ids.is_empty():
		var names = JSON.parse_string(FileAccess.get_file_as_string("res://assets/original/part_type_names.json"))
		var separator := RegEx.create_from_string("[^a-z0-9]+")
		for entry in names.types:
			var label := "type_%d" % int(entry.id)
			if entry.name is String:
				label = separator.sub(String(entry.name).to_lower(), "_", true).trim_suffix("_")
			_object_ids[label] = int(entry.id)
	if not doc.get("object_list") is Array or not _valid_word(doc.get("fixed_count"), 0, 32767) or not _valid_word(doc.get("moving_count"), 0, 32767):
		return false
	if doc.object_list.size() != int(doc.fixed_count + doc.moving_count):
		return false
	for row in doc.object_list:
		if not row is Dictionary:
			return false
		var type_id: Variant = _object_ids.get(row.get("type"), row.get("type"))
		if not _valid_word(type_id, 0, 84):
			return false
		var kind := int(type_id)
		stream.put_u16(kind)
		if doc.format == "sid-and-al-level-v3":
			const CATEGORY_BITS := {"fixed": 16384, "moving": 4096, "parts-bin": 2048, "unclassified": 0}
			if not CATEGORY_BITS.has(row.get("category")):
				last_error = "Unknown object category in %s: %s" % [doc.source_name, row.get("category")]
				return false
			row.flags_1 = int(CATEGORY_BITS[row.category]) | int(row.get("additional_object_bits", 0))
			row.flags_2 = int(row.get("additional_display_bits", 0)) | (4096 if row.uses_appearance_state else 0)
			row.flags_3 = int(row.get("additional_state_bits", 0)) | (64 if row.campaign_keep_on_stage else 0)
			row.unknown_10 = row.unmapped_word_at_offset_10
			row.width_2 = row.stored_width
			row.height_2 = row.stored_height
		stream.put_u16(int(row.flags_1))
		stream.put_u16((int(row.flags_2) & ~48) | (16 if row.flipped else 0) | (32 if row.flipped_y else 0))
		for field in ["flags_3", "appearance", "unknown_10", "width", "height", "width_2", "height_2", "x", "y", "behavior", "belt_present"]:
			stream.put_u16(int(row[field]))
		stream.put_u8(int(row.belt_anchor_x))
		stream.put_u8(int(row.belt_anchor_y))
		stream.put_u16(int(row.belt_line_distance))
		if row.belt_present:
			for endpoint in row.belt_endpoints:
				stream.put_16(int(endpoint))
		for slot in row.rope_slots:
			stream.put_u16(int(slot.present))
			stream.put_8(int(slot.x))
			stream.put_8(int(slot.y))
			if slot.present:
				for end in slot.ends:
					stream.put_16(int(end))
				for index in slot.slots:
					stream.put_u8(int(index))
		for field in ["connected_1", "connected_2", "outlet_plugged_1", "outlet_plugged_2"]:
			stream.put_16(int(row[field]))
		if kind in [17, 46]:
			stream.put_16(int(row.pulley_rope_owner if kind == 17 else row.tunnel_partner))
		if doc.version > 261:
			stream.put_u8(int(row.version_byte))
		const PROGRAM_FIELDS := {20: "ammo_count", 22: "boulder_count", 38: "programmed_time",
			39: "programmed_count", 59: "banana_setting", 69: "egg_count"}
		if PROGRAM_FIELDS.has(kind) and row.has(PROGRAM_FIELDS[kind]):
			var value = row[PROGRAM_FIELDS[kind]]
			var maximum := 255 if kind in [38, 39] else 65535
			if not _valid_word(value, 0, maximum):
				last_error = "Invalid %s in %s" % [PROGRAM_FIELDS[kind], doc.source_name]
				return false
			var setting := int(value)
			if kind in [38, 39]:
				var extra = row.get("additional_program_bits", 0)
				var reserved := 0x40ff if kind == 39 else 255
				if not _valid_word(extra, 0, 65535) or (int(extra) & reserved) != 0:
					return false
				setting |= int(extra)
			if kind == 39:
				if not row.get("reverse_count_direction", false) is bool:
					return false
				if row.get("reverse_count_direction", false):
					setting |= 0x4000
			stream.put_u16(setting)
		elif kind == 42 and row.has("letter"):
			var letter = row.letter
			var high_byte = row.get("setting_high_byte", 0)
			if not letter is String or letter.length() != 1 or letter.unicode_at(0) > 255 or not _valid_word(high_byte, 0, 255):
				last_error = "Invalid message machine character in %s" % doc.source_name
				return false
			stream.put_u16((int(high_byte) << 8) | int(letter.unicode_at(0)))
		else:
			stream.put_u16(int(row.wire_terminal))
	for value in doc.get("trailing_bytes", []):
		stream.put_u8(int(value))
	return true

func _valid_word(value: Variant, minimum: int, maximum: int) -> bool:
	return (value is float or value is int) and value == int(value) and value >= minimum and value <= maximum

func parse_bytes(name: String, bytes: PackedByteArray, construction_context: String = "") -> PuzzleDefinition:
	return _parse_bytes(name, bytes, construction_context, OriginalGoals.level_index(name))

func _parse_bytes(name: String, bytes: PackedByteArray, construction_context: String, goal_index: int) -> PuzzleDefinition:
	var puzzle := PuzzleDefinition.new()
	puzzle.name = name.get_basename()
	puzzle.source_name = name
	puzzle.construction_context = construction_context if not construction_context.is_empty() else ("home_toons" if name.get_extension().to_upper() == "ITL" else "campaign")
	if puzzle.construction_context == "campaign":
		puzzle.campaign_goal_index = goal_index
	puzzle.source_size = bytes.size()
	puzzle.logical_length = bytes.size()
	puzzle.magic = _hex_prefix(bytes, 4)
	if bytes.size() < 4:
		puzzle.scan_error = "truncated level prefix"
		puzzle.tail_offset = 0
		puzzle.tail = bytes
		return puzzle
	puzzle.format_magic = _u16(bytes, 0)
	puzzle.format_version = _u16(bytes, 2)
	if puzzle.format_magic != 0xACEE:
		puzzle.scan_error = "invalid level magic 0x%04X" % puzzle.format_magic
		puzzle.tail_offset = 0
		puzzle.tail = bytes
		return puzzle
	var cursor := 4
	var title_result := _read_c_string(bytes, cursor)
	puzzle.title = title_result.text
	cursor = title_result.next_offset
	var instruction_result := _read_c_string(bytes, cursor)
	puzzle.instructions = instruction_result.text
	cursor = instruction_result.next_offset
	puzzle.header_offset = cursor
	if cursor + 14 > bytes.size():
		puzzle.scan_error = "truncated seven-word level header"
		puzzle.tail_offset = cursor
		puzzle.tail = bytes.slice(cursor)
		return puzzle
	puzzle.pressure = _i16(bytes, cursor)
	puzzle.gravity = _i16(bytes, cursor + 2)
	puzzle.unknown_4 = _i16(bytes, cursor + 4)
	puzzle.unknown_6 = _i16(bytes, cursor + 6)
	puzzle.music = _i16(bytes, cursor + 8)
	puzzle.fixed_count = _i16(bytes, cursor + 10)
	puzzle.moving_count = _i16(bytes, cursor + 12)
	cursor += 14
	var section_counts := [puzzle.fixed_count, puzzle.moving_count]
	var section_names := ["fixed", "moving"]
	var total_records: int = maxi(0, puzzle.fixed_count) + maxi(0, puzzle.moving_count)
	var decoded_records := 0
	for section_index in range(2):
		var section_count: int = maxi(0, int(section_counts[section_index]))
		for record_index in range(section_count):
			if cursor + 48 > bytes.size():
				puzzle.scan_error = "truncated %s record %d at 0x%X" % [section_names[section_index], record_index, cursor]
				break
			var part := _candidate(bytes, cursor)
			if part == null:
				puzzle.scan_error = "no %s record at 0x%X" % [section_names[section_index], cursor]
				break
			part.section = section_names[section_index]
			part.construction_context = puzzle.construction_context
			part.list_index = record_index
			puzzle.assign_goal_id(part)
			if part.part_type == 20:
				part.variant = "type20_parts_bin"
			elif part.part_type == 31:
				part.variant = "type31_moving_or_parts_bin"
			puzzle.parts.append(part)
			if section_index == 0:
				puzzle.fixed_parts.append(part)
			if section_index == 1:
				puzzle.moving_parts.append(part)
			if part.is_in_parts_bin() or (part.part_type == 20 and puzzle.construction_context == "campaign"):
				puzzle.inventory_parts.append(part)
			if part.part_type == 36 or part.part_type == 37:
				puzzle.actor_candidates.append(part)
			var serialized_size := part.wire_links_offset + 10 + (1 if puzzle.format_version > 0x0105 else 0) + (2 if part.part_type in [17,46] else 0)
			var next_offset := cursor + serialized_size
			if next_offset > bytes.size():
				puzzle.scan_error = "truncated %s record %d at 0x%X (need %d bytes)" % [section_names[section_index], record_index, cursor, serialized_size]
				break
			var records_left := total_records - decoded_records - 1
			if records_left > 0 and _candidate(bytes, next_offset) == null:
				puzzle.scan_error = "invalid next record after %s record %d at 0x%X" % [section_names[section_index], record_index, cursor]
				break
			part.record_size = next_offset - cursor
			part.raw_record = bytes.slice(cursor, next_offset)
			part.raw_common = bytes.slice(cursor, mini(cursor + 48, bytes.size()))
			if cursor + 50 <= bytes.size():
				part.wire_terminal = _u16(bytes, next_offset - 2)
			if part.part_type == 46:
				part.tunnel_partner = _i16(bytes, cursor + part.wire_links_offset + 8)
			if next_offset > cursor + 50:
				part.raw_extension = bytes.slice(cursor + 48, next_offset - 2)
			part.wire_fields = _common_wire_fields()
			part.wire_fields["wire_terminal"] = serialized_size - 2
			part.wire_fields["version_byte"] = serialized_size - 3 if puzzle.format_version > 0x0105 else -1
			part.wire_fields["type_extension"] = part.wire_links_offset + 8
			for k in ["connected_1","connected_2","outlet_plugged_1","outlet_plugged_2"]:
				part.wire_fields[k] += part.wire_links_offset - 40
			if part.part_type == 46: part.wire_fields["tunnel_partner"] = part.wire_links_offset + 8
			decoded_records += 1
			cursor = next_offset
		if not puzzle.scan_error.is_empty():
			break
	# 298D:5D59 removes a connected controller when an authored endpoint or
	# Pulley is returned to the campaign bin. Preserve the saved graph itself.
	if puzzle.construction_context == "campaign":
		for belt in puzzle.parts:
			if belt.part_type != 1: continue
			for endpoint in belt.belt_endpoints:
				if endpoint >= 0 and endpoint < puzzle.parts.size() and puzzle.parts[endpoint].is_in_parts_bin():
					belt.campaign_rope_inventory = true
		for rope in puzzle.parts:
			if rope.part_type != 14 or rope.rope_slots.is_empty(): continue
			var ends: Array = rope.rope_slots[0].ends
			for index in ends:
				if index >= 0 and index < puzzle.parts.size() and puzzle.parts[index].is_in_parts_bin():
					rope.campaign_rope_inventory = true
			for node in puzzle.parts:
				if node.part_type == 17 and node.pulley_rope_owner == puzzle.parts.find(rope) and node.is_in_parts_bin():
					rope.campaign_rope_inventory = true
	puzzle.inventory_parts.clear()
	for part in puzzle.parts:
		if part.is_in_parts_bin() or (part.part_type==20 and puzzle.construction_context=="campaign"): puzzle.inventory_parts.append(part)
	puzzle.tail_offset = cursor
	puzzle.tail = bytes.slice(cursor)
	puzzle.record_gaps.clear()
	puzzle.declared_counts_match = puzzle.fixed_parts.size() == puzzle.fixed_count and puzzle.moving_parts.size() == puzzle.moving_count
	return puzzle

func _candidate(bytes: PackedByteArray, offset: int) -> PartDefinition:
	if offset < 0 or offset + 48 > bytes.size():
		return null
	var part_type := _u16(bytes, offset)
	var flags_1 := _u16(bytes, offset + 2)
	var state_flags := flags_1 & 0x7800
	if part_type >= 0x100:
		return null
	# Valid records carry one of the fixed/moving/inventory state bits. The
	# low bits vary by object family (for example 0x1410 is a moving part in
	# the shared levels), so matching only a short list of complete flag words
	# rejects real records and makes the following boundary look like padding.
	if state_flags == 0 and not [0x0600].has(flags_1):
		return null
	var pos_x := _i16(bytes, offset + 20)
	var pos_y := _i16(bytes, offset + 22)
	if pos_x < -700 or pos_x > 900 or pos_y < -3000 or pos_y > 1800:
		return null
	var part := PartDefinition.new()
	part.record_offset = offset
	part.part_type = part_type
	part.flags_1 = flags_1
	part.flags_2 = _u16(bytes, offset + 4)
	part.flags_3 = _u16(bytes, offset + 6)
	part.appearance = _u16(bytes, offset + 8)
	part.unknown_10 = _u16(bytes, offset + 10)
	part.width_1 = _u16(bytes, offset + 12)
	part.height_1 = _u16(bytes, offset + 14)
	part.width_2 = _u16(bytes, offset + 16)
	part.height_2 = _u16(bytes, offset + 18)
	part.pos_x = pos_x
	part.pos_y = pos_y
	part.behavior = _u16(bytes, offset + 24)
	part.unknown_26 = _u16(bytes, offset + 26)
	part.belt_connect_pos_x = bytes[offset + 28]
	part.belt_connect_pos_y = bytes[offset + 29]
	part.belt_line_distance = _u16(bytes, offset + 30)
	if part.unknown_26 != 0:
		if offset + 36 > bytes.size(): return null
		part.belt_endpoints.assign([_i16(bytes,offset+32),_i16(bytes,offset+34)])
	# 298D:5142: optional blocks are inline, before the next slot/links.
	var link_cursor := offset + 32 + (4 if part.unknown_26 != 0 else 0)
	for slot in 2:
		if link_cursor + 4 > bytes.size(): return null
		var present := _u16(bytes,link_cursor)
		var anchor := Vector2i(_i8(bytes[link_cursor+2]),_i8(bytes[link_cursor+3]))
		link_cursor += 4
		var payload := {"present":present,"anchor":anchor,"ends":[-1,-1],"slots":[0,0]}
		if present != 0:
			if link_cursor + 6 > bytes.size(): return null
			payload.ends=[_i16(bytes,link_cursor),_i16(bytes,link_cursor+2)]
			payload.slots=[bytes[link_cursor+4],bytes[link_cursor+5]]
			link_cursor += 6
		part.rope_slots.append(payload)
	part.unknown_32=part.rope_slots[0].present
	part.unknown_36=part.rope_slots[1].present
	part.rope_1_connect_pos_x=part.rope_slots[0].anchor.x
	part.rope_1_connect_pos_y=part.rope_slots[0].anchor.y
	part.rope_2_connect_pos_x=part.rope_slots[1].anchor.x
	part.rope_2_connect_pos_y=part.rope_slots[1].anchor.y
	if link_cursor+8+(2 if part_type in [17,46] else 0)>bytes.size(): return null
	part.wire_links_offset=link_cursor-offset
	part.connected_1 = _i16(bytes,link_cursor)
	part.connected_2 = _i16(bytes,link_cursor+2)
	part.outlet_plugged_1 = _i16(bytes,link_cursor+4)
	part.outlet_plugged_2 = _i16(bytes,link_cursor+6)
	if part_type==17: part.pulley_rope_owner=_i16(bytes,link_cursor+8)
	part.raw_common = bytes.slice(offset, offset + 48)
	return part

func _common_wire_fields() -> Dictionary:
	return {
		"type": 0,
		"flags_1": 2,
		"flags_2": 4,
		"flags_3": 6,
		"appearance": 8,
		"unknown_10": 10,
		"width_1": 12,
		"height_1": 14,
		"width_2": 16,
		"height_2": 18,
		"pos_x": 20,
		"pos_y": 22,
		"behavior": 24,
		"unknown_26": 26,
		"belt_connect_pos_x": 28,
		"belt_connect_pos_y": 29,
		"belt_line_distance": 30,
		"unknown_32": 32,
		"rope_1_connect_pos_x": 34,
		"rope_1_connect_pos_y": 35,
		"unknown_36": 36,
		"rope_2_connect_pos_x": 38,
		"rope_2_connect_pos_y": 39,
		"connected_1": 40,
		"connected_2": 42,
		"outlet_plugged_1": 44,
		"outlet_plugged_2": 46,
		"wire_terminal": 48,
	}

func _read_c_string(bytes: PackedByteArray, offset: int) -> Dictionary:
	var start := offset
	while offset < bytes.size() and bytes[offset] != 0:
		offset += 1
	var text := bytes.slice(start, offset).get_string_from_ascii()
	if offset < bytes.size():
		offset += 1
	return {"text": text, "next_offset": offset}

func _u16(bytes: PackedByteArray, offset: int) -> int:
	return bytes[offset] | (bytes[offset + 1] << 8)

func _i16(bytes: PackedByteArray, offset: int) -> int:
	var value := _u16(bytes, offset)
	return value if value < 0x8000 else value - 0x10000

func _hex_prefix(bytes: PackedByteArray, count: int) -> String:
	var values: PackedStringArray = []
	for i in range(mini(count, bytes.size())):
		values.append("%02x" % bytes[i])
	return " ".join(values)

func _i8(value: int) -> int:
	return value if value<128 else value-256
