extends VBoxContainer
const Controls=preload("res://scripts/ui/head_to_head_controls.gd")
const Game=preload("res://scripts/ui/game_emulation.gd")
var construction:=Controls.new()
var catalog: ResourceCatalog
var game: Control
var mode: OptionButton
var level: OptionButton
var rounds: SpinBox
var names: Array[LineEdit]=[]
var timers: Array[SpinBox]=[]
var turn_label: Label
var status_label: Label
var begin_button: Button
var bell: Button
var next_button: Button
var replay_button: Button
var solution_button: Button
var reset_match_button: Button
var goal_label: Label
var bound_runner: SimulationRunner

func _init(resource_catalog: ResourceCatalog) -> void:
	catalog=resource_catalog

func _ready() -> void:
	if construction.library.levels.is_empty():
		_label(self, "Head-2-head needs the optional Windows game data. Select a Windows copy in the asset importer to enable the 50 puzzles.")
		set_process(false)
		return
	var type_data: Variant=JSON.parse_string(FileAccess.get_file_as_string("res://assets/original/part_type_names.json"))
	for entry in type_data.get("types",[]):
		if entry.get("name")!=null: construction.type_names[int(entry.id)]=String(entry.name)
	construction.audio_state_provider=AudioEffects.playback_snapshot
	construction.turn_expired.connect(func(): AudioEffects.play_sample(3052))
	construction.audio_reset_requested.connect(func():
		if is_visible_in_tree(): AudioEffects.stop_bank_effects())
	var setup:=HBoxContainer.new()
	add_child(setup)
	mode=OptionButton.new()
	for title in ["Single Match","Tournament","Solo practice"]: mode.add_item(title)
	setup.add_child(mode)
	level=OptionButton.new()
	level.fit_to_longest_item=false
	level.custom_minimum_size.x=360
	for entry in construction.library.levels: level.add_item("PLAY%d — %s"%[int(entry.number),String(entry.title)],int(entry.number))
	setup.add_child(level)
	_label(setup,"Games")
	rounds=_spinner(setup,1,9,7)
	_button(setup,"Start new match",_start)
	var players:=HBoxContainer.new()
	add_child(players)
	for who in ["Sid","Al"]:
		_label(players,who+" player")
		var name_edit:=LineEdit.new()
		name_edit.text=who
		name_edit.max_length=11
		name_edit.custom_minimum_size.x=130
		players.add_child(name_edit)
		names.append(name_edit)
		_label(players,"seconds / turn")
		timers.append(_spinner(players,10,599,45))
	_button(players,"Default timers",func():
		for timer in timers: timer.value=45)
	var actions:=HBoxContainer.new()
	add_child(actions)
	begin_button=_button(actions,"Begin turn",func():
		game.goal_pending=false
		game.right_dialog.close()
		construction.begin_turn())
	bell=_button(actions,"Bell — End turn",func():
		AudioEffects.play_sample(4033)
		construction.end_turn())
	next_button=_button(actions,"Next round",func(): construction.next_round())
	replay_button=_button(actions,"Replay round",construction.replay_round)
	solution_button=_button(actions,"Reset puzzle (solo)",func(): construction.reset(false))
	reset_match_button=_button(actions,"Reset puzzle",func(): game.right_dialog.open("nuke"))
	turn_label=_label(actions,"")
	goal_label=_label(self,"")
	goal_label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
	status_label=_label(self,"")
	status_label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
	game=Game.new(catalog,construction)
	game.external_match_controls=true
	game.size_flags_vertical=Control.SIZE_EXPAND_FILL
	add_child(game)
	construction.changed.connect(_sync)
	mode.item_selected.connect(func(_index: int): _sync_setup())
	visibility_changed.connect(_visibility_changed)
	_start()

func _label(parent: Node, text: String) -> Label:
	var label:=Label.new()
	label.text=text
	parent.add_child(label)
	return label

func _button(parent: Node, text: String, action: Callable) -> Button:
	var button:=Button.new()
	button.text=text
	button.pressed.connect(action)
	parent.add_child(button)
	return button

func _spinner(parent: Node, minimum: int, maximum: int, value: int) -> SpinBox:
	var spinner:=SpinBox.new()
	spinner.min_value=minimum
	spinner.max_value=maximum
	spinner.value=value
	spinner.step=1
	spinner.custom_minimum_size.x=85
	parent.add_child(spinner)
	return spinner

func _start() -> void:
	if game!=null:
		game.program_dialog.close()
		game.right_dialog.close()
	construction.start_match(maxi(1,level.get_selected_id()),mode.selected==1,int(rounds.value),
		[int(timers[0].value),int(timers[1].value)],[names[0].text,names[1].text],mode.selected==2)
	_sync_setup()

func _sync_setup() -> void:
	level.disabled=mode.selected==1
	rounds.editable=mode.selected==1
	for timer in timers: timer.editable=mode.selected!=2
	_sync()

func _sync() -> void:
	if status_label==null: return
	status_label.text=construction.status
	var c:=construction
	if c.runner==null: return
	if bound_runner!=c.runner:
		bound_runner=c.runner
		bound_runner.sound_effect_requested.connect(func(event: Dictionary):
			if is_visible_in_tree(): AudioEffects.handle_event(event))
		bound_runner.audio_clock_advanced.connect(func(snapshot: Dictionary):
			if is_visible_in_tree(): AudioEffects.sync_simulation_audio(snapshot))
		bound_runner.set_audio_enabled(AudioEffects.effects_enabled)
		if is_visible_in_tree(): MusicPlayer.set_level_music(bound_runner.puzzle.music)
	goal_label.text="%s — %s\n%s"%[c.runner.puzzle.source_name,c.runner.puzzle.title,c.runner.puzzle.instructions]
	begin_button.disabled=not c.active_match or not c.awaiting_turn or c.round_complete or c.solo
	bell.disabled=not c.active_match or c.awaiting_turn or c.round_complete or c.play_backup!=null or c.solo
	next_button.disabled=not c.round_complete or c.round_index+1>=c.schedule.size()
	replay_button.disabled=not c.round_complete
	solution_button.visible=c.solo
	solution_button.disabled=c.play_backup!=null or c.grab_active
	reset_match_button.visible=not c.solo
	reset_match_button.disabled=not c.active_match or c.round_complete or c.play_backup!=null or c.grab_active
	if c.round_complete and c.round_index+1==c.schedule.size() and not c.solo:
		var result: String="Draw" if c.scores[0]==c.scores[1] else c.player_names[0 if c.scores[0]>c.scores[1] else 1]+" wins"
		status_label.text=c.status+" Match over: "+result+"."
	_clock_label()
	game._sync()

func _clock_label() -> void:
	var c:=construction
	turn_label.text="Solo — no timer" if c.solo else "%s  %d:%02d | Round %d/%d | %s %d : %d %s"%[
		c.player_names[c.player],ceili(c.remaining)/60,ceili(c.remaining)%60,c.round_index+1,c.schedule.size(),c.player_names[0],c.scores[0],c.scores[1],c.player_names[1]]

func _process(delta: float) -> void:
	if game==null or not is_visible_in_tree(): return
	if game.turn_splash!=null and game.turn_splash.waiting():
		game.turn_splash.advance(delta)
		_clock_label()
		return
	construction.advance(delta)
	_clock_label()

func _visibility_changed() -> void:
	if game==null: return
	# Hiding a local hot-seat game pauses it, so other tabs remain usable.
	if not is_visible_in_tree():
		game.program_dialog.close()
		return
	AudioEffects.stop_bank_effects()
	if construction.runner!=null:
		AudioEffects.sync_simulation_audio(construction.runner.state.audio.snapshot())
		MusicPlayer.set_level_music(construction.runner.puzzle.music)
