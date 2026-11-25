extends Control
## MPC 30:3C63: centered player sign, alternating TURN, click/10s dismissal.
const DURATION:=10.0
const FLASH_SECONDS:=0.2
var host: Control
var frames: Array[Texture2D]=[]
var elapsed:=0.0
var turn_frame:=0
var session_key: String=""
var release_pending:=false
var name_label: Label

func _init(view: Control) -> void:
	host=view
	size=Vector2(640,400)
	clip_contents=true
	mouse_filter=Control.MOUSE_FILTER_STOP
	texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
	visible=false

func _ready() -> void:
	frames=host.sprite_graphics.windows_ui_frames("H2HTURN.BMP")
	name_label=Label.new()
	name_label.mouse_filter=Control.MOUSE_FILTER_IGNORE
	name_label.clip_text=true
	name_label.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	name_label.vertical_alignment=VERTICAL_ALIGNMENT_TOP
	var font:=SystemFont.new()
	font.font_names=PackedStringArray(["Arial","Liberation Sans","sans-serif"])
	font.font_weight=700
	font.antialiasing=TextServer.FONT_ANTIALIASING_NONE
	name_label.add_theme_font_override("font",font)
	name_label.add_theme_font_size_override("font_size",32)
	name_label.add_theme_color_override("font_color",Color.BLACK)
	add_child(name_label)

func waiting() -> bool:
	var c=host.construction
	return c.active_match and not c.solo and c.awaiting_turn and not c.round_complete

func synchronize() -> void:
	if name_label==null: return
	var c=host.construction
	var key:=str([c.runner.get_instance_id() if c.runner!=null else 0,c.player,c.round_index])
	if key!=session_key:
		session_key=key
		elapsed=0
		turn_frame=0
		release_pending=false
	visible=waiting() and not host.goal_pending and not host.right_dialog.visible and not host.intro_player.visible
	if not waiting():
		elapsed=0
		release_pending=false
	if visible:
		var sid: bool=c.player==0
		name_label.position=Vector2(229,122) if sid else Vector2(258,93)
		name_label.size=Vector2(160,37) if sid else Vector2(133,36)
		name_label.text=c.player_names[c.player]+"'s"
		queue_redraw()

func advance(delta: float) -> void:
	synchronize()
	if not is_visible_in_tree(): return
	elapsed+=maxf(0,delta)
	turn_frame=int(elapsed/FLASH_SECONDS)%2
	queue_redraw()
	if elapsed>=DURATION and not release_pending: dismiss()

func dismiss() -> void:
	if not waiting(): return
	visible=false
	release_pending=false
	host.construction.begin_turn()

func _input(event: InputEvent) -> void:
	if not is_visible_in_tree(): return
	if event is InputEventMouse:
		host.guest_pointer=host.screen.get_global_transform().affine_inverse()*event.position
		# Consume both halves of the dismissal click, even when released outside.
		if not release_pending and not host.pointer_inside_screen(event): return
		get_viewport().set_input_as_handled()
		if event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT:
			if event.pressed: release_pending=true
			elif release_pending: dismiss()
	elif event is InputEventKey:
		get_viewport().set_input_as_handled()

func _draw() -> void:
	if frames.size()<4: return
	var sid: bool=host.construction.player==0
	draw_texture(frames[3 if sid else 2],Vector2(195,105) if sid else Vector2(193,78))
	draw_texture(frames[turn_frame],Vector2(241,164) if sid else Vector2(274,136))
