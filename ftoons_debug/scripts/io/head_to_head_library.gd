extends RefCounted
## Optional MPC pack. Original binaries plus trusted native callback catalogue.
const DIRECTORY := "res://dlc_win_data/head_to_head/"
var levels: Array = []
var entries_by_source: Dictionary = {}
var error := ""

func _init() -> void:
	if not FileAccess.file_exists(DIRECTORY+"index.json"):
		error="Head-2-head data is unavailable. Import the MPC PLAY resources first."
		return
	var parsed: Variant=JSON.parse_string(FileAccess.get_file_as_string(DIRECTORY+"index.json"))
	if not parsed is Dictionary or parsed.get("levels",[]).size()!=50:
		error="Invalid Head-2-head catalogue. Expected 50 puzzles."
		return
	levels=parsed.levels
	for entry: Dictionary in levels:
		entries_by_source[entry.source] = entry

func load_puzzle(number: int) -> PuzzleDefinition:
	error=""
	if number<1 or number>levels.size():
		error="Head-2-head puzzle number is unavailable."
		return null
	var entry: Dictionary=levels[number-1]
	var path:=DIRECTORY+String(entry.file)
	if not FileAccess.file_exists(path):
		error="Missing puzzle: "+path
		return null
	var bytes:=FileAccess.get_file_as_bytes(path)
	var hash:=HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	if hash.finish().hex_encode()!=String(entry.sha256):
		error="Puzzle integrity check failed: "+path
		return null
	# The shared reader also lists this pack. Resolve its binary parser here
	# when a board is opened so the two script resources can load independently.
	var reader = load("res://scripts/io/level_reader.gd").new(null)
	var puzzle: PuzzleDefinition = reader.parse_bytes(String(entry.source), bytes, "campaign")
	if not puzzle.scan_error.is_empty():
		error=puzzle.scan_error
		return null
	puzzle.head_to_head_goal=entry.goal.duplicate(true)
	return puzzle
