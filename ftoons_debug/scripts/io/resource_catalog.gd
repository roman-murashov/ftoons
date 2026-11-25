class_name ResourceCatalog
extends RefCounted

const DEFAULT_INDEX := "res://assets/original/resource_index.json"
const CUSTOM_INDEX := "res://assets/custom/resource_index.json"

var _entries: Array = []
var _by_name: Dictionary = {}
var load_error: String = ""

func _init(index_path: String = DEFAULT_INDEX) -> void:
	load_index(index_path)

func load_index(index_path: String = DEFAULT_INDEX) -> bool:
	_entries.clear()
	_by_name.clear()
	load_error = ""
	if not FileAccess.file_exists(index_path):
		load_error = "missing resource index: %s" % index_path
		return false
	var file := FileAccess.open(index_path, FileAccess.READ)
	if file == null:
		load_error = "cannot open resource index: %s" % index_path
		return false
	var parsed = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary) or not (parsed.has("entries")) or not (parsed["entries"] is Array):
		load_error = "resource index is not an entries object"
		return false
	for raw in parsed["entries"]:
		if not (raw is Dictionary) or not raw.has("name"):
			continue
		var entry: Dictionary = raw.duplicate(true)
		_entries.append(entry)
		_by_name[_canonical_name(String(entry["name"]))] = entry
	# Keep the original archive index intact. User-authored puzzles have their
	# own packaged index and never replace an original resource by name.
	if index_path == DEFAULT_INDEX and FileAccess.file_exists(CUSTOM_INDEX):
		var custom_file := FileAccess.open(CUSTOM_INDEX, FileAccess.READ)
		if custom_file == null:
			load_error = "cannot open custom puzzle index: %s" % CUSTOM_INDEX
			return false
		var custom = JSON.parse_string(custom_file.get_as_text())
		if not (custom is Dictionary) or not (custom.get("entries") is Array):
			load_error = "custom puzzle index is not an entries object"
			return false
		for raw in custom["entries"]:
			if not (raw is Dictionary) or not raw.has("name"):
				continue
			var entry: Dictionary = raw.duplicate(true)
			var key := _canonical_name(String(entry["name"]))
			if _by_name.has(key):
				load_error = "duplicate custom resource name: %s" % key
				return false
			_entries.append(entry)
			_by_name[key] = entry
	_entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["name"]) < String(b["name"]))
	return true

func count() -> int:
	return _entries.size()

func entries() -> Array:
	return _entries.duplicate(true)

func types() -> Array:
	var seen: Dictionary = {}
	for entry in _entries:
		seen[String(entry.get("type", ""))] = true
	var result: Array = seen.keys()
	result.sort()
	return result

func find(query: String = "", type_filter: String = "") -> Array:
	var needle := query.strip_edges().to_upper()
	var result: Array = []
	for entry in _entries:
		var name := String(entry.get("name", ""))
		var type := String(entry.get("type", ""))
		if not type_filter.is_empty() and type != type_filter:
			continue
		if not needle.is_empty() and not name.to_upper().contains(needle):
			continue
		result.append(entry)
	return result

func get_entry(name: String) -> Dictionary:
	return _by_name.get(_canonical_name(name), {})

func read_asset(name: String) -> PackedByteArray:
	var entry := get_entry(name)
	if entry.is_empty():
		return PackedByteArray()
	var asset_path := String(entry.get("asset_path", ""))
	if asset_path.is_empty():
		var safe_name := String(entry["name"]).get_file()
		asset_path = "res://assets/original/%s" % safe_name
	return FileAccess.get_file_as_bytes(asset_path)

func _canonical_name(name: String) -> String:
	return name.replace("\\", "/").get_file().to_upper()
