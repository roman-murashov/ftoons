extends "res://scripts/ui/dos_inventory_art.gd"
## Campaign success presentation. Predicates, progression and replay live in controls.
var host: Control
var owner_state: SimulationState
var font: Dictionary
var text_cache: Dictionary={}
var shade: Texture2D
var variants: Array=[]
var phases: Array[int]=[0,0]
var delays: Array[int]=[0,0]
var buttons: Dictionary={}
var elapsed:=0.0
var clock_accumulator:=0.0
var next_interval:=0.0
var ready_for_input:=false
var pending:=""
var exit_steps:=0
var group_text:=""
var title_text:=""
var date_text:=""
var wipe:=preload("res://scripts/ui/dos_wipe.gd").new()
var entrance_started:=false
var setup_finished:=false
var setup_remaining:=0.0
var timing_profile: Dictionary={}
var interlude: Control
var interlude_started:=false
var interlude_wiping:=false
# 1EA3:3F8A programs PIT channel0 with65535/13=5041. Its IRQ handler
# decrements DS:34BF on every interrupt (1EA3:403E). Both retained CAKE11
# completion and Home Toons snapshots confirm divisor5041 and multiplier13.
# These intervals follow that timer; rendering/OS scheduling may quantize them.
const PIT_HZ:=1193182.0
const TIMER_SECONDS:=5041.0/PIT_HZ
const FRAME_SECONDS:=12.0*TIMER_SECONDS
const INITIAL_SECONDS:=240.0*TIMER_SECONDS

func _init(game: Control) -> void:
	host=game
	super(game.catalog, game.sprite_graphics)
	layout=JSON.parse_string(FileAccess.get_file_as_string("res://assets/original/dos_completion_ui.json"))
	timing_profile=JSON.parse_string(FileAccess.get_file_as_string("res://assets/original/dos_reward_timing.json"))
	_load_sheets(["REWARD01.BMP", "REWSIGNS.BMP", "HAND.BMP", "WORM.BMP", "GOPHER.BMP", "MOLE.BMP"])
	font=Formats.decode_font(game.catalog.read_asset(layout.font))
	# Original full-screen transition applies the AA/55 checker mask, color15.
	var image:=Image.create(640,400,false,Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	for y in 400:
		for x in 640:
			if (x+y)%2==0: image.set_pixel(x,y,palette[15])
	shade=ImageTexture.create_from_image(image)
	size=Vector2(640,400)
	mouse_filter=Control.MOUSE_FILTER_STOP
	visible=false
	interlude=preload("res://scripts/ui/campaign_interlude.gd").new(game)
	add_child(interlude)

func synchronize() -> void:
	if not host.construction.is_completed():
		visible=false
		owner_state=null
		return
	if owner_state==host.construction.runner.state: return
	owner_state=host.construction.runner.state
	visible=true
	elapsed=0.0
	clock_accumulator=0.0
	next_interval=INITIAL_SECONDS
	ready_for_input=false
	pending=""
	exit_steps=0
	entrance_started=false
	setup_finished=false
	setup_remaining=0.0
	interlude_started=false
	interlude_wiping=false
	interlude.stage="";interlude.visible=false
	wipe.begin(host.construction.completion_wipe_variant())
	var decoration:=owner_state.completion_decoration()
	variants=[layout.variants[int(decoration.variants[0])],layout.variants[int(decoration.variants[1])]]
	layout.tables["0x45ec"]=variants[0].resource
	layout.tables["0x45e4"]=variants[1].resource
	phases=[0,0]
	delays.assign(decoration.delays)
	buttons.clear()
	for i in 2:
		var box: Array=variants[i].rectangle
		buttons["replay" if i==0 else "next"]=Rect2(box[0],box[1],box[2],box[3])
	var source: String=host.construction.runner.puzzle.source_name.get_file().to_upper()
	var group:=0
	for i in 4:
		if source.begins_with(["CAKE","BRAN","HARD","LOON"][i]): group=i
	group_text=layout.groups[group] if host.construction.runner.puzzle.campaign_goal_index >= 0 else "Home Toons"
	title_text='"'+host.construction.runner.puzzle.title+'"'
	# 6D38:0133 obtains the current DOS date for each reward invocation.
	# First-solved dates remain in progress storage, separately from this caption.
	date_text=Time.get_date_string_from_system()
	var date:=date_text.split("-")
	if date.size()==3: date_text="%d/%d/%02d"%[int(date[1]),int(date[2]),int(date[0])%100]
	queue_redraw()

func _start_entrance() -> void:
	entrance_started=true
	AudioEffects.play_sample(3011) # 6D38:001D follows the completed wipe.
	if not bool(owner_state.goal.get("interlude_done",false)):
		interlude.begin(owner_state.goal.get("campaign_presentation",{}))
		interlude_started=interlude.visible
	# 0589 loads the selected resources; 0133..01F5 composes captions and
	# presents BEFORE 01FA loads240. Predecoded Godot assets must not erase
	# that setup phase. This CPU budget is calibrated to the documented fixed
	#20000 profile, not claimed as a universal original delay instruction.
	var choice:=owner_state.completion_decoration()
	var key:="%d,%d"%[int(choice.variants[0]),int(choice.variants[1])]
	setup_remaining=float(timing_profile.pairs[key].setup_interrupts)*TIMER_SECONDS
	queue_redraw()

func _advance_entrance() -> void:
	for i in 2:
		if delays[i]>0: delays[i]-=1
		else:
			if phases[i]<int(variants[i].count): phases[i]+=1
			_play_frame_sound(int(variants[i].start)+phases[i]-1)

func _play_frame_sound(frame: int) -> void:
	# The native drawing dispatcher issues audio on each invocation, including
	# reverse exit frames (6D38:04B9/052D), not just during entrance.
	if layout.sounds.has(str(frame)): AudioEffects.play_sample(int(layout.sounds[str(frame)]))

func _begin_exit(action: String) -> void:
	pending=action
	exit_steps=5
	clock_accumulator=0.0
	next_interval=FRAME_SECONDS
	# 6D38:043D reloads12, then draws the first reverse pair immediately.
	# Five complete holds follow, independently of the idle entrance clock.
	_reverse_step()

func _reverse_step() -> void:
	var side:=0 if pending=="replay" else 1
	phases[side]=maxi(0,phases[side]-1)
	for i in 2:
		_play_frame_sound(int(variants[i].start)+phases[i]-1)
	queue_redraw()

func _process(delta: float) -> void:
	if not visible or not is_visible_in_tree(): return
	if owner_state!=host.construction.runner.state or not host.construction.is_completed():
		synchronize()
		return
	host.cursor_index=0
	if not entrance_started:
		delta=wipe.advance(delta)
		queue_redraw()
		if not wipe.finished(): return
		_start_entrance()
	if interlude_started:
		delta=interlude.advance(delta)
		queue_redraw()
		if interlude.visible: return
		interlude_started=false
		owner_state.goal.interlude_done=true
		# Native6D38:00A7..00B1 performs a further transition after extras.
		wipe.begin(host.construction.next_wipe_variant())
		interlude_wiping=true
	if interlude_wiping:
		delta=wipe.advance(delta)
		queue_redraw()
		if not wipe.finished(): return
		interlude_wiping=false
	if not setup_finished:
		var used:=minf(delta,setup_remaining)
		setup_remaining-=used
		delta-=used
		queue_redraw()
		if setup_remaining>0: return
		setup_finished=true
		# First entrance pair is immediate after setup, followed by240 counts.
		_advance_entrance()
	elapsed+=delta
	clock_accumulator+=delta
	while clock_accumulator>=next_interval:
		clock_accumulator-=next_interval
		next_interval=FRAME_SECONDS
		if exit_steps>0:
			exit_steps-=1
			if exit_steps==0:
				_activate(pending)
				return
			_reverse_step()
		elif not ready_for_input:
			# Native 03BC..03F4 waits after the final pair before enabling input.
			if phases[0]==int(variants[0].count) and phases[1]==int(variants[1].count): ready_for_input=true
			else: _advance_entrance()
	queue_redraw()

func _input(event: InputEvent) -> void:
	if not visible or not is_visible_in_tree(): return
	if event is InputEventMouse and not host.pointer_inside_screen(event):
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			pending = ""
		return
	if interlude.visible:
		if event is InputEventMouse: host.guest_pointer=host.screen.get_global_transform().affine_inverse()*event.position
		interlude.receive_input(event)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouse:
		host.guest_pointer=host.screen.get_global_transform().affine_inverse()*event.position
		if ready_for_input and exit_steps==0 and event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT:
			if event.pressed:
				pending=""
				for action in buttons:
					if buttons[action].has_point(host.guest_pointer): pending=action; break
			elif not pending.is_empty():
				if buttons[pending].has_point(host.guest_pointer): _begin_exit(pending)
				else: pending=""
		get_viewport().set_input_as_handled()
	elif event is InputEventKey:
		if event.pressed and not event.echo and event.keycode==KEY_ESCAPE: host.construction.stop()
		get_viewport().set_input_as_handled()

func _activate(action: String) -> void:
	visible=false
	if action=="replay": host.construction.replay_completed(false)
	elif not host.construction.advance_campaign(true): host.construction.stop()

func _width(text: String) -> int:
	var width:=0
	for ch in text: width+=int(font.glyphs.get(ch.unicode_at(0),font.glyphs[32]).width)
	return width

func _text(text: String) -> Texture2D:
	if text_cache.has(text): return text_cache[text]
	var image:=Image.create(maxi(2,_width(text)+2),int(font.height)+2,false,Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	var x:=1
	for ch in text:
		var glyph: Dictionary=font.glyphs.get(ch.unicode_at(0),font.glyphs[32])
		for y in int(glyph.height):
			for col in int(glyph.width):
				if glyph.pixels[y*int(glyph.width)+col]!=0:
					image.set_pixel(x+col+1,y+1,palette[4])
		for y in int(glyph.height):
			for col in int(glyph.width):
				if glyph.pixels[y*int(glyph.width)+col]!=0: image.set_pixel(x+col,y,palette[1])
		x+=int(glyph.width)
	text_cache[text]=ImageTexture.create_from_image(image)
	return text_cache[text]

func _paragraph(text: String, key: String) -> void:
	var box: Array=layout.text_boxes[key]
	var lines: Array[String]=[]
	var line:=""
	for word in text.replace("\n"," ").split(" "):
		var trial:=word if line.is_empty() else line+" "+word
		if _width(trial)>int(box[2]) and not line.is_empty():
			lines.append(line)
			line=word
		else: line=trial
	lines.append(line)
	var y:=int(box[1])
	for item in lines:
		if y+int(font.height)>int(box[1])+int(box[3]): break
		draw_texture(_text(item),Vector2(int(box[0])+(int(box[2])-_width(item))/2-1,y))
		y+=int(font.height)

func _case(index: int) -> void:
	# Art.commands expects top-level named lists.
	var key:=str(index)
	layout[key]=layout.commands.get(key,[])
	commands(key)

func _draw() -> void:
	if not visible: return
	if interlude.visible:
		draw_texture(shade,Vector2.ZERO)
		return
	if not entrance_started or not setup_finished:
		for box in wipe.visible_rectangles():
			draw_texture_rect_region(shade,Rect2(box),Rect2(box))
		return
	draw_texture(shade,Vector2.ZERO)
	_case(0)
	_paragraph(group_text,"group")
	_paragraph(title_text,"title")
	_paragraph(date_text,"date")
	for i in 2:
		if phases[i]>0: _case(int(variants[i].start)+phases[i]-1)
	if ready_for_input and host.construction.next_campaign_level(true).is_empty():
		var caption := "Campaign complete!" if host.construction.runner.puzzle.campaign_goal_index >= 0 else "Return to construction"
		draw_texture(_text(caption),Vector2((640 - _width(caption)) / 2,349))
