extends Control
## Keyboard-accessible authoring forms inside the 640x400 guest viewport.
var modal: Control
var host: Control
var panel: PanelContainer
var body: VBoxContainer
var title_field: LineEdit
var goal_field: TextEdit
var path_field: LineEdit
var file_field: LineEdit
var message: Label
var overwrite_path := ""
var mode := ""
var files: ItemList

func _init(owner_dialog: Control) -> void:
	modal=owner_dialog
	host=modal.host
	size=Vector2(640,400)
	mouse_filter=Control.MOUSE_FILTER_STOP
	visible=false

func begin(action: String) -> void:
	mode=action
	overwrite_path=""
	for child in get_children(): remove_child(child); child.queue_free()
	panel=PanelContainer.new()
	panel.position=Vector2(128,20)
	panel.size=Vector2(440,360)
	var style:=StyleBoxFlat.new()
	style.bg_color=Color("f5df52") if action=="editor_checklist" else Color("16d5eb")
	style.border_color=Color("141431")
	style.set_border_width_all(3)
	style.content_margin_left=12
	style.content_margin_right=12
	style.content_margin_top=10
	style.content_margin_bottom=10
	panel.add_theme_stylebox_override("panel",style)
	panel.add_theme_color_override("font_color",Color.BLACK)
	panel.add_theme_font_size_override("font_size",14)
	add_child(panel)
	body=VBoxContainer.new()
	body.add_theme_constant_override("separation",5)
	panel.add_child(body)
	visible=true
	if action in ["editor_goal","editor_save"]:
		panel.visible=false
		_native_form(action)
		return
	match action:
		"editor_checklist":
			label("MAKE-A-TOON CHECKLIST")
			button("Make-A-Toon: return to building",modal.close)
			button("Goal: edit title and instructions",func(): modal.open("editor_goal"))
			button("Lock all parts",func(): host.construction.pin_all(); modal.close())
			button("Choose fixed / inventory parts…",func(): begin("editor_pins"))
			button("Tune Toon Tunes",func(): modal.close(); modal.open("tunes"))
			button("Test-a-Toon",func(): modal.close(); host._play())
			button("Save-a-Toon",func(): modal.open("editor_save"))
			button("New blank Toon…",func(): begin("editor_new"))
			button("Load JSON puzzle…",func(): begin("editor_load"))
			button("OOPS",modal.close)
		"editor_pins":
			label("STICK IT DOWN")
			label("Checked: fixed on stage. Unchecked: player inventory.",12)
			var scroll:=ScrollContainer.new()
			scroll.custom_minimum_size=Vector2(400,245)
			body.add_child(scroll)
			var rows:=VBoxContainer.new()
			rows.size_flags_horizontal=Control.SIZE_EXPAND_FILL
			scroll.add_child(rows)
			for p in host.construction.runner.state.parts:
				if not p.active or not p.placed or p.spawned: continue
				var check:=CheckBox.new()
				check.text="%d: %s"%[p.index,host.construction.type_names.get(p.part_type,"Gadget")]
				check.button_pressed=bool(p.flags0a&0x40)
				check.add_theme_color_override("font_color",Color.BLACK)
				check.toggled.connect(func(value: bool): host.construction.set_pinned(p.index,value))
				rows.add_child(check)
			button("Done",modal.close)
		"editor_new":
			label("Start a blank Home Toon?")
			label("Save the current arrangement first if you want to keep it.")
			button("Create blank Toon",func(): modal.close(); host.construction.new_editor_puzzle())
			button("Cancel",modal.close)
		"editor_load":
			label("LOAD HOME TOON")
			var saved: String=host.construction.last_save_path
			path_field=field("Path",saved.get_base_dir() if not saved.is_empty() else host.construction.Document.default_folder())
			label("JSON · DOS:C:\\ maps to your local user_levels folder",12)
			file_field=field("File name",saved.get_file() if not saved.is_empty() else "HOME1.json")
			message=label("",12)
			message.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
			message.custom_minimum_size=Vector2(400,38)
			button("Load",_submit_file)
			button("Never mind",modal.close)
			file_field.grab_focus()
		_: modal.close()

func label(text: String, font_size: int=14) -> Label:
	var item:=Label.new()
	item.text=text
	item.add_theme_color_override("font_color",Color.BLACK)
	item.add_theme_font_size_override("font_size",font_size)
	body.add_child(item)
	return item

func field(caption: String, value: String) -> LineEdit:
	label(caption)
	var item:=LineEdit.new()
	item.text=value
	item.custom_minimum_size.y=27
	item.add_theme_font_size_override("font_size",14)
	body.add_child(item)
	return item

func button(caption: String, action: Callable) -> Button:
	var item:=Button.new()
	item.text=caption
	item.add_theme_font_size_override("font_size",14)
	item.custom_minimum_size.y=25
	item.pressed.connect(action)
	body.add_child(item)
	return item

func _apply_goal() -> void:
	if goal_field.text.length()>4096: return
	host.construction.runner.puzzle.title=title_field.text
	host.construction.runner.puzzle.instructions=goal_field.text
	host.construction.changed.emit()
	modal.close()

func native_field(rect: Rect2, value: String, color: Color) -> LineEdit:
	var edit:=LineEdit.new()
	edit.position=rect.position
	edit.size=rect.size
	edit.text=value
	edit.add_theme_color_override("font_color",color)
	edit.add_theme_font_size_override("font_size",16)
	for state in ["normal","focus"]: edit.add_theme_stylebox_override(state,StyleBoxEmpty.new())
	add_child(edit)
	return edit

func _native_form(action: String) -> void:
	if action=="editor_goal":
		title_field=native_field(Rect2(238,191,263,28),host.construction.runner.puzzle.title,modal.palette[14])
		title_field.max_length=255
		goal_field=TextEdit.new()
		goal_field.position=Vector2(252,231)
		goal_field.size=Vector2(249,140)
		goal_field.text=host.construction.runner.puzzle.instructions
		goal_field.wrap_mode=TextEdit.LINE_WRAPPING_BOUNDARY
		goal_field.add_theme_color_override("font_color",modal.palette[10])
		goal_field.add_theme_font_size_override("font_size",16)
		for state in ["normal","focus"]: goal_field.add_theme_stylebox_override(state,StyleBoxEmpty.new())
		add_child(goal_field)
		host._button(self,Rect2(160,332,69,50),"Save title and goal",_apply_goal)
		host._button(self,Rect2(140,0,379,146),"Cancel",modal.close)
		title_field.grab_focus()
		return
	modal.piggy.save_mode=true
	modal.piggy.visible=true
	modal.piggy.queue_redraw()
	var saved: String=host.construction.last_save_path
	path_field=native_field(Rect2(226,43,246,26),saved.get_base_dir() if not saved.is_empty() else "DOS:C:\\",modal.palette[14])
	path_field.tooltip_text="DOS:C:\\ maps to player_data/user_levels inside this project."
	title_field=native_field(Rect2(225,294,246,26),host.construction.runner.puzzle.title,modal.palette[1])
	title_field.max_length=255
	file_field=native_field(Rect2(300,339,144,25),saved.get_file() if not saved.is_empty() else "HOME1.json",modal.palette[1])
	files=ItemList.new()
	files.position=Vector2(151,93)
	files.size=Vector2(317,172)
	files.add_theme_stylebox_override("panel",StyleBoxEmpty.new())
	files.add_theme_color_override("font_color",modal.palette[1])
	files.add_theme_font_size_override("font_size",16)
	add_child(files)
	files.item_selected.connect(func(index: int): file_field.text=files.get_item_metadata(index))
	path_field.text_changed.connect(func(_value: String): _refresh_files())
	_refresh_files()
	message=Label.new()
	message.position=Vector2(148,267)
	message.size=Vector2(370,20)
	message.add_theme_color_override("font_color",Color.BLACK)
	message.add_theme_font_size_override("font_size",12)
	message.clip_text=true
	add_child(message)
	host._button(self,Rect2(155,331,86,42),"Save JSON puzzle",_submit_file)
	host._button(self,Rect2(458,335,90,41),"Never mind",modal.close)
	host._button(self,Rect2(518,157,46,67),"Previous files",func(): files.get_v_scroll_bar().value-=120)
	host._button(self,Rect2(524,235,37,49),"Next files",func(): files.get_v_scroll_bar().value+=120)
	file_field.grab_focus()

func _refresh_files() -> void:
	files.clear()
	var folder:=destination().get_base_dir()
	if not DirAccess.dir_exists_absolute(folder): return
	for filename in DirAccess.get_files_at(folder):
		if filename.get_extension().to_lower()!="json": continue
		files.add_item(filename)
		files.set_item_metadata(files.item_count-1,filename)

func destination() -> String:
	var folder:=path_field.text.strip_edges().replace("\\","/")
	# A DOS path belongs to a virtual drive; never overwrite the installed DOS save.
	if folder.to_upper().begins_with("DOS:C:/"):
		var tail:=folder.substr(7)
		if not tail.contains(":") and not tail.split("/").has(".."): folder=host.construction.Document.default_folder().path_join(tail)
		else: return ""
	var filename:=file_field.text.strip_edges()
	if filename.is_empty() or filename.get_file()!=filename or filename.contains(":") or filename.contains("\\"): return ""
	if filename.get_extension().is_empty(): filename+=".json"
	return folder.path_join(filename)

func _submit_file() -> void:
	var path:=destination()
	if path.is_empty(): message.text="Enter a filename without directory separators."; return
	if mode=="editor_load":
		var error: String=host.construction.load_editor(path)
		if error.is_empty(): modal.close()
		else: message.text=error
		return
	if FileAccess.file_exists(path) and overwrite_path!=path:
		overwrite_path=path
		message.text="File exists. Press Save again to replace it."
		return
	var error: String=host.construction.save_editor(path,title_field.text,overwrite_path==path)
	if error.is_empty(): modal.close()
	else: message.text=error

func _input(event: InputEvent) -> void:
	if not is_visible_in_tree(): return
	if event is InputEventKey and event.pressed and event.keycode==KEY_ESCAPE:
		modal.close()
		get_viewport().set_input_as_handled()
