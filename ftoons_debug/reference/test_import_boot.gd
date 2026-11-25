extends SceneTree
## Exercise the setup screen and the same scene transition taken by the player.
## Run a fresh project copy with -- --fresh-dos=<absolute-folder-or-zip>.

func _initialize() -> void:
	call_deferred("_run")

func _fail(reason: String) -> void:
	printerr(reason)
	quit(1)

func _run() -> void:
	var installer = root.get_node("ImportedResources")
	var paths := preload("res://scripts/io/portable_paths.gd")
	var fresh := ""
	var windows := ""
	var add_windows := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--fresh-dos="): fresh = arg.trim_prefix("--fresh-dos=")
		if arg.begins_with("--with-windows="): windows = arg.trim_prefix("--with-windows=")
		if arg.begins_with("--add-windows="): add_windows = arg.trim_prefix("--add-windows=")
	change_scene_to_file("res://scenes/import_start.tscn")
	await scene_changed
	if not fresh.is_empty() or OS.get_cmdline_user_args().has("--expect-setup"):
		var screen = current_scene
		if installer.dos_ready or screen.name != "GameFiles" or not screen.import_button.disabled:
			_fail("Expected the initial DOS selection prompt")
			return
		if fresh.is_empty():
			print("PASS: clean startup waits for DOS media")
			quit()
			return
		screen.fields.dos.text = fresh
		screen.fields.windows.text = windows
		screen._update_controls()
		if screen.import_button.disabled:
			_fail("Import button stayed disabled after choosing DOS files")
			return
		screen.import_button.pressed.emit()
	var deadline := Time.get_ticks_msec() + 360000
	while current_scene == null or current_scene.name != "Main":
		if Time.get_ticks_msec() > deadline:
			_fail("Timed out waiting for the regular debug game")
			return
		if current_scene != null and not fresh.is_empty() and current_scene.process_id < 0:
			_fail("First-run importer stopped: " + current_scene.status.text)
			return
		await process_frame
	var tabs: TabContainer = current_scene.get_child(0)
	if not add_windows.is_empty():
		if installer.windows_ready and int(installer.counts.windows.get("cd_tracks", 0)) == 24:
			_fail("The upgrade test requires a DOS-only or data-only installation")
			return
		var resources := tabs.get_node("Resources")
		var confirm := resources.find_children("*", "ConfirmationDialog", true, false)[0] as ConfirmationDialog
		confirm.confirmed.emit()
		await scene_changed
		var screen = current_scene
		screen.fields.windows.text = add_windows
		screen._update_controls()
		screen.import_button.pressed.emit()
		while current_scene == null or current_scene.name != "Main":
			if Time.get_ticks_msec() > deadline or (is_instance_valid(screen) and screen.is_inside_tree() and screen.process_id < 0):
				_fail("Windows add-on setup failed")
				return
			await process_frame
		tabs = current_scene.get_child(0)
		windows = add_windows
	var puzzles = tabs.get_node("Puzzles")
	var lib := ResourceCatalog.new()
	if not FileAccess.file_exists(paths.assets_folder("dos").path_join("original/payloads/GAME.PAL.bin")):
		_fail("The DOS palette is not a loose file in this project")
		return
	if not root.get_node("PortSettings").path.begins_with(paths.profile()) or not puzzles.construction.campaign_progress.path.begins_with(paths.profile()):
		_fail("Player data escaped the portable project folder")
		return
	if tabs.get_tab_count() != 6 or lib.count() != 464 or puzzles.runner.puzzle.source_name != "CAKE1.LEV":
		_fail("Incorrect debug startup or asset catalog")
		return
	var expected_windows := 50 if installer.windows_ready else 0
	if puzzles.levels.size() != 100 + expected_windows or puzzles.levels.count("PLAY1.H2H") != int(installer.windows_ready):
		_fail("Expected the 100 DOS puzzles plus the installed Windows solo series")
		return
	for n in [800, 801, 802]:
		if not lib.get_entry("PUZ_%d.ITL" % n).is_empty():
			_fail("Unwanted Home Toon in imported catalog")
			return
	var music = root.get_node("MusicPlayer")
	var effects = root.get_node("AudioEffects")
	if music.songs.size() != 31 or effects._get_sample(3040) == null or effects._get_sample(3) == null:
		_fail("Missing DOS music, digital or synthesized effect")
		return
	if not windows.is_empty() and not installer.windows_ready:
		_fail("Requested Windows import did not mount")
		return
	if installer.windows_ready:
		if not FileAccess.file_exists(paths.assets_folder("windows").path_join("head_to_head/PLAY1.bin")):
			_fail("Missing loose Windows level")
			return
		var game = tabs.get_node("Game emulation")
		game.graphics_button.button_pressed = true
		if not game.sprite_graphics.alternate_enabled or tabs.get_node("Head-2-head mode").construction.library.levels.size() != 50:
			_fail("Imported Windows graphics or puzzles were unavailable")
			return
		if FileAccess.file_exists("res://dlc_win_data/intros/intro_index.json"):
			var library = preload("res://scripts/graphics/windows_intro_library.gd").new()
			var clips: Array = library.timeline("CAKE1.LEV")
			if clips.is_empty() or clips[0].audio == null or clips[0].images.is_empty():
				_fail("Could not decode intro animation and speech")
				return
		if FileAccess.file_exists("res://dlc_win_data/audio/audio_index.json"):
			var cd = music.cd_library
			if not cd.refresh() or cd.load_song(int(cd.songs.keys()[0])) == null:
				_fail("Could not decode an imported CD track")
				return
	puzzles._place_solution()
	puzzles._run_simulation()
	puzzles.construction.advance(1.0 / AudioPlaybackState.SIMULATION_HZ)
	if puzzles.runner.state.tick < 1:
		_fail("CAKE1 simulation did not start")
		return
	print("PASS: six debug tabs, 464 resources, 100 DOS campaign levels, ", expected_windows, " Windows solo levels, CAKE1 Play, DOS music and effects")
	quit()
