extends Control

var catalog: ResourceCatalog
var search_box: LineEdit
var type_box: OptionButton
var list: ItemList
var details: RichTextLabel
var status: Label

func _init(resource_catalog: ResourceCatalog) -> void:
	catalog = resource_catalog

func _ready() -> void:
	_build_ui()
	_refresh()

func _build_ui() -> void:
	var background := ColorRect.new()
	background.color = Color("#17202a")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_bottom", 20)
	add_child(margin)

	var columns := VBoxContainer.new()
	margin.add_child(columns)
	var title := Label.new()
	title.text = "Sid & Al's Incredible Toons — Resource browser"
	title.add_theme_font_size_override("font_size", 24)
	columns.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "DOS assets are in the project's assets folder."
	if ImportedResources.windows_ready:
		var win: Dictionary = ImportedResources.counts.windows
		subtitle.text += " Windows CD tracks: %d. Voiced intro clips: %d." % [int(win.get("cd_tracks", 0)), int(win.get("intro_clips", 0))]
		if int(win.get("cd_tracks", 0)) == 0:
			subtitle.text += " Add the mixed-mode BIN/CUE for CD music."
	subtitle.modulate = Color("#aeb6bf")
	columns.add_child(subtitle)
	if not ImportedResources.windows_ready or int(ImportedResources.counts.windows.get("cd_tracks", 0)) < 24 or int(ImportedResources.counts.windows.get("intro_clips", 0)) < 167:
		var add_windows := Button.new()
		add_windows.text = "Add Windows CD media…" if ImportedResources.windows_ready else "Add Windows game files…"
		add_windows.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		columns.add_child(add_windows)
		var confirm := ConfirmationDialog.new()
		confirm.dialog_text = "Return to game file setup? Save any Home Toon edits you want to keep first."
		confirm.ok_button_text = "Open setup"
		add_child(confirm)
		add_windows.pressed.connect(func(): confirm.popup_centered())
		confirm.confirmed.connect(func():
			AudioEffects.stop_all_effects()
			MusicPlayer.stop_music()
			ImportedResources.setup_requested = true
			get_tree().change_scene_to_file("res://scenes/import_start.tscn"))

	var filters := HBoxContainer.new()
	filters.add_theme_constant_override("separation", 10)
	columns.add_child(filters)
	search_box = LineEdit.new()
	search_box.placeholder_text = "Filter by DOS filename"
	search_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search_box.text_changed.connect(func(_value: String) -> void: _refresh())
	filters.add_child(search_box)
	type_box = OptionButton.new()
	type_box.custom_minimum_size.x = 150
	type_box.item_selected.connect(func(_index: int) -> void: _refresh())
	filters.add_child(type_box)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_child(split)
	list = ItemList.new()
	list.custom_minimum_size.x = 410
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.item_selected.connect(_on_item_selected)
	split.add_child(list)
	details = RichTextLabel.new()
	details.bbcode_enabled = true
	details.fit_content = false
	details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	details.size_flags_vertical = Control.SIZE_EXPAND_FILL
	details.text = "Select a resource to inspect its archive metadata and read a byte sample."
	split.add_child(details)
	status = Label.new()
	status.modulate = Color("#aeb6bf")
	columns.add_child(status)

func _refresh() -> void:
	if list == null or type_box == null:
		return
	if type_box.item_count == 0:
		type_box.add_item("All types")
		for type in catalog.types():
			type_box.add_item(String(type))
	var selected_type := ""
	if type_box.selected > 0:
		selected_type = type_box.get_item_text(type_box.selected)
	var results := catalog.find(search_box.text, selected_type)
	list.clear()
	for entry in results:
		var index := list.add_item("%s  [%s]  %d B" % [entry["name"], entry["type"], int(entry["size"])])
		list.set_item_metadata(index, entry)
	status.text = "%d visible / %d indexed resources" % [results.size(), catalog.count()]
	if results.is_empty():
		details.text = "No matching resource."

func _on_item_selected(index: int) -> void:
	var entry: Dictionary = list.get_item_metadata(index)
	var bytes := catalog.read_asset(String(entry["name"]))
	var sample := bytes.slice(0, mini(32, bytes.size())).hex_encode()
	details.text = "[font_size=18][b]%s[/b][/font_size]\n\nType: %s\nPayload: %d bytes\nArchive offset: 0x%X\nPayload offset: 0x%X\nSHA-256: %s\n\nFirst bytes (%d):\n%s" % [
		entry["name"], entry["type"], int(entry["size"]), int(entry["offset"]), int(entry["payload_offset"]), entry["sha256"], bytes.size(), sample
	]
