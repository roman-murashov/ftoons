extends CenterContainer
## Original DOS presentation of one shared construction session.
const PuzzleCanvas = preload("res://scripts/ui/puzzle_canvas.gd")
const Art = preload("res://scripts/ui/dos_inventory_art.gd")
const Formats = preload("res://scripts/graphics/dynamix_formats.gd")
const SpriteGraphicsPack = preload("res://scripts/graphics/sprite_graphics_pack.gd")
const PAGE_SIZE := 5
const BUTTON_PRESS_SECONDS := 20.0*5041.0/1193182.0
const GRAPHICS_TITLE := "DOS/WIN Graphics"
const ACTIVE_GRAPHICS_COLOR := "#81e294"
var construction: RefCounted
var catalog: ResourceCatalog
var sprite_graphics: SpriteGraphicsPack
var canvas: PuzzleCanvas
var inventory: Control
var play_button: Button
var stop_button: Button
var remote_button: Button
var status: Label
var screen: Control
var display_frame: Control
var display_buttons: Array[Button] = []
var graphics_button: Button
var graphics_label: RichTextLabel
var graphics_status: Label
var music_pack_button: Button
var music_pack_label: RichTextLabel
var music_power_button: Button
var music_status: Label
var intro_button: Button
var intro_label: RichTextLabel
var intro_player: Control
var intro_pending := false
var art: Control
var remote_controls: Control
var inventory_signature := ""
var item_buttons: Dictionary = {}
var inventory_icons: Array[Texture2D] = []
var transform_buttons: Array[Button] = []
var page := 0
var remote_open := false
var press_remaining := 0.0
var pending_play_runner: SimulationRunner
var pending_play_audio: AudioPlaybackState
var cursor: TextureRect
var cursor_frames: Array[Texture2D] = []
var cursor_index := 0
var owns_cursor := false
var previous_mouse_mode := Input.MOUSE_MODE_VISIBLE
var count_font: Dictionary = {}
var count_cache: Dictionary = {}
var gadget_overlay: Control
var program_dialog: Control
var right_dialog: Control
var guest_pointer := Vector2(-1000,-1000)
var editor_buttons: Array[Button]=[]
var home_button: Button
var completion_dialog: Control
var goal_pending := false
## Head-to-head owns turn/result controls; campaign navigation stays isolated.
var external_match_controls:=false
var match_timer_panel:=true
var match_bar: Control
var turn_splash: Control
var match_turn_key: String=""

func _init(resource_catalog: ResourceCatalog, controls: RefCounted) -> void:
	catalog = resource_catalog
	construction = controls
	sprite_graphics = SpriteGraphicsPack.new(catalog)

func _ready() -> void:
	var column := VBoxContainer.new()
	add_child(column)
	var display_controls := HBoxContainer.new()
	display_controls.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(display_controls)
	var group := ButtonGroup.new()
	for title in ["1:1", "640x480 stretched"]:
		var button := Button.new()
		button.text = title
		button.toggle_mode = true
		button.button_group = group
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(_set_display_mode.bind(display_buttons.size()))
		display_buttons.append(button)
		display_controls.add_child(button)
	_add_graphics_toggle(display_controls)
	_add_intro_toggle(display_controls)
	var goal_setting := CheckBox.new()
	goal_setting.text="Show goal screen on level start"
	goal_setting.button_pressed=PortSettings.show_goal_on_level_start
	goal_setting.toggled.connect(PortSettings.set_show_goal_on_level_start)
	display_controls.add_child(goal_setting)
	graphics_status = Label.new()
	graphics_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	graphics_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(graphics_status)
	_update_graphics_status()
	_add_music_controls(column)
	display_frame = Control.new()
	display_frame.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	display_frame.clip_contents = true
	column.add_child(display_frame)
	screen = Control.new()
	screen.size = Vector2(640,400)
	screen.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	display_frame.add_child(screen)
	_set_display_mode(0)
	canvas = PuzzleCanvas.new(catalog, sprite_graphics)
	canvas.position = Vector2(88,0)
	canvas.size = Vector2(552,400)
	canvas.native_screen = true
	canvas.clip_contents = true
	canvas.show_selection = false
	canvas.rope_editor = construction.rope_editor
	canvas.belt_editor = construction.belt_editor
	canvas.part_selected.connect(func(index: int): construction.pick_native(index,canvas.last_pointer))
	canvas.board_hovered.connect(func(point: Vector2i): construction.invoke("_move_grab", [point]))
	canvas.board_clicked.connect(func(point: Vector2i): construction.invoke("_on_board_clicked", [point]))
	canvas.rope_endpoint_selected.connect(func(owner: int, side: int): construction.invoke("_take_rope_endpoint", [owner, side]))
	canvas.belt_endpoint_selected.connect(func(owner: int, side: int): construction.invoke("_take_belt_endpoint", [owner, side]))
	screen.add_child(canvas)
	art = Art.new(catalog, sprite_graphics)
	art.size = Vector2(640,400)
	screen.add_child(art)
	# Inclusive rectangles from original DS:119E..1288.
	play_button = _button(screen,Rect2(3,8,52,74),"Run",_play)
	remote_button = _button(screen,Rect2(53,32,33,40),"Remote control",_toggle_remote)
	_button(screen,Rect2(1,354,43,35),"Previous gadgets",_page.bind(-1))
	_button(screen,Rect2(44,353,44,40),"Next gadgets",_page.bind(1))
	_button(screen,Rect2(7,94,67,246),"Return gadget",_return_gadget)
	inventory = Control.new()
	inventory.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(inventory)
	inventory_icons = sprite_graphics.frames("ICONS.BMP")
	remote_controls = Control.new()
	remote_controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(remote_controls)
	home_button=_button(remote_controls,Rect2(583,0,57,61),"Go to Home Toons",func():
		if external_match_controls:
			construction.leave_match()
		else: construction.toggle_editor())
	editor_buttons.append(_button(remote_controls,Rect2(616,61,24,36),"Save Home Toon",func(): right_dialog.open("editor_save")))
	editor_buttons.append(_button(remote_controls,Rect2(593,97,47,46),"Save Home Toon",func(): right_dialog.open("editor_save")))
	editor_buttons.append(_button(remote_controls,Rect2(593,299,47,47),"Make-A-Toon checklist",func(): right_dialog.open("editor_checklist")))
	_button(remote_controls,Rect2(592,73,24,26),"Load puzzle",func(): right_dialog.open("load"))
	for entry in [[Rect2(593,144,42,50),"goal","Puzzle goal"],
		[Rect2(591,241,49,56),"nuke","Return placed gadgets to inventory"],
		[Rect2(593,348,47,45),"exit","Exit game"]]:
		_button(remote_controls,entry[0],entry[2],func():
			right_dialog.open("editor_goal" if entry[1]=="goal" and construction.is_editor() else entry[1]))
	_button(remote_controls,Rect2(587,191,53,50),"Tunes",func(): right_dialog.open("tunes"))
	if external_match_controls:
		match_bar=preload("res://scripts/ui/head_to_head_bar.gd").new(self)
		screen.add_child(match_bar)
	# Original running input table DS:1A06: any screen click stops the run.
	stop_button = _button(screen,Rect2(0,0,640,400),"Stop and restore arrangement",_stop)
	stop_button.tooltip_text = ""
	stop_button.visible = false
	cursor_frames = sprite_graphics.frames("MOUSE.BMP")
	gadget_overlay=preload("res://scripts/ui/dos_gadget_overlay.gd").new(self)
	gadget_overlay.size=Vector2(640,400)
	screen.add_child(gadget_overlay)
	program_dialog=preload("res://scripts/ui/gadget_program_dialog.gd").new(self)
	screen.add_child(program_dialog)
	right_dialog=preload("res://scripts/ui/right_bar_dialog.gd").new(self)
	screen.add_child(right_dialog)
	right_dialog.exit_requested.connect(func(): get_tree().quit())
	completion_dialog=preload("res://scripts/ui/campaign_completion.gd").new(self)
	screen.add_child(completion_dialog)
	intro_player = preload("res://scripts/ui/windows_level_intro.gd").new(self)
	intro_player.finished.connect(func(): _sync())
	screen.add_child(intro_player)
	if external_match_controls:
		turn_splash=preload("res://scripts/ui/head_to_head_turn_splash.gd").new(self)
		screen.add_child(turn_splash)
	cursor = TextureRect.new()
	cursor.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	cursor.stretch_mode = TextureRect.STRETCH_KEEP
	cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cursor.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	screen.add_child(cursor)
	count_font = Formats.decode_font(catalog.read_asset("SSD14_22.FNT"))
	status = Label.new()
	status.visible = false
	add_child(status)
	construction.changed.connect(_sync)
	construction.audio_reset_requested.connect(_cancel_pending_play)
	_sync()

func _add_graphics_toggle(parent: Control) -> void:
	graphics_button = Button.new()
	graphics_button.name = "GraphicsPack"
	graphics_button.toggle_mode = true
	graphics_button.accessibility_name = GRAPHICS_TITLE
	parent.add_child(graphics_button)
	var font := graphics_button.get_theme_font("font")
	var font_size := graphics_button.get_theme_font_size("font_size")
	var text_size := font.get_string_size(GRAPHICS_TITLE, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	graphics_button.custom_minimum_size = text_size.ceil() + graphics_button.get_theme_stylebox("normal").get_minimum_size()
	graphics_label = RichTextLabel.new()
	graphics_label.bbcode_enabled = true
	graphics_label.scroll_active = false
	graphics_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	graphics_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	graphics_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	graphics_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	graphics_label.add_theme_font_override("normal_font", font)
	graphics_label.add_theme_font_size_override("normal_font_size", font_size)
	graphics_button.add_child(graphics_label)
	graphics_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	graphics_button.toggled.connect(_set_graphics_pack)
	_set_graphics_pack(false)

func _set_graphics_pack(windows: bool) -> void:
	var active := sprite_graphics.set_alternate_enabled(windows)
	graphics_button.set_pressed_no_signal(active)
	var highlight := "[color=%s]%s[/color]"
	var dos := "DOS" if active else highlight % [ACTIVE_GRAPHICS_COLOR, "DOS"]
	var win := highlight % [ACTIVE_GRAPHICS_COLOR, "WIN"] if active else "WIN"
	graphics_label.text = "%s/%s Graphics" % [dos, win]
	if active:
		graphics_button.tooltip_text = "Windows graphics: %d compatible frames loaded." % sprite_graphics.replacement_count()
	elif windows:
		graphics_button.tooltip_text = sprite_graphics.load_error if not sprite_graphics.load_error.is_empty() else "No compatible Windows frames were found."
	else:
		graphics_button.tooltip_text = GRAPHICS_TITLE
	_update_graphics_status(windows and not active)
	if graphics_status != null:
		print("Game emulation graphics: ", graphics_status.text)

func _update_graphics_status(failed: bool = false) -> void:
	if graphics_status == null: return
	if failed:
		graphics_status.text = "Windows graphics unavailable: " + graphics_button.tooltip_text
		graphics_status.modulate = Color("ff9797")
	elif sprite_graphics.alternate_enabled:
		graphics_status.text = "WIN graphics active — %d loaded frames replaced; unmapped frames use DOS." % sprite_graphics.replacement_count()
		graphics_status.modulate = Color(ACTIVE_GRAPHICS_COLOR)
	else:
		graphics_status.text = "DOS graphics active"
		graphics_status.modulate = Color.WHITE

func _add_music_controls(parent: Control) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	parent.add_child(row)
	music_pack_button = Button.new()
	music_pack_button.name = "MusicPack"
	music_pack_button.toggle_mode = true
	music_pack_button.accessibility_name = "MIDI/CD Music"
	row.add_child(music_pack_button)
	var font := music_pack_button.get_theme_font("font")
	var font_size := music_pack_button.get_theme_font_size("font_size")
	music_pack_button.custom_minimum_size = font.get_string_size("MIDI/CD Music",HORIZONTAL_ALIGNMENT_LEFT,-1,font_size).ceil() + music_pack_button.get_theme_stylebox("normal").get_minimum_size()
	music_pack_label = RichTextLabel.new()
	music_pack_label.bbcode_enabled = true
	music_pack_label.scroll_active = false
	music_pack_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	music_pack_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	music_pack_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	music_pack_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	music_pack_label.add_theme_font_override("normal_font",font)
	music_pack_label.add_theme_font_size_override("normal_font_size",font_size)
	music_pack_button.add_child(music_pack_label)
	music_pack_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	music_pack_button.toggled.connect(func(enabled: bool): MusicPlayer.set_cd_enabled(enabled); _sync_music_controls())
	music_power_button = Button.new()
	music_power_button.name = "MusicPower"
	music_power_button.toggle_mode = true
	music_power_button.toggled.connect(MusicPlayer.set_music_enabled)
	row.add_child(music_power_button)
	music_status = Label.new()
	music_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(music_status)
	MusicPlayer.playback_changed.connect(_sync_music_controls)
	_sync_music_controls()

func _sync_music_controls() -> void:
	var active: bool = MusicPlayer.cd_enabled
	music_pack_button.set_pressed_no_signal(active)
	var highlight := "[color=%s]%s[/color]"
	var midi := "MIDI" if active else highlight % [ACTIVE_GRAPHICS_COLOR,"MIDI"]
	var cd := highlight % [ACTIVE_GRAPHICS_COLOR,"CD"] if active else "CD"
	music_pack_label.text = "%s/%s Music" % [midi,cd]
	music_pack_button.tooltip_text = "Use confirmed CD recordings; unmatched songs keep DOS music. Switching preserves Music On/Off."
	if OS.has_feature("web"):
		music_pack_button.disabled=true
		music_pack_button.tooltip_text="CD music is not included in this Web build. DOS music and sound effects are available."
	music_power_button.set_pressed_no_signal(MusicPlayer.music_enabled)
	music_power_button.text = "Music: ON" if MusicPlayer.music_enabled else "Music: OFF"
	music_status.text = MusicPlayer.get_music_source_status()
	music_status.modulate = Color.WHITE if MusicPlayer.cd_status.is_empty() else Color("ff9797")

func _add_intro_toggle(parent: Control) -> void:
	intro_button = Button.new()
	intro_button.name = "IntroVideos"
	intro_button.toggle_mode = true
	intro_button.accessibility_name = "Play intro videos"
	intro_button.tooltip_text = "Play Windows dialogue animations before campaign levels. Click the game or press Escape to skip."
	parent.add_child(intro_button)
	var font := intro_button.get_theme_font("font")
	var font_size := intro_button.get_theme_font_size("font_size")
	intro_button.custom_minimum_size = font.get_string_size("Intro videos: OFF",HORIZONTAL_ALIGNMENT_LEFT,-1,font_size).ceil() + intro_button.get_theme_stylebox("normal").get_minimum_size()
	intro_label = RichTextLabel.new()
	intro_label.bbcode_enabled = true
	intro_label.scroll_active = false
	intro_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	intro_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	intro_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	intro_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	intro_label.add_theme_font_override("normal_font",font)
	intro_label.add_theme_font_size_override("normal_font_size",font_size)
	intro_button.add_child(intro_label)
	intro_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	intro_button.set_pressed_no_signal(PortSettings.play_intro_videos)
	_update_intro_label()
	intro_button.toggled.connect(_set_intro_videos)

func _update_intro_label() -> void:
	intro_label.text = "Intro videos: [color=%s]%s[/color]" % [ACTIVE_GRAPHICS_COLOR if intro_button.button_pressed else "#ff6666", "ON" if intro_button.button_pressed else "OFF"]

func _set_intro_videos(enabled: bool) -> void:
	PortSettings.set_play_intro_videos(enabled)
	_update_intro_label()
	if not enabled:
		intro_pending = false
		if intro_player != null: intro_player.finish()
	elif construction.runner != null and construction.play_backup == null and not construction.grab_active and not construction.is_editor():
		# Enabling on an idle level previews its intro immediately, too.
		right_dialog.close()
		program_dialog.close()
		intro_pending = true
		goal_pending = PortSettings.show_goal_on_level_start

func _set_display_mode(mode: int) -> void:
	# DOS framebuffer is 640x400. The second mode applies 6:5 vertical
	# aspect correction, without changing guest coordinates or shared state.
	var target := Vector2(640,400 if mode==0 else 480)
	display_frame.custom_minimum_size = target
	display_frame.size = target
	screen.scale = target / Vector2(640,400)
	display_buttons[mode].set_pressed_no_signal(true)
	# Layout will recenter the screen; wait for the next pointer event rather
	# than retaining a cursor position from the old screen transform.
	guest_pointer = Vector2(-1000,-1000)

func _button(parent: Node, rect: Rect2, hint: String, action: Callable) -> Button:
	var button := Button.new()
	button.position = rect.position
	button.size = rect.size
	button.tooltip_text = hint
	# Native control captions are MOUSE.BMP sprites, not host tooltip windows.
	if parent==screen or parent==remote_controls: button.tooltip_text=""
	button.focus_mode = Control.FOCUS_NONE
	for state in ["normal","hover","pressed","disabled","focus"]:
		button.add_theme_stylebox_override(state,StyleBoxEmpty.new())
	button.pressed.connect(action)
	var cursor_id := 0
	if hint == "Run": cursor_id = 13
	elif hint == "Remote control": cursor_id = 14
	elif hint == "Previous gadgets": cursor_id = 15
	elif hint == "Next gadgets": cursor_id = 16
	button.mouse_entered.connect(func(): cursor_index = cursor_id)
	button.mouse_exited.connect(func(): cursor_index = 0)
	parent.add_child(button)
	return button

func _animate(widget: String, sound_id: int) -> void:
	art.pressed = widget
	art.queue_redraw()
	AudioEffects.play_sample(sound_id)
	# 298D:09FD/0A02 calls Delay(20), using the same5041 PIT divisor
	# as the reward animation (about84.5ms, rather than the provisional120ms).
	press_remaining = BUTTON_PRESS_SECONDS

func _play() -> void:
	if intro_player != null and intro_player.visible: return
	if construction.runner == null or construction.grab_active or construction.play_backup != null or pending_play_runner!=null: return
	if external_match_controls:
		if not construction.active_match or construction.round_complete: return
		goal_pending=false
		right_dialog.close()
		construction.begin_turn()
	_animate("play",3047)
	# 298D:2015 completes the depressed-button Delay(20) before2029/2053
	# enters gameplay. Do not advance the world while that UI hold is active.
	pending_play_runner=construction.runner
	pending_play_audio=AudioPlaybackState.new()
	pending_play_audio.restore(AudioEffects.playback_snapshot())
	_sync()

func _cancel_pending_play() -> void:
	if pending_play_runner==null: return
	pending_play_runner=null
	pending_play_audio=null
	press_remaining=0.0
	art.pressed=""
	art.queue_redraw()

func _finish_play_press() -> void:
	var runner:=pending_play_runner
	var audio:=pending_play_audio
	pending_play_runner=null
	pending_play_audio=null
	if runner!=construction.runner or construction.play_backup!=null or construction.grab_active: return
	construction.play()
	# The native global sound cursor survives the UI/game clock boundary. Carry
	# the cue's remaining duration, rather than restarting its138ms duration.
	audio.advance_to(audio.clock+roundi(BUTTON_PRESS_SECONDS*AudioPlaybackState.CLOCK_HZ))
	var origin:=audio.clock
	for voice in audio.voices:
		if voice.is_empty(): continue
		voice.start=int(voice.start)-origin
		if int(voice.end)>0: voice.end=int(voice.end)-origin
	audio.clock=0
	audio.microsecond_remainder=0
	runner.state.audio.restore(audio.snapshot())
	AudioEffects.sync_simulation_audio(runner.state.audio.snapshot())

func _stop() -> void:
	construction.stop()

func _toggle_remote() -> void:
	if construction.play_backup != null or construction.grab_active: return
	if external_match_controls and not construction.solo:
		match_timer_panel=not match_timer_panel
	else:
		remote_open = not remote_open
	_animate("remote",3054)
	_sync()

func _return_gadget() -> void:
	if construction.grab_active:
		AudioEffects.play_sample(5)
		construction.invoke("_cancel_grab")

func _process(delta: float) -> void:
	if cursor == null: return
	if pending_play_runner!=null and (not is_visible_in_tree() or construction.runner!=pending_play_runner or construction.play_backup!=null or construction.grab_active):
		pending_play_runner=null
		pending_play_audio=null
		press_remaining=0.0
		art.pressed=""
		_sync()
	if intro_pending and is_visible_in_tree() and construction.play_backup==null and not construction.grab_active:
		intro_pending = false
		if PortSettings.play_intro_videos and not construction.is_editor():
			right_dialog.close()
			program_dialog.close()
			intro_player.begin(construction.runner.puzzle.source_name)
			if not intro_player.error.is_empty():
				graphics_status.text = "Intro unavailable: " + intro_player.error
				graphics_status.modulate = Color("ff9797")
	if goal_pending and not intro_player.visible and is_visible_in_tree() and construction.play_backup==null and not construction.grab_active:
		goal_pending=false
		if PortSettings.show_goal_on_level_start and not construction.is_editor(): right_dialog.open("goal")
	if turn_splash!=null: turn_splash.synchronize()
	if press_remaining > 0:
		press_remaining -= delta
		if press_remaining <= 0:
			art.pressed = ""
			art.queue_redraw()
			if pending_play_runner!=null: _finish_play_press()
	art.advance_hover(guest_pointer,is_visible_in_tree() and not intro_player.visible and not program_dialog.visible and not right_dialog.visible and not completion_dialog.visible and not construction.grab_active,delta)
	var point := guest_pointer
	var inside := is_visible_in_tree() and Rect2(0,0,640,400).has_point(point)
	if inside and not owns_cursor:
		previous_mouse_mode = Input.mouse_mode
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
		owns_cursor = true
	elif not inside and owns_cursor:
		Input.mouse_mode = previous_mouse_mode
		owns_cursor = false
	cursor.visible = inside and not intro_player.visible and pending_play_runner==null and (construction.play_backup == null or completion_dialog.visible)
	if cursor.visible:
		var index := cursor_index
		if not program_dialog.visible and not right_dialog.visible and not completion_dialog.visible and construction.play_backup==null:
			var control_index:=_control_cursor(point)
			if control_index>=0: index=control_index
		if construction.grab_active: index = 10 if construction.rope_editor.active() else (9 if construction.belt_editor.active() else 0)
		cursor.texture = cursor_frames[index]
		# TextureRect otherwise retains the largest previous cursor rectangle.
		cursor.size = cursor.texture.get_size()
		var hotspot: Array = art.layout.cursor_hotspots[index]
		cursor.position = point.floor()-Vector2(hotspot[0],hotspot[1])

func _control_cursor(point: Vector2) -> int:
	if construction.grab_active: return -1
	if match_bar!=null and match_bar.visible and match_bar.GONG_RECT.has_point(point): return 26
	if Rect2(3,8,52,74).has_point(point): return 13
	if Rect2(53,32,33,40).has_point(point): return 14
	match art.hover_key:
		"previous": return 15
		"next": return 16
		"home": return 18 if construction.is_editor() else 17
		"load": return 19
		"editor_save_arrow": return 20
		"save": return 21
		"goal": return 22
		"tunes": return 23
		"nuke": return 24
		"checklist": return 25
		"exit": return 26
	return -1

func _exit_tree() -> void:
	if owns_cursor: Input.mouse_mode = previous_mouse_mode

func _page(direction: int) -> void:
	if construction.play_backup != null or construction.grab_active: return
	var pages := maxi(1,ceili(float(_available().size())/PAGE_SIZE))
	page = posmod(page+direction,pages)
	_animate("previous" if direction < 0 else "next",3055 if direction < 0 else 3056)
	inventory_signature = ""
	_sync()

func _take(index: int) -> void:
	if construction.play_backup != null or construction.rope_editor.active() or construction.belt_editor.active(): return
	if external_match_controls:
		if not construction.can_take_inventory(index): return
		goal_pending=false
		right_dialog.close()
		construction.begin_turn()
	AudioEffects.play_sample(5) # Verified live at 2F9C:2F8D, priority=0, retrigger=0.
	if index<=-100: construction.take_type(-100-index)
	else: construction.take_native(index)

func pointer_inside_screen(event: InputEventMouse) -> bool:
	var point := screen.get_global_transform().affine_inverse() * event.position
	return Rect2(Vector2.ZERO, screen.size).has_point(point)

func _input(event: InputEvent) -> void:
	if is_visible_in_tree() and event is InputEventMouse:
		guest_pointer = screen.get_global_transform().affine_inverse() * event.position
	if pending_play_runner!=null and is_visible_in_tree():
		if not event is InputEventMouse or pointer_inside_screen(event):
			get_viewport().set_input_as_handled()
		return
	if right_dialog!=null and right_dialog.visible: return
	if completion_dialog!=null and completion_dialog.visible: return
	if is_visible_in_tree() and construction.cancel_input(event):
		get_viewport().set_input_as_handled()

func _available() -> Dictionary:
	var available: Dictionary = {}
	if construction.runner == null: return available
	if construction.is_editor():
		for type_id in art.layout.inventory_order: available[int(type_id)]=[-100-int(type_id)]
		return available
	for part in construction.runner.state.parts:
		if not construction.inventory_visible(part.index): continue
		if part.spawned or part.definition == null or part.placed: continue
		if construction.grab_active and part.index == construction.grab_index: continue
		if not available.has(part.part_type): available[part.part_type] = []
		available[part.part_type].append(part.index)
	return available

func _sync() -> void:
	if canvas == null or construction.runner == null: return
	var runner: SimulationRunner = construction.runner
	if canvas.puzzle != runner.puzzle:
		if intro_player != null: intro_player.finish(false)
		intro_pending = PortSettings.play_intro_videos and not construction.is_editor()
		goal_pending=PortSettings.show_goal_on_level_start and not construction.is_editor()
		canvas.set_puzzle(runner.puzzle)
		page = 0
		inventory_signature = ""
	canvas.set_runtime(runner.state)
	canvas.grab_active = construction.grab_active
	canvas.editing_enabled = construction.play_backup == null and pending_play_runner==null
	if external_match_controls:
		canvas.editing_enabled=canvas.editing_enabled and construction.active_match and not construction.awaiting_turn and not construction.round_complete
	status.text = construction.status
	var running: bool = construction.play_backup != null
	if external_match_controls:
		var turn_key:=str([runner.get_instance_id(),construction.player,construction.round_index])
		if turn_key!=match_turn_key:
			match_turn_key=turn_key
			match_timer_panel=true
		if not construction.solo: remote_open=not match_timer_panel
	play_button.disabled = running or construction.grab_active or pending_play_runner!=null
	remote_button.disabled = running or construction.grab_active or pending_play_runner!=null
	stop_button.disabled = not running or construction.is_completed()
	stop_button.visible = running and not construction.is_completed()
	if not external_match_controls: completion_dialog.synchronize()
	remote_controls.visible = remote_open and not running
	art.remote_open = remote_open
	art.running = running or pending_play_runner!=null
	art.editor_mode=construction.is_editor()
	art.head_to_head_mode=external_match_controls
	for button in editor_buttons: button.visible=construction.is_editor()
	home_button.tooltip_text="" # Native mode-specific caption is cursor 17/18.
	home_button.disabled=construction.grab_active
	if external_match_controls:
		play_button.disabled=play_button.disabled or not construction.active_match or construction.round_complete
		# Goal/Tunes remain available. Match setup and results live above the view.
		for button in remote_controls.get_children():
			if button is Button:
				button.visible=button.position.y in [0.0,144.0,191.0,348.0]
				button.disabled=not button.visible or construction.grab_active
		if match_bar!=null: match_bar.synchronize()
		if turn_splash!=null: turn_splash.synchronize()
	art.queue_redraw()
	var available := _available()
	var types := available.keys()
	var order: Array[int] = []
	order.assign(art.layout.inventory_order)
	types.sort_custom(func(a: int,b: int):
		var ai := order.find(a)
		var bi := order.find(b)
		return (ai if ai >= 0 else 100+a) < (bi if bi >= 0 else 100+b))
	page = mini(page,maxi(0,ceili(float(types.size())/PAGE_SIZE)-1))
	var locked: bool = running or construction.rope_editor.active() or construction.belt_editor.active()
	var signature := str(available)+str(locked)+str(page)
	if external_match_controls: signature+=str([construction.awaiting_turn,construction.round_complete,construction.turn_item,construction.turn_partner,construction.stage_item,construction.stage_partner])
	if signature == inventory_signature: return
	inventory_signature = signature
	for child in inventory.get_children():
		inventory.remove_child(child)
		child.queue_free()
	item_buttons.clear()
	inventory.visible = not running
	for slot in mini(PAGE_SIZE,types.size()-page*PAGE_SIZE):
		var type_id: int = types[page*PAGE_SIZE+slot]
		var ids: Array = available[type_id]
		var y := 94+49*slot
		var button := _button(inventory,Rect2(7,y,67,50),construction.type_names.get(type_id,"Part %d" % type_id),_take.bind(ids[0]))
		button.disabled = locked or (external_match_controls and not construction.can_take_inventory(ids[0]))
		button.set_meta("quantity",ids.size())
		button.mouse_entered.connect(func(): cursor_index = 2)
		if type_id >= 0 and type_id < inventory_icons.size():
			var icon := TextureRect.new()
			icon.texture = inventory_icons[type_id]
			icon.position = Vector2((66-icon.texture.get_width())/2.0,(49-icon.texture.get_height())/2.0)
			icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			button.add_child(icon)
		var count := TextureRect.new()
		count.texture = _count_texture(ids.size())
		count.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		count.position = Vector2(65-count.texture.get_width(),0)
		count.mouse_filter = Control.MOUSE_FILTER_IGNORE
		count.visible=not construction.is_editor()
		button.add_child(count)
		item_buttons[type_id] = button

func _count_texture(quantity: int) -> Texture2D:
	if count_cache.has(quantity): return count_cache[quantity]
	var glyphs: Array = []
	var width := 0
	for character in str(quantity):
		var glyph: Dictionary = count_font.get("glyphs",{}).get(character.unicode_at(0),{})
		if not glyph.is_empty():
			glyphs.append(glyph)
			width += int(glyph.width)
	var image := Image.create(maxi(1,width),int(count_font.get("height",1)),false,Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	var start := 0
	for glyph in glyphs:
		for y in int(glyph.height):
			for x in int(glyph.width):
				if glyph.pixels[y*int(glyph.width)+x] != 0: image.set_pixel(start+x,y,canvas.palette[1])
		start += int(glyph.width)
	count_cache[quantity] = ImageTexture.create_from_image(image)
	return count_cache[quantity]
