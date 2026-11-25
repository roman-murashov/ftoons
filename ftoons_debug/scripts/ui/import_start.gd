extends CenterContainer
## Start the bundled import pipeline without blocking the running debug UI.
const MAIN := "res://scenes/main.tscn"
const WORKER := "res://import_native/import_game.gd"
const Paths := preload("res://scripts/io/portable_paths.gd")

var fields: Dictionary = {}
var pickers: Array[Button] = []
var import_button: Button
var continue_button: Button
var status: Label
var process_id := -1
var report_path := ""
var next_poll_msec := 0

func _ready() -> void:
	set_process(false)
	if ImportedResources.dos_ready and not ImportedResources.setup_requested and ImportedResources.issues.is_empty():
		_enter_game.call_deferred()
		return
	ImportedResources.setup_requested = false
	var box := VBoxContainer.new()
	box.custom_minimum_size.x = 600
	box.add_theme_constant_override("separation", 12)
	add_child(box)
	var title := Label.new()
	title.text = "Import game files"
	title.add_theme_font_size_override("font_size", 30)
	box.add_child(title)
	var help := Label.new()
	help.text = "Choose your game files. Decoded assets are saved beside project.godot."
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(help)
	_add_source(box, "dos", "DOS game (required)", "Folder containing TOONS.EXE, RESOURCE.001 and ADL.DRV")
	_add_source(box, "windows", "Windows game (optional)", "Choose the game CD image or the installed Windows files")
	var actions := HBoxContainer.new()
	box.add_child(actions)
	import_button = Button.new()
	import_button.text = "Import and open debug game"
	import_button.pressed.connect(_start_import)
	actions.add_child(import_button)
	continue_button = Button.new()
	continue_button.text = "Open debug game"
	continue_button.pressed.connect(_enter_game)
	actions.add_child(continue_button)
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.custom_minimum_size.y = 50
	status.text = "\n".join(ImportedResources.issues.values())
	box.add_child(status)
	_update_controls()

func _add_source(box: VBoxContainer, edition: String, caption: String, hint: String) -> void:
	var label := Label.new()
	label.text = caption
	box.add_child(label)
	var row := HBoxContainer.new()
	box.add_child(row)
	var field := LineEdit.new()
	fields[edition] = field
	field.placeholder_text = hint
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(field)
	var done := ImportedResources.dos_ready if edition == "dos" else ImportedResources.windows_ready
	if done and edition == "dos":
		field.text = "Imported"
		field.editable = false
		return
	if done:
		field.placeholder_text = "Windows files installed. Choose a disc to add more media."
	field.text_changed.connect(func(_value: String): _update_controls())
	for folder: bool in [true, false]:
		var pick := Button.new()
		pick.set_meta("edition", edition)
		pick.text = "Folder…" if folder else ("Disc or ZIP…" if edition == "windows" else "ZIP…")
		pick.pressed.connect(_choose.bind(field, folder, edition))
		row.add_child(pick)
		pickers.append(pick)

func _choose(field: LineEdit, folder: bool, edition: String) -> void:
	var dialog := FileDialog.new()
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR if folder else FileDialog.FILE_MODE_OPEN_FILE
	dialog.title = "Select game folder" if folder else "Select original game media"
	if not folder:
		if edition == "windows":
			dialog.add_filter("*.cue,*.bin,*.iso,*.zip", "Disc image or game ZIP")
		else:
			dialog.add_filter("*.zip", "ZIP archives")
	add_child(dialog)
	var selected := func(path: String):
		field.text = path
		_update_controls()
		dialog.queue_free()
	dialog.dir_selected.connect(selected)
	dialog.file_selected.connect(selected)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered_clamped(Vector2i(850, 580))

func _selection(edition: String) -> String:
	var field: LineEdit = fields[edition]
	return field.text.strip_edges().trim_prefix('"').trim_suffix('"') if field.editable else ""

func _update_controls() -> void:
	if not is_instance_valid(import_button):
		return
	var busy := process_id >= 0
	var dos := _selection("dos")
	var win := _selection("windows")
	import_button.disabled = busy or (dos.is_empty() and not ImportedResources.dos_ready) or (dos.is_empty() and win.is_empty())
	continue_button.visible = ImportedResources.dos_ready
	continue_button.disabled = busy
	for pick in pickers:
		var field: LineEdit = fields[pick.get_meta("edition")]
		pick.disabled = busy or not field.editable
	for field: LineEdit in fields.values():
		field.mouse_filter = Control.MOUSE_FILTER_IGNORE if busy else Control.MOUSE_FILTER_STOP
		field.focus_mode = Control.FOCUS_NONE if busy else Control.FOCUS_ALL
		if busy: field.release_focus()

func _start_import() -> void:
	var id := Crypto.new().generate_random_bytes(12).hex_encode()
	var work := Paths.work().path_join(id)
	if DirAccess.make_dir_recursive_absolute(work) != OK:
		status.text = "Cannot write here. Open this project in a writable folder: " + Paths.root_dir()
		return
	report_path = work.path_join("status.jsonl")
	var args := PackedStringArray(["--headless", "--path", Paths.root_dir(), "--log-file",
		work.path_join("decoder.log"), "--script", WORKER, "--", "--ftoons-import-worker", "--job", id])
	for edition: String in ["dos", "windows"]:
		var source := _selection(edition)
		if not source.is_empty():
			args.append_array(["--" + edition, source])
	process_id = OS.create_process(OS.get_executable_path(), args, false)
	if process_id < 0:
		status.text = "Could not start the Godot import worker."
		return
	status.text = "Starting the importer…"
	set_process(true)
	_update_controls()

func _process(_delta: float) -> void:
	if Time.get_ticks_msec() < next_poll_msec:
		return
	next_poll_msec = Time.get_ticks_msec() + 200
	var running := OS.is_process_running(process_id)
	var report: Variant = null
	if FileAccess.file_exists(report_path):
		var log_text := FileAccess.get_file_as_string(report_path)
		var end := log_text.rfind("\n")
		if end >= 0:
			var line := log_text.left(end).get_slice_count("\n") - 1
			report = JSON.parse_string(log_text.get_slice("\n", line))
	if report is Dictionary:
		status.text = String(report.get("message", ""))
	if running:
		return
	set_process(false)
	process_id = -1
	ImportedResources.refresh()
	if report is Dictionary and report.get("state") == "done" and ImportedResources.dos_ready and ImportedResources.issues.is_empty():
		_enter_game()
		return
	if not report is Dictionary or report.get("state") == "working":
		status.text = "The importer stopped before finishing. See " + report_path.get_base_dir().path_join("decoder.log")
	if not ImportedResources.issues.is_empty():
		status.text += "\n" + "\n".join(ImportedResources.issues.values())
	if ImportedResources.dos_ready:
		fields.dos.editable = false
		fields.dos.text = "Imported"
	_update_controls()

func _enter_game() -> void:
	get_tree().change_scene_to_file(MAIN)
