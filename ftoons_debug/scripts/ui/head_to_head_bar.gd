extends Control
## MPC segment 30:2DFA/2EDB; pixel coordinates include the left inventory bar.
const GONG_RECT:=Rect2(593,348,47,45)
var view: Control
var parts: Array[Texture2D]=[]
var digits: Array[Texture2D]=[]
var gong: Button
var blocked_area: Control
var last_signature: String=""
var struck:=false

func _init(owner_view: Control) -> void:
	view=owner_view
	mouse_filter=Control.MOUSE_FILTER_IGNORE
	texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
	size=Vector2(640,400)
	clip_contents=true

func _ready() -> void:
	parts=view.sprite_graphics.windows_ui_frames("H2HPTS1.BMP")
	digits=view.sprite_graphics.windows_ui_frames("H2HPTS2.BMP")
	blocked_area=Control.new()
	blocked_area.position=Vector2(590,0)
	blocked_area.size=Vector2(50,400)
	blocked_area.mouse_filter=Control.MOUSE_FILTER_STOP
	add_child(blocked_area)
	gong=view._button(self,GONG_RECT,"End turn — ring the gong",ring)
	gong.button_down.connect(func(): struck=true; queue_redraw())
	gong.button_up.connect(func(): struck=false; queue_redraw())
	synchronize()

func ring() -> void:
	var c=view.construction
	if not c.active_match or c.solo or c.awaiting_turn or c.round_complete or c.play_backup!=null: return
	view.program_dialog.close()
	AudioEffects.play_sample(4033)
	c.end_turn()

func synchronize() -> void:
	if gong==null: return
	var c=view.construction
	visible=view.match_timer_panel and c.active_match and not c.solo and c.play_backup==null and view.pending_play_runner==null and not c.round_complete
	gong.disabled=c.awaiting_turn or c.round_complete or not c.active_match
	var signature:=str([ceili(c.remaining),c.player,struck,visible])
	if signature!=last_signature:
		last_signature=signature
		queue_redraw()

func _process(_delta: float) -> void:
	if is_visible_in_tree(): synchronize()

func _sprite(frames: Array[Texture2D], index: int, point: Vector2) -> void:
	if index<frames.size() and frames[index]!=null: draw_texture(frames[index],point)

func _draw() -> void:
	if parts.size()<32 or digits.size()<15:
		draw_rect(Rect2(590,0,50,400),Color("442244"))
		return
	var c=view.construction
	_sprite(digits,4,Vector2(592,0))
	# Native fill operation removes the old player portrait before redrawing.
	# 30:0031 -> 2:2255 maps logical colour 12 to CLU entry 48 (case +30h).
	draw_rect(Rect2(600,58,36,68),view.sprite_graphics._windows_palette[48])
	_sprite(parts,3 if c.player==0 else 2,Vector2(590 if c.player==0 else 592,15))
	_sprite(parts,30,Vector2(594,193))
	_sprite(parts,31,Vector2(594,281))
	var seconds:=clampi(ceili(c.remaining),0,599)
	_sprite(digits,5+seconds/60,Vector2(620,163))
	_sprite(digits,5+(seconds%60)/10,Vector2(599,250))
	_sprite(digits,5+seconds%10,Vector2(619,250))
	_sprite(parts,5 if struck else 6,Vector2(595,330))
