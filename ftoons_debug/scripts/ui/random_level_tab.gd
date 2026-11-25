extends MarginContainer

const Generator := preload("res://scripts/generation/random_level_generator.gd")
const Exporter := preload("res://scripts/io/generated_level_export.gd")
const Document := preload("res://scripts/io/home_toons_document.gd")
const Controls := preload("res://scripts/ui/construction_controls.gd")
const Similarity := preload("res://scripts/generation/room_similarity.gd")

var catalog: ResourceCatalog
var construction := Controls.new()
var levels: Array[Dictionary] = []
var room_history := {}
var recent_challenges: Array[String] = []
var recent_boards: Array[Dictionary] = []
var selected_level := -1
var generating := false
var rng := RandomNumberGenerator.new()

var difficulty := OptionButton.new()
var session_list := ItemList.new()
var generate_button: Button
var solution_button: Button
var play_button: Button
var json_button: Button
var lev_button: Button
var inventory_selector := OptionButton.new()
var take_button: Button
var title_label := Label.new()
var goal_label := Label.new()
var level_details := Label.new()
var status_label := Label.new()
var canvas: PuzzleCanvas
var board_panel := VBoxContainer.new()
var empty_state := Label.new()
var export_dialog := FileDialog.new()
var pending_export: Dictionary
var export_format := ""

func _init(resource_catalog: ResourceCatalog, type_names: Dictionary) -> void:
	catalog = resource_catalog
	construction.type_names = type_names

func _ready() -> void:
	rng.randomize()
	for side in ["left", "right", "top", "bottom"]:
		add_theme_constant_override("margin_" + side, 16)
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 16)
	add_child(columns)
	var library := VBoxContainer.new()
	library.custom_minimum_size.x = 260
	library.add_theme_constant_override("separation", 8)
	columns.add_child(library)
	library.add_child(_label("Difficulty"))
	for index in Generator.TIERS.size():
		var tier: Dictionary = Generator.TIERS[index]
		difficulty.add_item("%d · %s" % [index + 1, tier.name], index + 1)
	library.add_child(difficulty)
	generate_button = _button(library, "Generate a new level", _generate)
	library.add_child(HSeparator.new())
	library.add_child(_label("Generated this session"))
	session_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	session_list.allow_reselect = true
	session_list.item_selected.connect(open_level)
	library.add_child(session_list)

	columns.add_child(VSeparator.new())
	empty_state.text = "Choose a difficulty and generate a level to start."
	empty_state.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	empty_state.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	empty_state.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	empty_state.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(empty_state)
	board_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	board_panel.add_theme_constant_override("separation", 8)
	columns.add_child(board_panel)
	board_panel.hide()
	title_label.add_theme_font_size_override("font_size", 24)
	title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	board_panel.add_child(title_label)
	level_details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	board_panel.add_child(level_details)
	goal_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	board_panel.add_child(goal_label)

	var actions := HFlowContainer.new()
	board_panel.add_child(actions)
	solution_button = _button(actions, "Place solution", _place_solution)
	play_button = _button(actions, "Play level", _toggle_play)
	json_button = _button(actions, "Export JSON", _export.bind("json"))
	lev_button = _button(actions, "Export LEV", _export.bind("lev"))
	lev_button.tooltip_text = "DOS Home Toons board and goal text. The original game uses manual judging for custom levels."
	canvas = PuzzleCanvas.new(catalog)
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas.clip_contents = true
	canvas.rope_editor = construction.rope_editor
	canvas.belt_editor = construction.belt_editor
	canvas.part_selected.connect(func(index: int): construction.pick_native(index, canvas.last_pointer))
	canvas.rope_endpoint_selected.connect(func(owner: int, side: int): construction.invoke("_take_rope_endpoint", [owner, side]))
	canvas.belt_endpoint_selected.connect(func(owner: int, side: int): construction.invoke("_take_belt_endpoint", [owner, side]))
	canvas.board_clicked.connect(func(pos: Vector2i): construction.invoke("_on_board_clicked", [pos]))
	canvas.board_hovered.connect(func(pos: Vector2i): construction.invoke("_move_grab", [pos]))
	board_panel.add_child(canvas)

	var inventory_row := HBoxContainer.new()
	board_panel.add_child(inventory_row)
	inventory_row.add_child(_label("Inventory"))
	inventory_selector.custom_minimum_size.x = 170
	inventory_selector.fit_to_longest_item = false
	inventory_row.add_child(inventory_selector)
	take_button = _button(inventory_row, "Take", _take)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	board_panel.add_child(status_label)
	export_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	export_dialog.access = FileDialog.ACCESS_FILESYSTEM
	if not OS.has_feature("web"):
		var levels := preload("res://scripts/io/home_toons_document.gd").default_folder()
		if DirAccess.make_dir_recursive_absolute(levels) == OK:
			export_dialog.current_dir = levels
	export_dialog.file_selected.connect(_save_export)
	export_dialog.canceled.connect(func(): pending_export = {})
	add_child(export_dialog)

	construction.changed.connect(_sync_board)
	construction.audio_reset_requested.connect(func():
		if is_visible_in_tree(): AudioEffects.stop_bank_effects())
	construction.audio_state_provider = AudioEffects.playback_snapshot
	visibility_changed.connect(_visibility_changed)
	_visibility_changed()
	_sync_board()

func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label

func _button(parent: Control, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(action)
	parent.add_child(button)
	return button

func _generate() -> void:
	if generating: return
	generating = true
	generate_button.disabled = true
	difficulty.disabled = true
	generate_button.text = "Generating…"
	var tier := difficulty.get_selected_id()
	var generator := Generator.new()
	if selected_level < 0: empty_state.text = "Testing the solution and the missing pieces in the room…"
	generator.candidate_started.connect(func(number: int): generate_button.text = "Checking room %d…" % number)
	var history: Array = room_history.get(tier, [])
	var document: Dictionary = await generator.generate_level(tier, rng.randi(), get_tree(),
			history, recent_challenges, recent_boards)
	generating = false
	generate_button.disabled = false
	difficulty.disabled = false
	generate_button.text = "Generate a new level"
	if document.is_empty():
		_show_status(generator.error)
		return
	# Keep the selected puzzle and its suggested JSON filename identifiable on a long run.
	var base_title: String = document.title
	var edition := 1
	while levels.any(func(existing): return existing.title == document.title):
		edition += 1
		document.title = "%s (%d)" % [base_title, edition]
	var room_id: String = document.generator.room_id
	history.erase(room_id)
	history.append(room_id)
	room_history[tier] = history
	recent_boards.append(Similarity.fingerprint(document))
	if recent_boards.size() > 20: recent_boards.pop_front()
	for key: String in document.generator.challenge_keys:
		recent_challenges.erase(key)
		recent_challenges.append(key)
	var index := levels.size()
	levels.append(document)
	session_list.add_item("%d. %s" % [index + 1, document.title])
	session_list.set_item_tooltip(index, "%s · %s" % [Generator.TIERS[tier - 1].name, document.goal])
	open_level(index)
	session_list.ensure_current_is_visible()

func open_level(index: int) -> void:
	if index < 0 or index >= levels.size(): return
	var document := levels[index]
	var codec := Document.new()
	var puzzle := codec.decode(document, "generated-%d.json" % (index + 1), false)
	if puzzle == null:
		_show_status(codec.error)
		return
	# Each entry starts a fresh puzzle with the same pre-Play state as its verified solution.
	construction.set_runner(null)
	selected_level = index
	session_list.select(index)
	empty_state.hide()
	board_panel.show()
	title_label.text = puzzle.title
	goal_label.text = puzzle.instructions
	var plan: Dictionary = document.generator
	level_details.text = "%d · %s    |    %s" % [plan.difficulty, plan.campaign_tier, plan.room_name]
	level_details.tooltip_text = str(plan.mechanism)
	canvas.set_puzzle(puzzle)
	var runner := SimulationRunner.new(puzzle)
	runner.set_audio_enabled(AudioEffects.effects_enabled)
	runner.sound_effect_requested.connect(func(event: Dictionary):
		if is_visible_in_tree(): AudioEffects.handle_event(event))
	runner.audio_clock_advanced.connect(func(snapshot: Dictionary):
		if is_visible_in_tree(): AudioEffects.sync_simulation_audio(snapshot))
	construction.set_runner(runner)
	if is_visible_in_tree(): MusicPlayer.set_level_music(puzzle.music)

func _place_solution() -> void:
	construction.reset(true)
	_show_status("Solution placed. Press Play level to run it.")

func _toggle_play() -> void:
	if construction.play_backup == null:
		construction.play()
	else:
		construction.stop()

func _take() -> void:
	if inventory_selector.selected >= 0:
		construction.take_native(inventory_selector.get_selected_id())

func _sync_board() -> void:
	var runner := construction.runner
	var attempting := construction.play_backup != null
	solution_button.disabled = runner == null
	play_button.disabled = runner == null or construction.grab_active
	json_button.disabled = runner == null
	lev_button.disabled = runner == null
	play_button.text = "Stop" if attempting else "Play level"
	if runner == null: return
	canvas.grab_active = construction.grab_active
	canvas.selected_index = construction.selected_index
	canvas.editing_enabled = not attempting
	canvas.set_runtime(runner.state)
	if not attempting:
		var previous := inventory_selector.get_selected_id()
		inventory_selector.clear()
		for part in runner.state.parts:
			if part.placed or not construction.inventory_visible(part.index): continue
			inventory_selector.add_item(construction.type_names.get(part.part_type, "Gadget"), part.index)
			if part.index == previous: inventory_selector.select(inventory_selector.item_count - 1)
	inventory_selector.disabled = attempting or construction.grab_active or inventory_selector.item_count == 0
	take_button.disabled = inventory_selector.disabled
	status_label.text = construction.status

func _show_status(message: String) -> void:
	if construction.runner == null:
		empty_state.text = message
	else:
		construction.status = message
		status_label.text = message

func _export(format: String) -> void:
	if selected_level < 0: return
	var document := levels[selected_level]
	var filename := "%s.json" % String(document.title).validate_filename()
	if format == "lev": filename = "TOON%04d.LEV" % (selected_level + 1)
	if OS.has_feature("web"):
		var exporter := Exporter.new()
		var bytes := exporter.encode(document, format)
		if bytes.is_empty():
			_show_status(exporter.error)
			return
		var mime := "application/json" if format == "json" else "application/octet-stream"
		JavaScriptBridge.download_buffer(bytes, filename, mime)
		_show_status("Download requested for " + filename)
		return
	pending_export = document
	export_format = format
	export_dialog.title = "Export " + format.to_upper()
	export_dialog.filters = PackedStringArray(["*.%s ; %s level" % [format, format.to_upper()]])
	export_dialog.current_file = filename
	export_dialog.popup_centered_ratio(0.7)

func _save_export(path: String) -> void:
	if pending_export.is_empty(): return
	var document := pending_export
	pending_export = {}
	if path.get_extension().to_lower() != export_format:
		_show_status("Choose a ." + export_format + " filename.")
		return
	var exporter := Exporter.new()
	if exporter.save_file(path, document, true):
		_show_status("Exported to " + path)
	else:
		_show_status(exporter.error)

func _visibility_changed() -> void:
	var active := is_visible_in_tree()
	set_process(active)
	set_process_input(active)
	if not active: return
	AudioEffects.stop_bank_effects()
	if construction.runner != null:
		construction.runner.set_audio_enabled(AudioEffects.effects_enabled)
		AudioEffects.sync_simulation_audio(construction.runner.state.audio.snapshot())
		MusicPlayer.set_level_music(construction.runner.puzzle.music)

func _process(delta: float) -> void:
	construction.advance(delta)

func _input(event: InputEvent) -> void:
	if construction.cancel_input(event):
		get_viewport().set_input_as_handled()
