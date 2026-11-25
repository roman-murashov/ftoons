extends "res://scripts/ui/dos_inventory_art.gd"
## Additional original progress requesters, password picture and scripted finale.
const Finale=preload("res://scripts/ui/dos_finale.gd")
const PIT_SECONDS:=5041.0/1193182.0
var host: Control
var stage:=""
var finale: RefCounted
var background: Texture2D
var font: Dictionary
var picture_font: Dictionary
var bonus_font: Dictionary
var text_cache: Dictionary={}
var remaining_tiles:=-1
var elapsed:=0.0
var delay_left:=0.0
var password:=""
var editing:=false
var error:=""

func _init(game: Control) -> void:
	host=game
	super(game.catalog, game.sprite_graphics)
	layout=JSON.parse_string(FileAccess.get_file_as_string("res://assets/original/dos_campaign_presentations.json"))
	layout.tables["generic"]="GENREQES.BMP"
	_load_sheets(layout.tables.values())
	font=Formats.decode_font(host.catalog.read_asset("TUXEDO.FNT"))
	picture_font=Formats.decode_font(host.catalog.read_asset("SSD14_22.FNT"))
	bonus_font=Formats.decode_font(host.catalog.read_asset("SSD14_38.FNT"))
	background=ImageTexture.create_from_image(Formats.scr_to_image(Formats.decode_scr(host.catalog.read_asset("PUZZLE.SCR")),palette))
	finale=Finale.new(host.catalog)
	size=Vector2(640,400);mouse_filter=Control.MOUSE_FILTER_STOP;visible=false

func begin(presentation: Dictionary) -> void:
	var branch:=int(presentation.get("branch",0))
	stage="";error="";elapsed=0;delay_left=0;password="";editing=false
	remaining_tiles=int(presentation.get("remaining_tiles",-1))
	if branch==2: stage="unlock"
	elif branch==3: stage="picture";editing=remaining_tiles==0
	elif branch==4:
		if finale.begin(): stage="finale"
		else: error=finale.error;push_error(error)
	visible=not stage.is_empty()
	queue_redraw()

func advance(delta: float) -> float:
	if stage.is_empty(): return delta
	if stage=="finale":
		delta=finale.advance(delta)
		if finale.finished: stage="border";elapsed=0
		else: queue_redraw();return 0.0
	if stage=="border":
		var used:=minf(delta,240.0*PIT_SECONDS-elapsed)
		elapsed+=used;delta-=used
		if elapsed>=240.0*PIT_SECONDS: finish()
	elif stage=="unlock_hold" or stage=="bonus_hold":
		var used:=minf(delta,delay_left)
		delay_left-=used;delta-=used
		if delay_left<=0:
			finish()
	else: elapsed+=delta;delta=0
	queue_redraw()
	return delta if stage.is_empty() else 0.0

func finish() -> void:
	stage="";visible=false
	# 769D cleanup stops effects; finale's caller performs the following wipe.
	AudioEffects.stop_all_effects()

func receive_input(event: InputEvent) -> void:
	if stage.is_empty(): return
	if event is InputEventKey and event.pressed and not event.echo:
		if stage in ["finale","border"]: stage="border";elapsed=240.0*PIT_SECONDS;advance(0)
		elif stage=="picture":
			if editing:
				if event.keycode==KEY_ENTER or event.keycode==KEY_KP_ENTER:
					editing=false
					if password.to_upper()=="WIND":
						host.construction.campaign_progress.unlock_bonus()
						AudioEffects.play_sample(17);stage="bonus"
					else: AudioEffects.play_sample(2)
				elif event.keycode==KEY_ESCAPE: editing=false
				elif event.keycode==KEY_BACKSPACE: password=password.left(maxi(0,password.length()-1))
				elif event.unicode>=32 and event.unicode<127 and password.length()<10: password+=String.chr(event.unicode)
			else: finish()
	elif event is InputEventMouseButton and not event.pressed and event.button_index==MOUSE_BUTTON_LEFT:
		var point: Vector2=host.guest_pointer
		if stage in ["finale","border"]: stage="border";elapsed=240.0*PIT_SECONDS;advance(0)
		elif stage in ["unlock","bonus"]:
			var box:=Rect2(155,270,365,40) if stage=="unlock" else Rect2(210,290,280,40)
			if box.has_point(point):
				AudioEffects.play_sample(2)
				stage="unlock_hold" if stage=="unlock" else "bonus_hold"
				delay_left=60.0*PIT_SECONDS
		elif stage=="picture":
			if remaining_tiles>=0 and Rect2(429,348,111,21).has_point(point):
				editing=true;AudioEffects.play_sample(3018)
			else: AudioEffects.play_sample(2);delay_left=24*PIT_SECONDS;finish()
	queue_redraw()

func _text(message: String,color: int=4) -> Texture2D:
	var active_font: Dictionary=picture_font if stage=="picture" else (bonus_font if stage.begins_with("bonus") else font)
	var key:=stage+str(color)+message
	if text_cache.has(key): return text_cache[key]
	var width:=1
	for ch in message: width+=int(active_font.glyphs.get(ch.unicode_at(0),active_font.glyphs[32]).width)
	var image:=Image.create(maxi(1,width+1),int(active_font.height)+2,false,Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	var x:=0
	for ch in message:
		var glyph: Dictionary=active_font.glyphs.get(ch.unicode_at(0),active_font.glyphs[32])
		for y in int(glyph.height):
			for col in int(glyph.width):
				if glyph.pixels[y*int(glyph.width)+col]: image.set_pixel(x+col,y,palette[color])
		x+=int(glyph.width)
	text_cache[key]=ImageTexture.create_from_image(image)
	return text_cache[key]

func _center(message: String,y: int,color: int=4) -> void:
	var texture:=_text(message,color)
	draw_texture(texture,Vector2((640-texture.get_width())/2,y))

func _case(index: int) -> void:
	layout[str(index)]=layout.commands[str(index)]
	commands(str(index))

func _request_commands(key: String) -> void:
	for command in layout.get(key,[]):
		if command.kind=="text": draw_texture(_text(command.text,int(command.color)),Vector2(command.xy[0],command.xy[1]))
		else: layout["generic_command"]=[command];commands("generic_command")

func _draw() -> void:
	if not visible: return
	if stage in ["finale","border"]:
		if finale.frame==0: return
		draw_texture(finale.texture,Vector2.ZERO)
		if stage=="border":
			var fraction:=clampf(elapsed/(240.0*PIT_SECONDS),0,1)
			var x:=int(320*fraction);var y:=int(200*fraction)
			for box in [Rect2(0,0,640,y),Rect2(0,400-y,640,y),Rect2(0,y,x,400-2*y),Rect2(640-x,y,x,400-2*y)]: draw_rect(box,palette[0])
	elif stage=="picture":
		draw_texture(background,Vector2.ZERO)
		var order: Array=layout.tile_order
		for i in maxi(0,remaining_tiles):
			var tile:=int(order[i]);var col:=tile%17;var row:=tile/17
			var parity: int=(col^row)&1
			var x: int=(col/2)*80+(col&1)*43-24-(row&~1)
			if row&1: x+=2 if parity else -4
			var y: int=(row/2)*72+(row&1)*25-20
			if col&1: y+=-11 if parity else 11
			draw_texture(sheets["PUZZLE.BMP"][parity],Vector2(x,y))
		if remaining_tiles>0: _case(0)
		if remaining_tiles>=0:
			_case(2)
			draw_texture(_text(layout.password_label),Vector2(397,319))
			draw_texture(_text(password+("_" if editing else "")),Vector2(429,348))
		if remaining_tiles==0: _case(1 if int(elapsed*60)%20<13 else 3)
	else:
		var command_key:="bonus_commands" if stage.begins_with("bonus") else "unlock_commands"
		if layout.has(command_key):
			_request_commands(command_key)
			if stage.ends_with("_hold"): _request_commands(command_key+"_pressed")
			return
		# Resource-derived geometry/text. The generic requester is a separate
		# synchronous screen; it must never leave reward buttons interactive.
		var bonus:=stage.begins_with("bonus")
		var box:=Rect2(180,100,350,251) if bonus else Rect2(140,100,410,251)
		draw_rect(box.grow(4),palette[4]);draw_rect(box,palette[15])
		_center("Congratulations,",128)
		_center("You have unlocked all" if bonus else "You have unlocked several",160)
		_center("the bonus puzzles!" if bonus else "more puzzles.",184)
		var button:=Rect2(210,290,280,40) if bonus else Rect2(155,270,365,40)
		draw_rect(button,palette[14] if bonus else palette[10])
		_center("Am I amazing or what?!?" if bonus else "Sometimes I really impress myself.",int(button.position.y)+8)
