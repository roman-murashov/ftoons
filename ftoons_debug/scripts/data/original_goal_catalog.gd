extends RefCounted
## Packaged translations of the DOS campaign and optional Windows PLAY callbacks.
const CATALOGUE_PATH := "res://assets/original/dos_campaign_goals.json"
const PLAY_INDEX := "res://dlc_win_data/head_to_head/index.json"
const PREFIXES := ["CAKE", "BRAN", "HARD", "LOON"]
const COUNTS := [30, 20, 25, 25]
static var catalogue: Dictionary = {}
static var dos_specs: Dictionary = {}
static var play_specs: Dictionary = {}

static func level_names() -> Array[String]:
	var result: Array[String] = []
	for group in 4:
		for number in range(1, COUNTS[group]+1): result.append("%s%d.LEV" % [PREFIXES[group],number])
	return result

static func level_index(source: String) -> int:
	return level_names().find(source.to_upper())

static func data() -> Dictionary:
	if catalogue.is_empty() and FileAccess.file_exists(CATALOGUE_PATH):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(CATALOGUE_PATH))
		if parsed is Dictionary: catalogue = parsed
	return catalogue

static func dos_spec(index: int) -> Dictionary:
	var content := data()
	var levels: Array = content.get("levels", [])
	if index < 0 or index >= levels.size(): return {}
	return content.get("callbacks", {}).get(levels[index].callback, {})

static func original_spec(source: String) -> Dictionary:
	# A document may name a catalogue entry. It cannot supply a callback or path.
	if source.ends_with(".LEV"):
		if dos_specs.is_empty():
			var content := data()
			for row in content.get("levels", []):
				dos_specs[row.source_name] = content.callbacks[row.callback]
		return dos_specs.get(source, {})
	if not source.begins_with("PLAY") or not source.ends_with(".H2H"): return {}
	if play_specs.is_empty() and FileAccess.file_exists(PLAY_INDEX):
		var index = JSON.parse_string(FileAccess.get_file_as_string(PLAY_INDEX))
		if index is Dictionary:
			for row in index.get("levels", []): play_specs[row.source] = row.goal
	return play_specs.get(source, {})
