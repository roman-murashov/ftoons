extends Control
## Presentation-only MPC entrance, lip-synced dialogue, and exit.
signal finished
const Library = preload("res://scripts/graphics/windows_intro_library.gd")
var library := Library.new()
var host: Control
var owner_runner: SimulationRunner
var sequence: Array[Dictionary] = []
var stage := -1
var elapsed := 0.0
var last_tick := -1
var base: Image
var composed: Image
var texture: ImageTexture
var voice: AudioStreamPlayer
var error := ""

func _init(game: Control) -> void:
	host = game
	size = Vector2(640,400)
	mouse_filter = Control.MOUSE_FILTER_STOP
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	visible = false
	voice = AudioStreamPlayer.new()
	if OS.has_feature("web"): voice.playback_type=AudioServer.PLAYBACK_TYPE_STREAM
	add_child(voice)

func begin(level: String) -> bool:
	finish(false)
	error = ""
	sequence = library.timeline(level)
	if sequence.is_empty():
		error = library.error
		return false
	owner_runner = host.construction.runner
	base = _blank()
	composed = base.duplicate()
	visible = true
	stage = -1
	_next_stage()
	return true

func _blank() -> Image:
	var image := Image.create(640,400,false,Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	return image

func _next_stage() -> void:
	voice.stop()
	stage += 1
	if stage >= sequence.size():
		finish()
		return
	# The native exit restores the screen captured before the entrance.
	base = _blank() if sequence[stage].kind == "exit" else composed.duplicate()
	composed = base.duplicate()
	elapsed = 0.0
	last_tick = -1
	voice.stream = sequence[stage].audio
	if host.get_node("/root/AudioEffects").effects_enabled:
		voice.volume_db = host.get_node("/root/AudioEffects").effects_volume_db
		voice.play()
	_render(0)

func _render(tick: int) -> void:
	var item: Dictionary = sequence[stage]
	var sampled := (mini(tick,int(item.duration)-1)/maxi(1,int(item.step)))*maxi(1,int(item.step))
	if sampled == last_tick: return
	var next := 0 if last_tick < 0 else last_tick + maxi(1,int(item.step))
	while next <= sampled:
		composed = library.compose(item,next,composed,maxi(0,last_tick))
		last_tick = next
		next += maxi(1,int(item.step))
	if texture == null: texture = ImageTexture.create_from_image(composed)
	else: texture.update(composed)
	queue_redraw()

func _process(delta: float) -> void:
	if not visible: return
	if owner_runner != host.construction.runner or host.construction.play_backup != null or host.construction.is_editor():
		finish()
		return
	voice.stream_paused = not host.is_visible_in_tree()
	if voice.stream_paused: return
	advance(delta)

func advance(delta: float) -> void:
	if not visible: return
	elapsed += maxf(0,delta)*600.0
	while visible and elapsed >= float(sequence[stage].duration):
		var remaining := elapsed-float(sequence[stage].duration)
		_render(int(sequence[stage].duration)-1)
		_next_stage()
		elapsed = remaining
	if visible: _render(int(elapsed))

func finish(emit_signal: bool = true) -> void:
	var was_visible := visible
	visible = false
	voice.stop()
	voice.stream = null
	voice.stream_paused = false
	owner_runner = null
	sequence.clear()
	stage = -1
	if emit_signal and was_visible: finished.emit()

func _input(event: InputEvent) -> void:
	if not is_visible_in_tree(): return
	if event is InputEventMouse:
		if not host.pointer_inside_screen(event): return
		get_viewport().set_input_as_handled()
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed: finish()
	elif event is InputEventKey:
		get_viewport().set_input_as_handled()
		if event.pressed and not event.echo and event.keycode in [KEY_ESCAPE,KEY_SPACE,KEY_ENTER]: finish()

func _draw() -> void:
	# Same blue screen-door shade as Goal: game below, intro actors above.
	draw_texture(host.program_dialog.shade,Vector2.ZERO)
	if texture != null: draw_texture(texture,Vector2.ZERO)

func _exit_tree() -> void:
	voice.stop()
