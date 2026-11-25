extends Control
## Original selection strips and confirmed transform tools. No simulation clock.
const Rules = preload("res://scripts/ui/dos_construction_rules.gd")
var host: Control
var selected := -1
var phase := 0
var animation_accumulator := 0.0
var handles: Array[Texture2D] = []
var buttons: Dictionary = {}
var layout: Dictionary
var hovered := ""
var tool_phase := 0
var flip_allowed: Dictionary = {}
var tools_dirty := true
var type_rows: Dictionary = {}

func _init(game: Control) -> void:
	host=game
	mouse_filter=Control.MOUSE_FILTER_IGNORE
	texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
	layout=JSON.parse_string(FileAccess.get_file_as_string("res://assets/original/dos_construction_ui.json"))
	layout.tool_frames["pin"]=int(layout.pin_frames[0])
	for row in layout.types: type_rows[int(row.type)]=row
	host.construction.changed.connect(func(): tools_dirty=true)
	handles = host.sprite_graphics.frames("HANDLES.BMP")

func eligible(index: int) -> bool:
	var c: RefCounted=host.construction
	if c.runner==null or index<0 or index>=c.runner.state.parts.size(): return false
	if not c.can_edit_part(index): return false
	var p: SimulationState.SimPart=c.runner.state.parts[index]
	return p.active and p.placed and (c.is_editor() or not (p.flags0a&0x40)) and p.part_type not in [1,14,76] and (p.definition.is_in_parts_bin() or c.is_editor())

func _process(delta: float) -> void:
	var c: RefCounted=host.construction
	if host.intro_player != null and host.intro_player.visible:
		visible = false
		buttons.clear()
		return
	if (host.program_dialog!=null and host.program_dialog.visible) or (host.right_dialog!=null and host.right_dialog.visible):
		visible=false
		buttons.clear()
		return
	visible=host.is_visible_in_tree() and c.runner!=null and c.play_backup==null
	if not visible: return
	var mouse: Vector2=host.guest_pointer
	var old_selected:=selected
	var over_action := ""
	for action in buttons:
		if buttons[action].has_point(mouse): over_action=action
	if over_action!=hovered:
		hovered=over_action
		tool_phase=0
	if mouse.x>=88 and (not host.remote_open or mouse.x<583): host.cursor_index=0
	if c.grab_index>=0:
		selected=c.grab_index
	elif c.grab_active:
		selected=-1
	else:
		var over_tool:=false
		for rect in buttons.values():
			if rect.has_point(mouse): over_tool=true
		# Keep selection across the gap between the body and its tool regions.
		if eligible(selected):
			var envelope:=Rect2(Rules.frame(c.runner,c.runner.state.parts[selected]))
			envelope.position+=Vector2(91,8)
			if envelope.grow(38).has_point(mouse): over_tool=true
		if not over_tool:
			selected=-1
			if mouse.x>=88 and (not host.remote_open or mouse.x<583):
				for i in range(c.runner.state.parts.size()-1,-1,-1):
					if eligible(i) and Rect2(Rules.frame(c.runner,c.runner.state.parts[i])).has_point(mouse-Vector2(91,8)):
						selected=i
						break
	if selected!=old_selected: tools_dirty=true
	if eligible(selected) and not c.grab_active:
		host.cursor_index=2
		if tools_dirty:
			flip_allowed.clear()
			var backup: SimulationState=c.runner.state.clone()
			var previous: int=c.selected_index
			var old_status: String=c.status
			c.selected_index=selected
			c.probing_transform=true
			for action in ["flip_x","flip_y"]:
				c.call("_flip_x_selected" if action=="flip_x" else "_flip_y_selected")
				flip_allowed[action]=not Rules.blocked(c.runner,selected)
				c.runner.state=backup.clone()
			c.runner.state=backup
			c.probing_transform=false
			c.selected_index=previous
			c.status=old_status
			# Trial transforms replace state, so both presentations must rebind.
			c.changed.emit()
			tools_dirty=false
	advance_animation(delta,c.grab_active)
	queue_redraw()

func advance_animation(delta: float, dragging: bool) -> void:
	# DOS live DS:0548/42BC: held preview ~30Hz, tool hover ~60Hz at
	# fixed 20000 cycles. Draw calls must never advance either sequence.
	var interval := 1.0 / (30.0 if dragging else 60.0)
	animation_accumulator += delta
	while animation_accumulator + 0.0000001 >= interval:
		animation_accumulator -= interval
		phase=0 if phase>=7 else phase+2
		if not hovered.is_empty(): tool_phase+=1

func _draw() -> void:
	buttons.clear()
	var c: RefCounted=host.construction
	if not eligible(selected) or c.play_backup!=null: return
	var p: SimulationState.SimPart=c.runner.state.parts[selected]
	var box:=Rect2(Rules.frame(c.runner,p))
	box.position+=Vector2(91,8)
	# Native tool envelope and strip clipping are independent of collision bounds.
	if box.size.x<32:
		box.position.x-=floorf((32-box.size.x)/2)
		box.size.x=32
	if box.size.y<32:
		box.position.y-=floorf((32-box.size.y)/2)
		box.size.y=32
	var border:=box.grow(4).intersection(Rect2(88,0,495 if host.remote_open else 552,400))
	if border.has_area():
		strip(Rect2(border.position,Vector2(border.size.x,5)),11,false)
		strip(Rect2(Vector2(border.position.x,border.end.y-4),Vector2(border.size.x,5)),11,false)
		strip(Rect2(border.position,Vector2(8,border.size.y)),12,true)
		strip(Rect2(Vector2(border.end.x-7,border.position.y),Vector2(8,border.size.y)),12,true)
		if c.grab_index==selected and c.placement_invalid:
			for offset in [-1,0,1]:
				var color: Color=host.canvas.palette[8 if offset==0 else 4]
				draw_line(border.position+Vector2(offset,0),border.end+Vector2(offset,0),color)
				draw_line(Vector2(border.position.x+offset,border.end.y),Vector2(border.end.x+offset,border.position.y),color)
	if c.grab_active: return
	if c.is_editor():
		# 26B1:1C22..1C9E selects by pin flag, not hover sequence index.
		layout.tool_frames["pin"]=int(layout.pin_frames[1 if p.flags0a&0x40 else 0])
		# MOUSE.BMP: 8 = "stick it down" (pin); 3 = "flush it" (trash).
		tool("pin",Vector2(box.end.x+2,box.position.y-37),8)
		if p.flags0a&0x40: return
	# 1000:4957..496A enables Flush for unpinned campaign gadgets too.
	tool("trash",Vector2(box.position.x-37,box.position.y-37),3)
	# 26B1:18E1. Trial flips are checked at click time, and rolled back if blocked.
	if p.flags&0x400 and flip_allowed.get("flip_x",false): tool("flip_x",Vector2(box.position.x-37,box.end.y+2),4)
	if p.flags&0x200 and flip_allowed.get("flip_y",false): tool("flip_y",box.end+Vector2(2,2),5)
	if c.can_program(selected):
		tool("program",Vector2(box.end.x+2,box.get_center().y-16),8)
	# Native table limits; walls use a 16px transverse dimension and
	# Thumpulator height selects its 65px constructor sections.
	if p.part_type in [0,26,27,28,29,82,83,47,48,49,50,51,84] and p.flags08&0x80:
		tool("left",Vector2(box.position.x-37,box.get_center().y-16),6)
		tool("right",Vector2(box.end.x+2,box.get_center().y-16),6)
	if p.part_type in [26,27,28,29,82,83,40,45] and p.flags08&0x100:
		tool("top",Vector2(box.get_center().x-16,box.position.y-37),7)
		tool("bottom",Vector2(box.get_center().x-16,box.end.y+2),7)

func strip(rect: Rect2, frame: int, vertical: bool) -> void:
	var texture: Texture2D=host.cursor_frames[frame]
	var length:=int(rect.size.y if vertical else rect.size.x)
	var maximum:=int(texture.get_height() if vertical else texture.get_width())
	var at:=0
	while at<length:
		var start:=phase if at==0 else 0
		var count:=mini(maximum-start,length-at)
		var size:=Vector2(rect.size.x,count) if vertical else Vector2(count,rect.size.y)
		var offset:=Vector2(0,at) if vertical else Vector2(at,0)
		var source:=Vector2(0,start) if vertical else Vector2(start,0)
		draw_texture_rect_region(texture,Rect2(rect.position+offset,size),Rect2(source,size))
		at+=count

func tool(action: String, point: Vector2, cursor_id: int) -> void:
	if host.construction.is_editor():
		point=point.clamp(Vector2(88,0),Vector2(551 if host.remote_open else 608,368))
	var rect:=Rect2(point,Vector2(32,32))
	if point.x<88 or point.y<0 or rect.end.x>(583 if host.remote_open else 640) or rect.end.y>400: return
	buttons[action]=rect
	var f:=int(layout.tool_frames[action])
	if hovered==action:
		var sequence: Array=layout.tool_sequences.get(action,[])
		if not sequence.is_empty():
			f=int(sequence[tool_phase%sequence.size()])
	if f<handles.size(): draw_texture(handles[f],point)
	if rect.has_point(host.guest_pointer): host.cursor_index=cursor_id

func _input(event: InputEvent) -> void:
	if host.intro_player != null and host.intro_player.visible: return
	if host.program_dialog.visible or host.right_dialog.visible: return
	if not is_visible_in_tree() or not event is InputEventMouseButton or not event.pressed or event.button_index!=MOUSE_BUTTON_LEFT: return
	var c: RefCounted=host.construction
	if c.grab_active or c.play_backup!=null or not eligible(selected): return
	var pointer: Vector2=host.screen.get_global_transform().affine_inverse()*event.position
	host.guest_pointer=pointer
	for action in buttons:
		if buttons[action].has_point(pointer):
			if action=="pin":
				c.set_pinned(selected,not bool(c.runner.state.parts[selected].flags0a&0x40))
				get_viewport().set_input_as_handled()
				return
			if action=="trash":
				c.flush_part(selected)
				get_viewport().set_input_as_handled()
				return
			if action=="program":
				host.program_dialog.open(selected)
				get_viewport().set_input_as_handled()
				return
			if action in ["left","right","top","bottom"]:
				c.begin_native_resize(selected,action,type_rows[c.runner.state.parts[selected].part_type].size_limits)
				get_viewport().set_input_as_handled()
				return
			var backup: SimulationState=c.runner.state.clone()
			c.selected_index=selected
			var native_handled: bool=c.call("_flip_native_selected",1 if action=="flip_x" else 2)
			if not native_handled:
				c.call("_flip_x_selected" if action=="flip_x" else "_flip_y_selected")
			if Rules.blocked(c.runner,selected):
				c.runner.state=backup
				c.status="Flip refused: another gadget blocks this position."
			c.changed.emit()
			get_viewport().set_input_as_handled()
			return
