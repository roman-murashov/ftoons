extends "res://scripts/ui/dos_inventory_art.gd"
## All seven original 754B programming variants.
var host: Control
var part_index := -1
var owner_runner: SimulationRunner
var fonts: Dictionary = {}
var text_cache: Dictionary = {}
var shade: Texture2D
var pressed_action := ""
var press_time := 0.0
var buttons := {"up":Rect2(367,109,42,57),"down":Rect2(370,171,34,46),"confirm":Rect2(248,185,95,41)}

func _init(game: Control) -> void:
	host=game
	super(game.catalog, game.sprite_graphics)
	layout=JSON.parse_string(FileAccess.get_file_as_string("res://assets/original/dos_gadget_programming.json"))
	_load_sheets(layout.tables.values())
	for name in ["SSD14_38.FNT","SSD14_44.FNT"]:
		fonts[name]=Formats.decode_font(host.catalog.read_asset(name))
	var image:=Image.create(640,400,false,Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	# 1DBF:0009 applies alternating AA/55 pixel masks, setting color15.
	for y in 400:
		for x in 640:
			if (x+y)%2==0: image.set_pixel(x,y,palette[15])
	shade=ImageTexture.create_from_image(image)
	size=Vector2(640,400)
	mouse_filter=Control.MOUSE_FILTER_STOP
	visible=false

func open(index: int) -> void:
	var c: RefCounted=host.construction
	if not c.can_program(index): return
	part_index=index
	owner_runner=c.runner
	visible=true
	pressed_action=""
	queue_redraw()

func close() -> void:
	visible=false
	part_index=-1
	pressed_action=""

func _process(delta: float) -> void:
	if not visible: return
	if owner_runner!=host.construction.runner or not host.is_visible_in_tree() or host.construction.play_backup!=null:
		close()
		return
	host.cursor_index=0
	if press_time>0:
		press_time-=delta
		if press_time<=0:
			if pressed_action=="confirm": close()
			pressed_action=""
			queue_redraw()

func _input(event: InputEvent) -> void:
	if not visible or not host.is_visible_in_tree(): return
	if event is InputEventMouse and not host.pointer_inside_screen(event): return
	if event is InputEventMouse:
		host.guest_pointer=host.screen.get_global_transform().affine_inverse()*event.position
		if event is InputEventMouseButton and event.pressed and event.button_index==MOUSE_BUTTON_LEFT and pressed_action!="confirm":
			for action in buttons:
				if buttons[action].has_point(host.guest_pointer):
					pressed_action=action
					press_time=0.12
					if action!="confirm":
						var c: RefCounted=host.construction
						c.adjust_program(part_index,1 if action=="up" else -1)
					queue_redraw()
					break
		get_viewport().set_input_as_handled()
	elif event is InputEventKey:
		get_viewport().set_input_as_handled()

func text_texture(text: String, font_name: String) -> Texture2D:
	var key:=font_name+text
	if text_cache.has(key): return text_cache[key]
	var font: Dictionary=fonts[font_name]
	var width:=0
	for character in text: width+=int(font.glyphs[character.unicode_at(0)].width)
	var image:=Image.create(width+2,int(font.height)+2,false,Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	var start:=1
	for character in text:
		var glyph: Dictionary=font.glyphs[character.unicode_at(0)]
		for y in int(glyph.height):
			for x in int(glyph.width):
				if glyph.pixels[y*int(glyph.width)+x]==0: continue
				for offset in [Vector2i.LEFT,Vector2i.RIGHT,Vector2i.UP,Vector2i.DOWN]:
					image.set_pixel(start+x+offset.x,1+y+offset.y,palette[0])
		start+=int(glyph.width)
	start=1
	for character in text:
		var glyph: Dictionary=font.glyphs[character.unicode_at(0)]
		for y in int(glyph.height):
			for x in int(glyph.width):
				if glyph.pixels[y*int(glyph.width)+x]!=0: image.set_pixel(start+x,1+y,palette[4])
		start+=int(glyph.width)
	text_cache[key]=ImageTexture.create_from_image(image)
	return text_cache[key]

func _draw() -> void:
	if part_index<0: return
	draw_texture(shade,Vector2.ZERO)
	for index in [0,2 if pressed_action=="up" else 1,4 if pressed_action=="down" else 3,5,7 if pressed_action=="confirm" else 6]:
		# Reuse the original draw-list renderer with the recovered overlay blocks.
		layout[str(index)]=layout.commands[str(index)]
		commands(str(index))
	var part:=owner_runner.state.parts[part_index]
	var metadata: Dictionary=layout.types[str(part.part_type)]
	draw_texture(text_texture(metadata.label,"SSD14_38.FNT"),Vector2(metadata.xy[0]-1,metadata.xy[1]-1))
	if part.part_type==59:
		var key:="13" if part.settings!=0 else "14"
		layout[key]=layout.commands[key]
		commands(key)
		return
	var text:=str(part.settings&255) if part.part_type==39 else str(part.settings)
	if part.part_type==42:
		if (part.settings&255)==0: return
		text=String.chr(part.settings&255)
	var number:=text_texture(text,"SSD14_44.FNT")
	var extent:=number.get_size()-Vector2(2,2)
	draw_texture(number,Vector2(262,119)+((Vector2(93,58)-extent)/2).floor()-Vector2.ONE)
