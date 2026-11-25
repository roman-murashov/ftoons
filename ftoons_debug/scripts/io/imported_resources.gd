extends Node
## Verify the committed loose resource directories before any game scene starts.

signal dos_mounted
const Paths := preload("res://scripts/io/portable_paths.gd")
const FORMAT := 2
const MARKER := "ftoons-import.json"
const REQUIRED := {
	"dos": ["original/resource_index.json", "original/reaction_tables.bin",
		"original/music_index.json", "original/synth_effect_index.json", "original/sound_effect_index.json",
		"original/dos_home_editor.json", "levels/CAKE1.json", "decoded_graphics/index.json"],
	"windows": ["graphics/binary/resource_index.json", "head_to_head/index.json", "decoded_graphics/index.json"]
}
var dos_ready := false
var windows_ready := false
var setup_requested := false
var issues := {}
var counts := {}

func _ready() -> void:
	if OS.get_cmdline_user_args().has("--ftoons-import-worker"):
		return
	DirAccess.make_dir_recursive_absolute(Paths.profile())
	_recover_interrupted_publication()
	refresh()

## A power loss between the two directory renames leaves the old import here.
func _recover_interrupted_publication() -> void:
	var pid_path := Paths.work().path_join("lock/pid")
	if FileAccess.file_exists(pid_path) and OS.is_process_running(FileAccess.get_file_as_string(pid_path).to_int()):
		return
	for edition: String in ["dos", "windows"]:
		var old := Paths.work().path_join("previous-" + edition)
		var dest := Paths.assets_folder(edition)
		if not DirAccess.dir_exists_absolute(dest) and FileAccess.file_exists(old.path_join(MARKER)):
			DirAccess.rename_absolute(old, dest)

## Re-read after an import or a Windows disc upgrade in the same session.
func refresh() -> void:
	var was_ready := dos_ready
	issues.clear()
	counts.clear()
	dos_ready = _check("dos")
	windows_ready = _check("windows")
	if dos_ready and not was_ready:
		dos_mounted.emit()

func _check(edition: String) -> bool:
	var folder := Paths.assets_folder(edition)
	if not DirAccess.dir_exists_absolute(folder):
		return false
	var marker := folder.path_join(MARKER)
	var info: Variant = null
	if FileAccess.file_exists(marker):
		info = JSON.parse_string(FileAccess.get_file_as_string(marker))
	if info is Dictionary and info.get("format") == FORMAT and info.get("edition") == edition and info.get("details") is Dictionary and info.get("sizes") is Dictionary:
		var required: Array = REQUIRED[edition].duplicate()
		var details: Dictionary = info.get("details", {})
		if int(details.get("cd_tracks", 0)) > 0:
			required.append_array(["audio/audio_index.json", "audio/music_matches.json"])
		if int(details.get("intro_clips", 0)) > 0:
			required.append("intros/intro_index.json")
		for file: String in required:
			if not FileAccess.file_exists(folder.path_join(file)):
				issues[edition] = "Missing %s. Select your %s files to repair the import." % [file, edition]
				return false
		var inventory: Dictionary = info.get("sizes", {})
		if inventory.is_empty():
			issues[edition] = "The %s import record is incomplete." % edition
			return false
		for relative: String in inventory:
			var file: FileAccess
			if relative.is_relative_path() and not relative.contains(":") and relative.simplify_path() == relative and not relative.begins_with(".."):
				file = FileAccess.open(folder.path_join(relative), FileAccess.READ)
			if file == null or file.get_length() != int(inventory[relative]):
				issues[edition] = "Missing or incomplete file %s. Select your %s files to repair it." % [relative, edition]
				return false
		counts[edition] = details
		return true
	issues[edition] = "No valid import record in %s. Check this folder before importing again." % folder
	return false
