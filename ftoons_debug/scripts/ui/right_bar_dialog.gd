extends "res://scripts/ui/dos_inventory_art.gd"
## Original right-bar modal art and guest-coordinate input.
signal exit_requested
var host: Control
var owner_runner: SimulationRunner
var kind := ""
var pending := ""
var confirm_frame := -1
var confirm_elapsed := 0.0
var confirm_drawn := false
var elapsed := 0.0
var font: Dictionary
var text_cache := {}
var buttons := {}
var tunes: Control
var piggy: Control
var tunes_close_pending:=false
var editor_form: Control
var level_wipe:=preload("res://scripts/ui/dos_wipe.gd").new()
var wiping:=false
const GOAL_FRAME_SECONDS := 12.0*5041.0/1193182.0

func goal_animation_cases() -> Array[int]:
	# 6606:0070 increments an eight-bit phase, draws alternating camera feet
	# and six wheel poses, then0110..0119 waits12 timer counts. The first
	# presented loop uses phase1; the byte wrap also restarts the wheel cycle.
	var phase: int=(1+int(elapsed/GOAL_FRAME_SECONDS))&255
	return [3+phase%2,5+phase%6,11+phase%2]

func _init(game: Control) -> void:
	host=game
	super(game.catalog, game.sprite_graphics)
	layout=JSON.parse_string(FileAccess.get_file_as_string("res://assets/original/dos_right_dialogs.json"))
	_load_sheets(layout.tables.values())
	font=Formats.decode_font(host.catalog.read_asset("SSD14_22.FNT"))
	size=Vector2(640,400)
	mouse_filter=Control.MOUSE_FILTER_STOP
	visible=false
	tunes=preload("res://scripts/ui/tunes_dialog.gd").new(game.catalog, sprite_graphics)
	tunes.construction=host.construction
	add_child(tunes)
	piggy=preload("res://scripts/ui/piggy_dialog.gd").new(self)
	add_child(piggy)
	editor_form=preload("res://scripts/ui/home_toons_dialog.gd").new(self)
	add_child(editor_form)

func open(action: String) -> void:
	if host.construction.runner==null or host.construction.play_backup!=null or host.construction.grab_active: return
	wiping=action=="goal" and host.construction.level_wipe_variant>=0
	if wiping:
		level_wipe.begin(host.construction.level_wipe_variant)
		host.construction.level_wipe_variant=-1
	tunes_close_pending=false
	owner_runner=host.construction.runner
	confirm_frame=-1
	kind=action
	pending=""
	elapsed=0
	editor_form.visible=false
	piggy.visible=false
	buttons={}
	if kind.begins_with("editor_"):
		if not host.construction.is_editor() and kind!="editor_load": return
		editor_form.begin(kind)
		visible=true
		queue_redraw()
		return
	match kind:
		"exit": buttons={"accept":Rect2(240,237,91,35),"cancel":Rect2(363,146,122,99)}
		"nuke": buttons={"accept":Rect2(271,145,70,51),"cancel":Rect2(218,226,85,62)}
		"load": piggy.begin()
		"tunes":
			buttons=tunes.BUTTONS
			tunes.begin()
		"goal": buttons={"close":Rect2(140,0,379,146),"camera":Rect2(160,332,69,50)}
		_: return
	visible=true
	queue_redraw()

func close() -> void:
	tunes_close_pending=false
	tunes.held_action=""
	wiping=false
	editor_form.visible=false
	if kind=="load": piggy.visible=false
	if kind=="tunes":
		tunes.finish()
		if host.construction.is_editor(): host.construction.runner.puzzle.music=MusicPlayer.current_song_id
	visible=false
	confirm_frame=-1
	pending=""

func _process(delta: float) -> void:
	if not visible: return
	if host.construction.runner!=owner_runner or not host.is_visible_in_tree() or host.construction.play_backup!=null:
		close()
		return
	if wiping:
		delta=level_wipe.advance(delta)
		queue_redraw()
		if not level_wipe.finished(): return
		wiping=false
	if confirm_frame>=0:
		confirm_elapsed+=delta
		# 676B:00E6..013E presents cases 5..9, then calls 1000:5D06.
		# Keep every recovered frame visible even at a low render frame rate.
		if confirm_drawn and confirm_elapsed>=1.0/60.0:
			confirm_elapsed=0.0
			confirm_drawn=false
			confirm_frame+=1
			if confirm_frame>9:
				host.construction.nuke()
				close()
				return
	host.cursor_index=0
	if kind=="load": piggy.advance(delta)
	if kind=="editor_save": piggy.advance(delta)
	if kind=="tunes":
		tunes.advance(delta)
		if tunes_close_pending and not tunes.busy():
			close()
			return
		if pending in ["previous","next","up","down"] and not tunes.busy():
			tunes.activate(pending,pending in ["previous","next"])
			tunes.advance(0.0)
	elapsed+=delta
	queue_redraw()

func _input(event: InputEvent) -> void:
	if not visible or not host.is_visible_in_tree(): return
	if event is InputEventMouse and not host.pointer_inside_screen(event):
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			pending = ""
			tunes.held_action = ""
		return
	if wiping:
		get_viewport().set_input_as_handled()
		return
	if kind=="tunes" and tunes.busy():
		# Input release still updates the held-button latch while the original
		# synchronous routine is busy. Dropping it would repeat forever.
		if event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT and not event.pressed:
			pending=""
			tunes.held_action=""
		get_viewport().set_input_as_handled()
		return
	if editor_form.visible: return # Let LineEdit/TextEdit receive physical keyboard input.
	if event is InputEventMouse:
		host.guest_pointer=host.screen.get_global_transform().affine_inverse()*event.position
		if kind=="tunes":
			if event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT:
				pending=""
				if event.pressed:
					for action in buttons:
						if not buttons[action].has_point(host.guest_pointer): continue
						tunes.held_action=action
						tunes_close_pending=action=="close"
						if action in ["previous","next","up","down"]: pending=action
						tunes.activate(action)
						break
				else: tunes.held_action=""
			get_viewport().set_input_as_handled()
			return
		if confirm_frame<0 and event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT:
			if event.pressed:
				for action in buttons:
					if buttons[action].has_point(host.guest_pointer): pending=action; break
			elif pending!="":
				var action:=pending
				pending=""
				if kind=="load":
					piggy.activate(action)
					get_viewport().set_input_as_handled()
					return
				# Calls to original sample player in overlays 64CD/6606/676B.
				if kind=="exit": AudioEffects.play_sample(1 if action=="accept" else 3052)
				elif kind=="nuke": AudioEffects.play_sample(3117 if action=="accept" else 3102)
				elif kind=="goal": AudioEffects.play_sample(3036)
				if action=="accept":
					if kind=="nuke":
						confirm_frame=5
						confirm_elapsed=0.0
						confirm_drawn=false
						queue_redraw()
					else: exit_requested.emit()
				if confirm_frame<0: close()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey:
		get_viewport().set_input_as_handled()

func text_image(text: String, color: int) -> Texture2D:
	var key:=str(color)+text
	if text_cache.has(key): return text_cache[key]
	var width:=text_width(text)
	var image:=Image.create(maxi(width+2,2),int(font.height)+2,false,Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	for outline in [true,false]:
		var x:=1
		for ch in text:
			var glyph: Dictionary=font.glyphs.get(ch.unicode_at(0),font.glyphs[32])
			for y in int(glyph.height):
				for col in int(glyph.width):
					if glyph.pixels[y*int(glyph.width)+col]==0: continue
					if outline:
						for off in [Vector2i.LEFT,Vector2i.RIGHT,Vector2i.UP,Vector2i.DOWN]: image.set_pixel(x+col+off.x,y+1+off.y,palette[0])
					else: image.set_pixel(x+col,y+1,palette[color])
			x+=int(glyph.width)
	text_cache[key]=ImageTexture.create_from_image(image)
	return text_cache[key]

func text_width(text: String) -> int:
	var width:=0
	for ch in text: width+=int(font.glyphs.get(ch.unicode_at(0),font.glyphs[32]).width)
	return width

func paragraph(text: String, origin: Vector2, width: int, color: int) -> void:
	var y:=origin.y
	for para in text.replace("\r","").split("\n"):
		var line:=""
		for word in para.split(" "):
			var trial:=word if line.is_empty() else line+" "+word
			if text_width(trial)>width and not line.is_empty():
				draw_texture(text_image(line,color),Vector2(origin.x-1,y-1))
				y+=font.height
				line=word
			else: line=trial
		draw_texture(text_image(line,color),Vector2(origin.x-1,y-1))
		y+=font.height

func _draw() -> void:
	if not visible: return
	if wiping:
		for box in level_wipe.visible_rectangles():
			draw_texture_rect_region(host.program_dialog.shade,Rect2(box),Rect2(box))
		return
	draw_texture(host.program_dialog.shade,Vector2.ZERO)
	match kind:
		"exit":
			commands("exit_0")
			commands("exit_1")
			commands("exit_2" if int(elapsed*5)%2==0 else "exit_3")
			for lamp in layout.exit_lamps:
				var center:=Vector2(lamp[0],lamp[1])
				draw_circle(center,lamp[2],palette[14 if int(elapsed*5)%2 else 13])
				draw_circle(center,lamp[2],palette[13 if int(elapsed*5)%2 else 7],false,1.0)
			if pending=="accept": commands("exit_6")
		"nuke":
			for index in [0,1,3 if pending=="cancel" else 2,confirm_frame if confirm_frame>=0 else 4]: commands("nuke_%d"%index)
			if confirm_frame>=0: confirm_drawn=true
		"goal","editor_goal":
			commands("goal_0")
			commands("goal_1")
			commands("goal_18" if owner_runner.puzzle.construction_context=="home_toons" else "goal_14")
			for frame in goal_animation_cases(): commands("goal_%d"%frame,Vector2(5,-5))
			if kind=="goal":
				paragraph(owner_runner.puzzle.title,Vector2(238,192),263,14)
				paragraph(owner_runner.puzzle.instructions,Vector2(252,232),249,10)

