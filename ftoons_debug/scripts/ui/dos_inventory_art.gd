extends Control
## Draw commands extracted from original resident code; hit areas live separately.
const Formats = preload("res://scripts/graphics/dynamix_formats.gd")
const SpriteGraphicsPack = preload("res://scripts/graphics/sprite_graphics_pack.gd")
var layout: Dictionary
var palette: Array
var sprite_graphics: SpriteGraphicsPack
var sheets: Dictionary = {}
var mirrored: Dictionary = {}
var remote_open := false
var running := false
var pressed := ""
var hover_key := ""
var hover_elapsed := 0.0
var editor_mode := false
var head_to_head_mode := false
var campaign_colors: Dictionary
var editor_colors: Dictionary
var home_cycle := 0
const RIGHT_HOVER_RECTS := {
	"home":Rect2(583,0,57,61),"editor_save_arrow":Rect2(616,61,24,36),"load":Rect2(592,73,24,26),
	"save":Rect2(593,97,47,46),"goal":Rect2(593,144,42,50),
	"tunes":Rect2(587,191,53,50),"nuke":Rect2(591,241,49,56),
	"checklist":Rect2(593,299,47,47),"exit":Rect2(593,348,47,45)}

func advance_hover(point: Vector2, enabled: bool, delta: float) -> void:
	var next:=""
	if enabled and not running:
		if Rect2(1,354,43,35).has_point(point): next="previous"
		elif Rect2(44,353,44,40).has_point(point): next="next"
		elif remote_open:
			for key in RIGHT_HOVER_RECTS:
				if head_to_head_mode and key not in ["home","goal","tunes","exit"]: continue
				if key in ["editor_save_arrow","checklist"] and not editor_mode: continue
				if RIGHT_HOVER_RECTS[key].has_point(point): next=key; break
	var changed:=next!=hover_key
	if changed:
		hover_key=next
		hover_elapsed=0.0
		if next=="home" and editor_mode: home_cycle+=1
	else: hover_elapsed+=delta
	if changed or not hover_key.is_empty(): queue_redraw()


func _init(catalog: ResourceCatalog, graphics: SpriteGraphicsPack = null) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	layout = JSON.parse_string(FileAccess.get_file_as_string("res://assets/original/dos_inventory_ui.json"))
	var hover: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://assets/original/dos_right_hover.json"))
	for key in hover:
		if hover[key] is Array: layout["hover_"+key]=hover[key]
	# Replace the moving arrow in its original layer, before its base and pig.
	# Painting it after right_controls lets its pixels cover those foreground parts.
	var load_controls: Array=[]
	var home_controls: Array=[]
	for command in layout.right_controls:
		if not (command.kind=="sprite" and command.table=="0x44bd" and int(command.frame)==4):
			home_controls.append(command)
		if command.kind=="sprite" and command.table=="0x44bd" and int(command.frame)==7:
			load_controls.append_array(hover.load)
		else: load_controls.append(command)
	layout["right_controls_load_hover"]=load_controls
	layout["right_controls_without_home"]=home_controls
	sprite_graphics = graphics if graphics != null else SpriteGraphicsPack.new(catalog)
	palette = sprite_graphics.palette
	sprite_graphics.changed.connect(_refresh_sprites)
	var editor: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://assets/original/dos_home_editor.json"))
	campaign_colors=layout.colors.duplicate()
	editor_colors=editor.colors
	layout["editor_controls"]=editor.editor_controls
	var resources: Array=layout.tables.values()
	resources.append("TN_ED_CN.BMP")
	_load_sheets(resources)

func _load_sheets(resources: Array) -> void:
	for resource in resources:
		sheets[resource] = sprite_graphics.frames(resource)

func _refresh_sprites() -> void:
	mirrored.clear()
	queue_redraw()

func _draw() -> void:
	layout.colors=editor_colors if editor_mode else campaign_colors
	layout.tables["0x44d1"]="TN_ED_CN.BMP" if editor_mode else "TN_PL_CN.BMP"
	commands("left_background")
	commands("play_running" if running else "play_idle", Vector2(-2,2) if pressed == "play" else Vector2.ZERO)
	commands("remote_open" if remote_open else "remote_closed", Vector2(0,2) if pressed == "remote" else Vector2.ZERO)
	commands("previous_pressed" if pressed == "previous" or (hover_key=="previous" and int(hover_elapsed/0.5)%2==0) else "previous")
	commands("next_pressed" if pressed == "next" or (hover_key=="next" and int(hover_elapsed/0.5)%2==0) else "next")
	if remote_open and not running:
		commands("right_background")
		var load_hover:=hover_key=="load" and int(hover_elapsed/0.5)%2==0
		commands("right_controls_without_home" if editor_mode or hover_key=="home" else ("right_controls_load_hover" if load_hover else "right_controls"))
		if editor_mode: commands("editor_controls")
		if editor_mode and hover_key=="home":
			# 298D:1450 varies phase duration and direction with DS:43D0.
			var phase:=int(hover_elapsed/((15.0-2.0*(home_cycle%5))/60.0))%3
			commands("hover_editor_home_clear")
			if phase==2: commands("hover_editor_home_idle")
			else: commands("hover_editor_home_%d"%((phase if home_cycle%2 else 1-phase)+1))
		elif editor_mode and hover_key in ["load","editor_save_arrow","save","checklist"]:
			var active:=int(hover_elapsed/0.5)%2==0
			if hover_key=="load":
				commands("hover_load" if active else "hover_load_idle")
				commands("hover_editor_save_arrow_idle")
			elif hover_key=="editor_save_arrow":
				commands("hover_editor_save_arrow" if active else "hover_editor_save_arrow_idle")
				commands("hover_load_idle")
			elif hover_key=="checklist":
				commands("hover_checklist_clear")
				commands("hover_checklist" if active else "hover_checklist_idle")
			else: commands("hover_save" if active else "hover_save_idle")
		elif hover_key=="home" and not editor_mode:
			var phase:=fmod(hover_elapsed,1.25)
			# Native 136B restores the full background, including its curved cap.
			# Each phase is composed from scratch; phase 1 replaces the idle head.
			commands("hover_home_clear")
			if phase<0.5: commands("hover_home_1")
			else:
				commands("hover_home_idle")
				if phase<1.0: commands("hover_home_2" if phase<0.75 else "hover_home_3")
		elif hover_key!="load" and hover_key!="home" and not hover_key.is_empty() and (not editor_mode or hover_key in ["goal","tunes","nuke","exit"]) and int(hover_elapsed/(0.5 if hover_key in ["goal","exit"] else 1.0/3.0))%2==0:
			commands("hover_"+hover_key)

func commands(key: String, offset := Vector2.ZERO) -> void:
	for command in layout.get(key, []):
		if head_to_head_mode and key.begins_with("right_controls") and command.kind=="sprite" and command.table=="0x44bd" and int(command.frame) not in [4,16,17,19,26]: continue
		if command.kind == "sprite":
			var frames: Array = sheets[layout.tables[command.table]]
			if command.frame < frames.size():
				var texture: Texture2D = frames[int(command.frame)]
				if int(command.flags) & 3:
					var mirror_key := "%s/%d/%d" % [command.table,command.frame,command.flags]
					if not mirrored.has(mirror_key):
						var image := texture.get_image()
						if int(command.flags)&2: image.flip_x()
						if int(command.flags)&1: image.flip_y()
						mirrored[mirror_key] = ImageTexture.create_from_image(image)
					texture = mirrored[mirror_key]
				draw_texture(texture, Vector2(command.xy[0],command.xy[1])+offset)
		else:
			var index: int = int(layout.colors["0x%x" % int(command.color[1])]) if command.color is Array else int(command.color)
			var color: Color = palette[index]
			var a: Array = command.xywh
			if command.kind == "rect":
				draw_rect(Rect2(Vector2(a[0],a[1])+offset,Vector2(a[2],a[3])),color)
			else:
				draw_line(Vector2(a[0],a[1])+offset,Vector2(a[2],a[3])+offset,color,1)
