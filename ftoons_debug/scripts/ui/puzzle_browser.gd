class_name PuzzleBrowser
extends VBoxContainer

const LevelReader = preload("res://scripts/io/level_reader.gd")
const PuzzleCanvas = preload("res://scripts/ui/puzzle_canvas.gd")
const SimulationRunner = preload("res://scripts/simulation/simulation_runner.gd")
const PlacementObjective = preload("res://scripts/simulation/placement_objective.gd")
const RopeEditor = preload("res://scripts/simulation/rope_editor.gd")

var reader: LevelReader
var catalog: ResourceCatalog
var levels: Array = []
var selector: OptionButton
var previous_level_button: Button
var next_level_button: Button
var summary_label: Label
var detail_label: RichTextLabel
var canvas: PuzzleCanvas
var construction := preload("res://scripts/ui/construction_controls.gd").new()
var runner: SimulationRunner:
	get: return construction.runner
	set(value): construction.set_runner(value)
var objective: PlacementObjective
var sim_status: Label
var objective_status: Label
var take_button: Button
var grab_status: Label
var grab_backup: SimulationState:
	get: return construction.grab_backup
	set(value): construction.grab_backup = value
var grab_index: int:
	get: return construction.grab_index
	set(value): construction.grab_index = value
var rope_editor: RopeEditor:
	get: return construction.rope_editor
var belt_editor: RefCounted:
	get: return construction.belt_editor
var inventory_selector: OptionButton
var place_solution_button: Button
var graphics_button: Button
var graphics_status: Label
var sound_button: Button
var test_sound_button: Button
var music_button: Button
var music_selector: OptionButton
var music_volume: HSlider
var type_names: Dictionary = {}
var completion_actions: HBoxContainer
var completion_next: Button
var selected_index: int:
	get: return construction.selected_index
	set(value): construction.selected_index = value
var tick_accumulator: float:
	get: return construction.tick_accumulator
	set(value): construction.tick_accumulator = value

func _init(resource_catalog: ResourceCatalog) -> void:
	catalog = resource_catalog
	reader = LevelReader.new(resource_catalog)
	var names_file := FileAccess.open("res://assets/original/part_type_names.json", FileAccess.READ)
	if names_file != null:
		var parsed = JSON.parse_string(names_file.get_as_text())
		if parsed is Dictionary:
			for entry in parsed.get("types", []):
				if entry.get("name") != null:
					type_names[int(entry.id)] = String(entry.name)

func _ready() -> void:
	construction.type_names = type_names
	construction.changed.connect(_sync_construction)
	construction.audio_reset_requested.connect(AudioEffects.stop_bank_effects)
	construction.audio_state_provider=AudioEffects.playback_snapshot
	construction.puzzle_install_requested.connect(_install_puzzle)
	add_theme_constant_override("separation", 6)
	var toolbar := HBoxContainer.new()
	toolbar.custom_minimum_size.y = 30
	add_child(toolbar)
	var heading := Label.new()
	heading.text = "Puzzle / playable slice"
	heading.custom_minimum_size.x = 150
	toolbar.add_child(heading)
	selector = OptionButton.new()
	selector.fit_to_longest_item = true
	selector.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	selector.item_selected.connect(_on_level_selected)
	toolbar.add_child(selector)
	previous_level_button = Button.new()
	previous_level_button.text = "Previous level"
	previous_level_button.pressed.connect(_change_level.bind(-1))
	toolbar.add_child(previous_level_button)
	next_level_button = Button.new()
	next_level_button.text = "Next level"
	next_level_button.pressed.connect(_change_level.bind(1))
	toolbar.add_child(next_level_button)
	var reload := Button.new()
	reload.text = "Reload"
	reload.pressed.connect(_reload)
	toolbar.add_child(reload)
	var reset_button := Button.new()
	reset_button.text = "Reset"
	reset_button.pressed.connect(_reset_simulation)
	toolbar.add_child(reset_button)
	var step_button := Button.new()
	step_button.text = "Step"
	step_button.pressed.connect(_step_simulation)
	toolbar.add_child(step_button)
	var run_button := Button.new()
	run_button.text = "Play"
	run_button.pressed.connect(_run_simulation)
	toolbar.add_child(run_button)
	var stop_button := Button.new()
	stop_button.text = "Stop"
	stop_button.pressed.connect(_stop_simulation)
	toolbar.add_child(stop_button)
	var pause_button := Button.new()
	pause_button.text = "Pause"
	pause_button.pressed.connect(_pause_simulation)
	toolbar.add_child(pause_button)
	sim_status = Label.new()
	sim_status.custom_minimum_size.x = 150
	toolbar.add_child(sim_status)
	var display_row := HBoxContainer.new()
	display_row.add_theme_constant_override("separation", 8)
	add_child(display_row)
	graphics_button = Button.new()
	graphics_button.text = "Graphics: On"
	graphics_button.toggle_mode = true
	graphics_button.button_pressed = true
	graphics_button.toggled.connect(_on_graphics_toggled)
	display_row.add_child(graphics_button)
	sound_button = Button.new()
	sound_button.toggle_mode = true
	sound_button.button_pressed = AudioEffects.effects_enabled
	sound_button.text = "Effects: On" if sound_button.button_pressed else "Effects: Off"
	sound_button.toggled.connect(_on_sound_toggled)
	display_row.add_child(sound_button)
	test_sound_button = Button.new()
	test_sound_button.text = "Test sound"
	test_sound_button.disabled = not sound_button.button_pressed
	test_sound_button.pressed.connect(_test_sound)
	display_row.add_child(test_sound_button)
	graphics_status = Label.new()
	graphics_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	graphics_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	display_row.add_child(graphics_status)
	var music_row := HBoxContainer.new()
	music_row.add_theme_constant_override("separation", 8)
	add_child(music_row)
	music_button = Button.new()
	music_button.toggle_mode = true
	music_button.toggled.connect(MusicPlayer.set_music_enabled)
	music_row.add_child(music_button)
	var previous_track := Button.new()
	previous_track.text = "Previous track"
	previous_track.pressed.connect(func(): MusicPlayer.change_track(-1))
	music_row.add_child(previous_track)
	music_selector = OptionButton.new()
	music_selector.custom_minimum_size.x = 180
	for song_id: int in MusicPlayer.playlist:
		music_selector.add_item(MusicPlayer.get_song_name(song_id), song_id)
	music_selector.item_selected.connect(func(index: int): MusicPlayer.select_song(music_selector.get_item_id(index)))
	music_row.add_child(music_selector)
	var next_track := Button.new()
	next_track.text = "Next track"
	next_track.pressed.connect(func(): MusicPlayer.change_track(1))
	music_row.add_child(next_track)
	var volume_label := Label.new()
	volume_label.text = "Music volume"
	music_row.add_child(volume_label)
	music_volume = HSlider.new()
	music_volume.min_value = 0
	music_volume.max_value = 7
	music_volume.step = 1
	music_volume.custom_minimum_size.x = 120
	music_volume.value_changed.connect(func(value: float): MusicPlayer.set_volume_step(int(value)))
	music_row.add_child(music_volume)
	MusicPlayer.playback_changed.connect(_sync_music_controls)
	MusicPlayer.playback_failed.connect(func(message: String): grab_status.text = message)
	_sync_music_controls()
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(split)
	canvas = PuzzleCanvas.new(catalog)
	canvas.custom_minimum_size = Vector2(560, 400)
	canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	canvas.part_selected.connect(_on_canvas_part_selected)
	canvas.board_clicked.connect(_on_board_clicked)
	canvas.board_hovered.connect(_move_grab)
	canvas.rope_endpoint_selected.connect(_take_rope_endpoint)
	canvas.rope_editor=rope_editor
	canvas.belt_editor=belt_editor
	canvas.belt_endpoint_selected.connect(_take_belt_endpoint)
	canvas.graphics_status_changed.connect(_on_graphics_status_changed)
	split.add_child(canvas)
	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 460
	split.add_child(right)
	var inventory_heading := Label.new()
	inventory_heading.text = "Inventory (select a part, then Take)"
	right.add_child(inventory_heading)
	inventory_selector = OptionButton.new()
	inventory_selector.fit_to_longest_item = false
	inventory_selector.clip_text = true
	inventory_selector.item_selected.connect(_on_inventory_selected)
	right.add_child(inventory_selector)
	take_button = Button.new()
	take_button.text = "Take"
	take_button.pressed.connect(_take_inventory)
	right.add_child(take_button)
	grab_status = Label.new()
	grab_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	grab_status.text = "Ready — choose an item and press Take."
	right.add_child(grab_status)
	var transform_row := HBoxContainer.new()
	var rotate_button := Button.new()
	rotate_button.text = "Rotate"
	rotate_button.pressed.connect(_rotate_selected)
	transform_row.add_child(rotate_button)
	var flip_x_button := Button.new()
	flip_x_button.text = "Flip X"
	flip_x_button.pressed.connect(_flip_x_selected)
	transform_row.add_child(flip_x_button)
	var flip_y_button := Button.new()
	flip_y_button.text = "Flip Y"
	flip_y_button.pressed.connect(_flip_y_selected)
	transform_row.add_child(flip_y_button)
	right.add_child(transform_row)
	place_solution_button = Button.new()
	place_solution_button.text = "Place solution"
	place_solution_button.tooltip_text = "Restart paused with all parts at their saved positions, sizes, flips and settings. Press Run to simulate."
	place_solution_button.disabled = true
	place_solution_button.pressed.connect(_place_solution)
	right.add_child(place_solution_button)
	var complete_button := Button.new()
	complete_button.text = "Check solution"
	complete_button.pressed.connect(_check_solution)
	right.add_child(complete_button)
	# Keep placement controls visible even when puzzle records or status text
	# are long. Only the explanatory content participates in vertical scrolling.
	var details_scroll := ScrollContainer.new()
	details_scroll.name = "PuzzleDetailsScroll"
	details_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	details_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	details_scroll.custom_minimum_size.y = 120
	right.add_child(details_scroll)
	var details_content := VBoxContainer.new()
	details_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	details_scroll.add_child(details_content)
	summary_label = Label.new()
	summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	details_content.add_child(summary_label)
	var objective_heading := Label.new()
	objective_heading.text = "Level objective"
	objective_heading.tooltip_text = "Play or Step checks the level’s winning condition after each update."
	details_content.add_child(objective_heading)
	objective_status = Label.new()
	objective_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	details_content.add_child(objective_status)
	completion_actions=HBoxContainer.new()
	completion_actions.visible=false
	details_content.add_child(completion_actions)
	var replay:=Button.new()
	replay.text="Instant replay"
	replay.pressed.connect(func(): construction.replay_completed())
	completion_actions.add_child(replay)
	completion_next=Button.new()
	completion_next.text="Next puzzle"
	completion_next.pressed.connect(func(): construction.advance_campaign())
	completion_actions.add_child(completion_next)
	var return_button:=Button.new()
	return_button.text="Return to construction"
	return_button.pressed.connect(func(): construction.stop())
	completion_actions.add_child(return_button)
	detail_label = RichTextLabel.new()
	detail_label.bbcode_enabled = true
	detail_label.fit_content = true
	detail_label.scroll_active = false
	details_content.add_child(detail_label)
	construction.level_load_requested.connect(_load_source)
	_reload()
	set_process(true)

func _reload() -> void:
	selector.clear()
	levels = reader.list_levels()
	construction.level_sources=levels.duplicate()
	for name in levels:
		var entry := catalog.get_entry(name)
		var label: String = name
		if String(name).get_extension().to_lower()=="json": label=String(name).get_file()+" (Home Toons)"
		if String(entry.get("construction_context", "")) == "home_toons":
			label = "%s — %s (Home Toons)" % [name, entry.get("title", "")]
		selector.add_item(label)
	if levels.is_empty():
		previous_level_button.disabled = true
		next_level_button.disabled = true
		summary_label.text = "No puzzle resources found in the packaged catalog."
		if objective_status != null:
			objective_status.text = "READY: no puzzle data"
		return
	var preferred := levels.find("CAKE1.LEV")
	var index := preferred if preferred >= 0 else 0
	selector.select(index)
	_show_level(index)

func _load_source(source_name: String) -> void:
	var index:=levels.find(source_name)
	if index<0: return
	selector.select(index)
	_show_level(index)

func _on_level_selected(index: int) -> void:
	_show_level(index)

func _change_level(direction: int) -> void:
	var index := selector.selected + direction
	if index < 0 or index >= levels.size():
		return
	selector.select(index)
	_show_level(index)

func _on_graphics_toggled(enabled: bool) -> void:
	graphics_button.text = "Graphics: On" if enabled else "Graphics: Off"
	canvas.set_graphics_enabled(enabled)
	_on_graphics_status_changed(canvas.get_graphics_status())

func _on_graphics_status_changed(message: String) -> void:
	if graphics_status != null:
		graphics_status.text = message

func _process(delta: float) -> void:
	construction.advance(delta)

func _on_sound_toggled(enabled: bool) -> void:
	AudioEffects.set_effects_enabled(enabled)
	if runner != null: runner.set_audio_enabled(enabled)
	sound_button.text = "Effects: On" if enabled else "Effects: Off"
	test_sound_button.disabled = not enabled

func _test_sound() -> void:
	if not AudioEffects.play_sample(3040):
		grab_status.text = "The sound could not be played. Check the Godot output for details."

func _sync_music_controls() -> void:
	music_button.set_pressed_no_signal(MusicPlayer.music_enabled)
	music_button.text = "Music: On" if MusicPlayer.music_enabled else "Music: Off"
	music_selector.select(music_selector.get_item_index(MusicPlayer.current_song_id))
	music_volume.set_value_no_signal(MusicPlayer.volume_step)

func _run_simulation() -> void:
	construction.play()

func _pause_simulation() -> void:
	construction.pause()

func _step_simulation() -> void:
	construction.step()

func _reset_simulation() -> void:
	construction.reset()
	_update_objective({"status": "reset", "message": "Initial placement restored."})

func _place_solution() -> void:
	construction.reset(true)
	_update_objective({"status": "placed", "message": "Saved layout restored. Play simulates; Stop restores this arrangement; Reset returns to the initial puzzle."})

func _update_sim_status() -> void:
	if runner == null:
		sim_status.text = "sim: unavailable"
		return
	sim_status.text = "sim %s t=%d" % ["run" if runner.state.running else "pause", runner.state.tick]

func _show_level(index: int) -> void:
	var was_editor:=construction.is_editor()
	construction.editor_solution.clear()
	_cancel_grab()
	if index < 0 or index >= levels.size():
		return
	previous_level_button.disabled = index == 0
	next_level_button.disabled = index == levels.size() - 1
	selector.tooltip_text = selector.get_item_text(index)
	place_solution_button.disabled = true
	var puzzle := reader.read_level(levels[index])
	if puzzle == null:
		summary_label.text = reader.last_error
		detail_label.text = ""
		return
	_install_puzzle(puzzle)
	if was_editor and not construction.is_editor(): construction.toggle_editor()

func _install_puzzle(puzzle: PuzzleDefinition) -> void:
	canvas.set_puzzle(puzzle)
	canvas.set_graphics_enabled(graphics_button.button_pressed)
	_on_graphics_status_changed(canvas.get_graphics_status())
	if not construction.retain_completion_audio: AudioEffects.stop_bank_effects()
	runner = SimulationRunner.new(puzzle)
	MusicPlayer.set_level_music(puzzle.music)
	runner.sound_effect_requested.connect(AudioEffects.handle_event)
	runner.set_audio_enabled(AudioEffects.effects_enabled)
	runner.audio_clock_advanced.connect(AudioEffects.sync_simulation_audio)
	if not construction.retain_completion_audio: AudioEffects.sync_simulation_audio(runner.state.audio.snapshot())
	place_solution_button.disabled = false
	tick_accumulator = 0.0
	objective = PlacementObjective.new()
	selected_index = -1
	_update_sim_status()
	canvas.set_runtime(runner.state)
	inventory_selector.clear()
	for part_index in puzzle.parts.size():
		var part: PartDefinition = puzzle.parts[part_index]
		if part.is_in_parts_bin():
			inventory_selector.add_item("%s (type %d)" % [type_names.get(part.part_type, "Unknown part"), part.part_type])
			inventory_selector.set_item_metadata(inventory_selector.item_count - 1, part_index)
	if inventory_selector.item_count > 0:
		inventory_selector.select(0)
		selected_index = int(inventory_selector.get_item_metadata(0))
	if runner.uses_world_physics():
		_check_solution()
	else:
		_update_objective({"status": "unavailable", "message": "Physics tables could not be loaded."})
	var counts := puzzle.observed_counts()
	summary_label.text = "%s\n%s\n\nFormat: 0x%04X v%04X\nHeader: pressure %d, gravity %d, music %d\nDeclared fixed/moving: %d / %d\nObserved: %s\nTail: %d bytes at 0x%X" % [puzzle.source_name, puzzle.title, puzzle.format_magic, puzzle.format_version, puzzle.pressure, puzzle.gravity, puzzle.music, puzzle.fixed_count, puzzle.moving_count, str(counts), puzzle.tail.size(), puzzle.tail_offset]
	var lines: Array[String] = ["[b]Instructions[/b]", puzzle.instructions, "", "[b]Part records[/b]"]
	for part_index in puzzle.parts.size():
		var part: PartDefinition = puzzle.parts[part_index]
		lines.append("%02d  %s (type %d)  %s  pos=(%d,%d) size=(%d,%d) flags=%04X/%04X/%04X links=%d,%d" % [part_index, type_names.get(part.part_type, "Unknown"), part.part_type, part.category(), part.pos_x, part.pos_y, part.width_1, part.height_1, part.flags_1, part.flags_2, part.flags_3, part.connected_1, part.connected_2])
	if not puzzle.scan_error.is_empty():
		lines.append("\n[color=yellow]Scan note: %s[/color]" % puzzle.scan_error)
	detail_label.text = "\n".join(lines)

func _on_inventory_selected(option_index: int) -> void:
	if grab_index>=0 or (rope_editor.active() or belt_editor.active()): return
	if option_index >= 0 and option_index < inventory_selector.item_count:
		selected_index = int(inventory_selector.get_item_metadata(option_index))

func _input(event: InputEvent) -> void:
	if construction.cancel_input(event):
		get_viewport().set_input_as_handled()

func _take_inventory() -> void:
	var option := inventory_selector.selected
	if option >= 0:
		var id:=int(inventory_selector.get_item_metadata(option))
		if id<=-100: construction.take_type(-100-id,false)
		else: construction.take(id)

func _begin_grab(index: int) -> void:
	construction.invoke("_begin_grab", [index])

func _cancel_grab() -> void:
	construction.invoke("_cancel_grab", [])

func _refresh_inventory() -> void:
	if inventory_selector==null or runner==null: return
	var previous: int=int(inventory_selector.get_item_metadata(inventory_selector.selected)) if inventory_selector.selected>=0 else -1
	inventory_selector.clear()
	if construction.is_editor():
		var order: Array=JSON.parse_string(FileAccess.get_file_as_string("res://assets/original/dos_inventory_ui.json")).inventory_order
		for type_id in order:
			inventory_selector.add_item("%s (type %d)"%[type_names.get(int(type_id),"Gadget"),int(type_id)])
			inventory_selector.set_item_metadata(inventory_selector.item_count-1,-100-int(type_id))
			if -100-int(type_id)==previous: inventory_selector.select(inventory_selector.item_count-1)
		return
	for p in runner.state.parts:
		if not construction.inventory_visible(p.index): continue
		if p.spawned or p.definition==null: continue
		if p.definition.is_in_parts_bin() or not p.placed:
			inventory_selector.add_item("%s (type %d)" % [type_names.get(p.part_type,"Unknown part"),p.part_type])
			inventory_selector.set_item_metadata(inventory_selector.item_count-1,p.index)
			if p.index==previous: inventory_selector.select(inventory_selector.item_count-1)

func _move_grab(position: Vector2i) -> void:
	construction.invoke("_move_grab", [position])

func _take_rope_endpoint(owner: int, side: int) -> void:
	construction.invoke("_take_rope_endpoint", [owner, side])

func _on_canvas_part_selected(index: int) -> void:
	_begin_grab(index)

func _on_board_clicked(position: Vector2i) -> void:
	construction.invoke("_on_board_clicked", [position])

func _rotate_selected() -> void:
	construction.invoke("_rotate_selected", [])

func _flip_x_selected() -> void:
	construction.invoke("_flip_x_selected", [])

func _flip_y_selected() -> void:
	construction.invoke("_flip_y_selected", [])

func _apply_transform(rotation: int, flip_x: bool, flip_y: bool) -> void:
	construction.invoke("_apply_transform", [rotation, flip_x, flip_y])

func _check_solution() -> void:
	if runner == null: return
	var goal: Dictionary=runner.state.goal
	if not String(goal.get("error","")).is_empty():
		_update_objective({"status":"error","message":String(goal.error)})
	elif construction.is_completed():
		_update_objective({"status":"won","message":"Goal completed at update %d. Instant replay restores your arrangement."%int(goal.get("completion_tick",runner.state.tick))})
	elif not bool(goal.get("enabled",false)):
		_update_objective({"status":"ready","message":"Manual judging. Compare the result with the Goal text."})
	elif int(goal.get("countdown",-1))>=0:
		_update_objective({"status":"ready","message":"Goal reached. Completion in %d updates."%int(goal.countdown + 1)})
	elif runner.state.tick == 0:
		_update_objective({"status":"ready","message":"Play or Step tests the winning condition."})
	else:
		_update_objective({"status":"incomplete","message":"Waiting for the level’s winning condition."})

func _update_objective(result: Dictionary) -> void:
	if objective_status == null:
		return
	var status := String(result.get("status", ""))
	var message := String(result.get("message", ""))
	objective_status.text = "%s: %s" % [status.to_upper(), message]
	objective_status.modulate = Color("8be28b") if status == "won" else Color("e9d18b") if status in ["incomplete", "ready", "placed", "reset"] else Color("e28b8b")

func _take_belt_endpoint(owner: int, side: int) -> void:
	construction.invoke("_take_belt_endpoint", [owner, side])


func _stop_simulation() -> void:
	construction.stop()

func _sync_construction() -> void:
	if canvas == null or runner == null: return
	var source:=runner.puzzle.source_name
	if not levels.has(source):
		levels.append(source)
		selector.add_item(source.get_file()+" (Home Toons)")
	selector.select(levels.find(source))
	previous_level_button.disabled=selector.selected<=0
	next_level_button.disabled=selector.selected>=levels.size()-1
	canvas.grab_active = construction.grab_active
	canvas.selected_index = selected_index
	canvas.editing_enabled = construction.play_backup == null
	canvas.set_runtime(runner.state)
	grab_status.text = construction.status
	_update_sim_status()
	_refresh_inventory()
	if selected_index < 0: inventory_selector.select(-1)
	if completion_actions!=null:
		completion_actions.visible=construction.is_completed()
		completion_next.disabled=construction.next_campaign_level().is_empty()
		_check_solution()
