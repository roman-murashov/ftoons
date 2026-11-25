extends SceneTree
## Run after importing DOS, then run again after adding the Windows game.
## Exercises the main game's Piggy Bank, shared construction and solo goals.
const Document = preload("res://scripts/io/home_toons_document.gd")
const Rules = preload("res://import_native/windows/win_play_rules.json")

var game
var browser
var controls
var failures: Array[String] = []
var fixture := ""
var probe_progress := ""

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, detail: String) -> bool:
	if not condition:
		failures.append(detail)
		printerr(detail)
	return condition

func _finish() -> void:
	for path in [fixture, probe_progress]:
		if not path.is_empty() and FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	if failures.is_empty():
		print("PASS: Home Toons solo menu, authored level and DOS campaign separation")
	quit(0 if failures.is_empty() else 1)

func _click(point: Vector2) -> void:
	var viewport_point: Vector2 = game.screen.get_global_transform() * point
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = viewport_point
		event.button_index = MOUSE_BUTTON_LEFT
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		event.pressed = down
		root.push_input(event, true)

## Select through the actual modal's hit rectangles, including its page arrows.
func _select_home(source: String) -> bool:
	game.right_dialog.open("load")
	var pig = game.right_dialog.piggy
	_click(pig.buttons.group_4.get_center())
	if not _check(pig.visible and pig.category == 4, "Home Toons category did not open"):
		return false
	var sources: Array = pig.groups[4].map(func(row): return row.source)
	var index := sources.find(source)
	if not _check(index >= 0, "Missing menu row " + source):
		return false
	while index >= pig.top + 5:
		var before: int = pig.top
		_click(pig.buttons.down.get_center())
		if not _check(pig.top > before, "Page Down stopped before " + source):
			return false
	_click(pig.buttons["row_%d" % (index - pig.top)].get_center())
	_click(pig.buttons.load.get_center())
	return _check(not pig.visible and controls.runner.puzzle.source_name == source and
			browser.runner == controls.runner and browser.levels[browser.selector.selected] == source,
			"Piggy Load did not select the shared puzzle " + source)

func _run() -> void:
	var install = root.get_node("ImportedResources")
	if not _check(install.dos_ready, "Import the DOS files before running this test"):
		_finish()
		return
	AudioServer.set_bus_mute(0, true)
	root.size = Vector2i(1440, 900)
	# Use a unique local save to confirm authored puzzles remain loadable.
	var token := Crypto.new().generate_random_bytes(12).hex_encode()
	fixture = Document.default_folder().path_join("solo_fixture_" + token + ".json")
	if not _check(Document.new().save_file(fixture, {"format":Document.FORMAT, "version":1,
			"title":"Solo picker fixture", "goal":"", "music":0, "gravity":0, "pressure":0,
			"parts":[], "ropes":[], "belts":[]}), "Could not create the authored puzzle fixture"):
		_finish()
		return
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	var tabs: TabContainer = current_scene.get_child(0)
	game = tabs.get_node("Game emulation")
	tabs.current_tab = tabs.get_tab_idx_from_control(game)
	browser = tabs.get_node("Puzzles")
	browser.set_process(false)
	controls = game.construction
	probe_progress = Document.default_folder().path_join("progress_" + token + ".tmp")
	controls.campaign_progress.path = probe_progress
	controls.campaign_progress.load_progress()
	var dos_status: Array = controls.campaign_progress.native_status.duplicate()
	await process_frame
	game.right_dialog.close()
	game.remote_open = true
	game._sync()
	_click(Vector2(603, 86))
	var pig = game.right_dialog.piggy
	if not _check(pig.visible, "The remote's Piggy Bank button did not open the load dialog"):
		_finish()
		return
	var campaign_count := 0
	for group in range(4):
		campaign_count += pig.groups[group].size()
	_check(campaign_count == 100, "DOS campaign categories must still contain 100 levels")
	var windows_sources: Array = []
	var menu_titles := {}
	for row: Dictionary in pig.groups[4]:
		if String(row.source).get_extension() == "H2H":
			windows_sources.append(row.source)
			menu_titles[row.source] = row.title
	if not _select_home(fixture):
		_finish()
		return
	if not install.windows_ready:
		_check(windows_sources.is_empty(), "Unavailable Windows levels appeared in the DOS-only menu")
		print("DOS-only Home Toons verified")
		_finish()
		return
	var expected: Array[String] = []
	for n in range(1, 51):
		expected.append("PLAY%d.H2H" % n)
	if not _check(windows_sources == expected, "Windows puzzles must appear once in numerical order"):
		_finish()
		return
	if not _select_home("PLAY50.H2H") or not _select_home("PLAY1.H2H"):
		_finish()
		return
	for n in range(1, 51):
		var source: String = expected[n - 1]
		if not _check(controls.request_level(source), "Cannot load " + source):
			continue
		var run: SimulationRunner = controls.runner
		_check(not run.puzzle.title.is_empty() and menu_titles.get(source) == run.puzzle.title,
				"Menu title does not match the Windows board " + source)
		_check(run.puzzle.declared_counts_match and run.puzzle.campaign_goal_index == -1 and
				run.puzzle.head_to_head_goal == Rules.data[n - 1],
				"Wrong part count or original Windows goal for " + source)
		var successor := "PLAY%d.H2H" % (n + 1) if n < 50 else ""
		_check(controls.next_campaign_level(true) == successor and controls.next_campaign_level() == successor,
				"Incorrect Next puzzle for " + source)
		controls.reset(true)
		controls.play()
		run.step()
		_check(run.state.goal.enabled and run.state.goal.initialized and run.state.goal.error.is_empty(),
				"Solo simulation failed to bind " + source)
		controls.stop()
	if not _select_home("PLAY25.H2H"):
		_finish()
		return
	controls.reset(true)
	controls.play()
	for tick in 600:
		if controls.is_completed():
			break
		controls.runner.step()
	if _check(controls.is_completed(), "PLAY25 did not meet its native goal with the stored placement"):
		var completion_tick: int = controls.runner.state.tick
		_check(controls.advance_campaign(true) and controls.runner.puzzle.source_name == "PLAY26.H2H",
				"Next after solving PLAY25 did not open PLAY26")
		print("PLAY25 completed at update %d; checked PLAY1–PLAY50 goal binding and progression" % completion_tick)
	_check(not FileAccess.file_exists(probe_progress) and controls.campaign_progress.entries.is_empty()
			and controls.campaign_progress.native_status == dos_status, "Solo completion altered DOS campaign progress")
	_finish()
