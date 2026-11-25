extends SceneTree
## The setup screen starts a second, headless copy of the same Godot executable.
## Decoding, temporary files and publication all belong to this project.
const Paths := preload("res://scripts/io/portable_paths.gd")
const Inputs := preload("res://import_native/input_media.gd")
const Dos := preload("res://import_native/dos_assets.gd")
const Windows := preload("res://import_native/windows/import_windows.gd")
const DecodedGraphics := preload("res://import_native/decoded_graphics.gd")
const Install := preload("res://scripts/io/imported_resources.gd")

var job := ""
var job_id := ""
var error := ""
var records: FileAccess
var summary := {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var index := args.find("--job")
	if index < 0 or index + 1 >= args.size():
		quit(2)
		return
	job_id = args[index + 1]
	if job_id.length() != 24 or not job_id.is_valid_hex_number(false):
		quit(2)
		return
	job = Paths.work().path_join(job_id)
	records = FileAccess.open(job.path_join("status.jsonl"), FileAccess.WRITE)
	if records == null:
		quit(2)
		return
	var acquired := _acquire()
	if acquired:
		for edition in ["dos", "windows"]:
			index = args.find("--" + edition)
			if index >= 0 and index + 1 < args.size():
				if not _install(edition, args[index + 1]):
					break
		_remove_tree(Paths.work().path_join("lock"))
	_remove_tree(job.path_join("staging"))
	_remove_tree(job.path_join("input"))
	_write_status("done" if error.is_empty() else "error", "Game resources are ready." if error.is_empty() else error)
	quit(0 if error.is_empty() else 1)

func _write_status(state: String, message: String) -> void:
	records.store_line(JSON.stringify({"state": state, "message": message, "details": summary}))
	records.flush()

func _progress(message: String) -> void:
	_write_status("working", message)

func _failed(message: String) -> bool:
	error = message
	return false

func _acquire() -> bool:
	var claim := job.path_join("claim")
	var lock := Paths.work().path_join("lock")
	if DirAccess.make_dir_absolute(claim) != OK:
		return _failed("Could not create the project import lock.")
	var owner := FileAccess.open(claim.path_join("pid"), FileAccess.WRITE)
	if owner == null: return _failed("Could not write the project import lock.")
	owner.store_line(str(OS.get_process_id()))
	owner.close()
	if DirAccess.dir_exists_absolute(lock):
		var pid := FileAccess.get_file_as_string(lock.path_join("pid")).to_int()
		if pid <= 0 or OS.is_process_running(pid):
			return _failed("Another import is running in this project.")
		# Only one new worker can claim an abandoned lock via rename.
		if DirAccess.rename_absolute(lock, job.path_join("abandoned")) != OK:
			return _failed("Another importer is opening this project.")
	if DirAccess.rename_absolute(claim, lock) != OK:
		return _failed("Another import is running in this project, or this folder is read-only.")
	return true

func _install(edition: String, selected: String) -> bool:
	var stage := job.path_join("staging/" + edition)
	var dest := Paths.assets_folder(edition)
	var previous := Paths.work().path_join("previous-" + edition)
	if DirAccess.dir_exists_absolute(previous) and not DirAccess.dir_exists_absolute(dest):
		if DirAccess.rename_absolute(previous, dest) != OK:
			return _failed("Could not recover the previous %s import." % edition)
	if DirAccess.dir_exists_absolute(dest) and not FileAccess.file_exists(dest.path_join(Install.MARKER)):
		return _failed("The folder %s already exists without an import record. Move it aside before importing." % dest)
	if DirAccess.make_dir_recursive_absolute(stage) != OK:
		return _failed("Cannot create staging files inside this project.")
	_progress("Reading the selected %s media…" % edition)
	var input := Inputs.new()
	var source := input.prepare(edition, selected, job.path_join("input/" + edition))
	if source.is_empty(): return _failed(input.error)
	var details: Dictionary
	if edition == "dos":
		details = Dos.new().import_dos(source, stage)
		if not details.get("ok", false): return _failed(details.get("error", "DOS resource import failed."))
		var metadata := stage.path_join("assets/original")
		for leaf in DirAccess.get_files_at("res://port_data/original"):
			if leaf.get_extension() == "json":
				if DirAccess.copy_absolute("res://port_data/original/" + leaf, metadata.path_join(leaf)) != OK:
					return _failed("Could not install port data " + leaf)
		_progress("Rendering 31 DOS scores and decoding sound effects…")
		var output := []
		var decoder := Paths.root_dir().path_join("native_audio/ftoons_audio.exe")
		if not FileAccess.file_exists(decoder):
			return _failed("The bundled Windows audio decoder is missing: " + decoder)
		if OS.execute(decoder, ["import", source, stage], output, true, false) != 0:
			return _failed("DOS audio decoding failed. " + "\n".join(output).strip_edges().right(1500))
	else:
		var win := Windows.new()
		details = win.run(source, stage, _progress)
		if not win.error.is_empty(): return _failed(win.error)
	var files := stage.path_join(dest.get_file())
	# Adding disc media after a folder import keeps the earlier MIDI files.
	if edition == "windows" and DirAccess.dir_exists_absolute(dest):
		if not _keep_missing(dest, files):
			return _failed("Could not preserve the previous Windows files.")
		var old: Variant = JSON.parse_string(FileAccess.get_file_as_string(dest.path_join(Install.MARKER)))
		if old is Dictionary:
			for key in details:
				if details[key] is int:
					details[key] = maxi(details[key], int(old.get("details", {}).get(key, 0)))
	var graphics := DecodedGraphics.new()
	details.merge(graphics.run(edition, stage, _progress), true)
	if not graphics.error.is_empty(): return _failed(graphics.error)
	for name: String in Install.REQUIRED[edition]:
		if not FileAccess.file_exists(files.path_join(name)):
			return _failed("Decoder did not produce " + name)
	var inventory := {}
	if not _record_sizes(files, "", inventory): return _failed("Could not verify the imported files.")
	if not _write_text(files.path_join(Install.MARKER),
			JSON.stringify({"format": Install.FORMAT, "edition": edition, "details": details, "sizes": inventory}, "\t")):
		return _failed("Could not finish writing %s assets." % edition)
	_progress("Publishing %s files into %s…" % [edition, dest.get_file()])
	if DirAccess.dir_exists_absolute(previous):
		_remove_tree(previous)
	if DirAccess.dir_exists_absolute(dest) and DirAccess.rename_absolute(dest, previous) != OK:
		return _failed("Could not replace %s. Close other programs using the imported files and retry." % dest)
	if DirAccess.rename_absolute(files, dest) != OK:
		if DirAccess.dir_exists_absolute(previous):
			DirAccess.rename_absolute(previous, dest)
		return _failed("Could not publish %s." % dest)
	_remove_tree(previous)
	summary[edition] = details
	return true

func _write_text(path: String, contents: String) -> bool:
	var out := FileAccess.open(path, FileAccess.WRITE)
	return out != null and out.store_string(contents)

func _record_sizes(root: String, prefix: String, sizes: Dictionary) -> bool:
	var dir := DirAccess.open(root.path_join(prefix))
	if dir == null: return false
	for leaf in dir.get_files():
		if leaf in [Install.MARKER, ".gdignore"] or leaf.get_extension() in ["import","uid"]: continue
		var relative := prefix.path_join(leaf) if not prefix.is_empty() else leaf
		var file := FileAccess.open(root.path_join(relative), FileAccess.READ)
		if file == null: return false
		sizes[relative] = file.get_length()
	for child in dir.get_directories():
		var relative := prefix.path_join(child) if not prefix.is_empty() else child
		if not _record_sizes(root, relative, sizes): return false
	return true

func _keep_missing(from: String, to: String) -> bool:
	var dir := DirAccess.open(from)
	if dir == null or DirAccess.make_dir_recursive_absolute(to) != OK: return false
	for leaf in dir.get_files():
		if leaf == Install.MARKER or leaf.get_extension() in ["import", "uid"] or dir.is_link(leaf) or FileAccess.file_exists(to.path_join(leaf)): continue
		if DirAccess.copy_absolute(from.path_join(leaf), to.path_join(leaf)) != OK: return false
	for leaf in dir.get_directories():
		if not dir.is_link(leaf) and not _keep_missing(from.path_join(leaf), to.path_join(leaf)): return false
	return true

## Only remove private staging, lock and previous-import directories.
func _remove_tree(path: String) -> void:
	if not path.simplify_path().begins_with(Paths.work().trim_suffix("/") + "/"): return
	var dir := DirAccess.open(path)
	if dir == null: return
	dir.include_hidden = true
	for name in dir.get_files():
		dir.remove(name)
	for name in dir.get_directories():
		if dir.is_link(name): dir.remove(name)
		else: _remove_tree(path.path_join(name))
	DirAccess.remove_absolute(path)
