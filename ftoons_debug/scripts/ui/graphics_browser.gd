class_name GraphicsBrowser
extends Control

const DynamixFormats = preload("res://scripts/graphics/dynamix_formats.gd")

var catalog: ResourceCatalog
var resource_box: OptionButton
var frame_box: OptionButton
var palette_box: OptionButton
var preview: TextureRect
var swatches: GridContainer
var details: RichTextLabel
var status: Label
var graphics_entries: Array = []
var decoded: Dictionary = {}
var palettes: Dictionary = {}

func _init(resource_catalog: ResourceCatalog) -> void:
	catalog = resource_catalog

func _ready() -> void:
	_build_ui()
	_load_palettes()
	_populate_resources()
	_refresh()

func _build_ui() -> void:
	var background := ColorRect.new()
	background.color = Color("#101820")
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
	title.text = "Graphics viewer — Iteration 2"
	title.add_theme_font_size_override("font_size", 24)
	columns.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "Dynamix PAL, SCR, SCN/OFF, and BIN readers; indexed pixels are rendered with a selected VGA palette."
	subtitle.modulate = Color("#aeb6bf")
	columns.add_child(subtitle)

	var controls := HBoxContainer.new()
	controls.add_theme_constant_override("separation", 10)
	columns.add_child(controls)
	resource_box = OptionButton.new()
	resource_box.custom_minimum_size.x = 300
	resource_box.item_selected.connect(func(_index: int) -> void: _on_resource_changed())
	controls.add_child(resource_box)
	frame_box = OptionButton.new()
	frame_box.custom_minimum_size.x = 190
	frame_box.item_selected.connect(func(_index: int) -> void: _refresh())
	controls.add_child(frame_box)
	palette_box = OptionButton.new()
	palette_box.custom_minimum_size.x = 180
	palette_box.item_selected.connect(func(_index: int) -> void: _refresh())
	controls.add_child(palette_box)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_child(split)
	preview = TextureRect.new()
	preview.custom_minimum_size = Vector2(640, 400)
	preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	split.add_child(preview)

	var inspector := VBoxContainer.new()
	inspector.custom_minimum_size.x = 300
	split.add_child(inspector)
	details = RichTextLabel.new()
	details.bbcode_enabled = true
	details.fit_content = false
	details.size_flags_vertical = Control.SIZE_EXPAND_FILL
	details.text = "Select a palette, screen, or sprite resource."
	inspector.add_child(details)
	swatches = GridContainer.new()
	swatches.columns = 16
	swatches.visible = false
	inspector.add_child(swatches)
	status = Label.new()
	status.modulate = Color("#aeb6bf")
	columns.add_child(status)

func _load_palettes() -> void:
	palette_box.add_item("AUTO")
	for entry in catalog.find("", "PAL"):
		var name := String(entry["name"])
		var result: Dictionary = DynamixFormats.decode_palette(catalog.read_asset(name))
		if result.get("ok", false):
			palettes[name] = result["colors"]
			palette_box.add_item(name)

func _populate_resources() -> void:
	for entry in catalog.entries():
		var type := String(entry.get("type", ""))
		if type in ["BMP", "SCR", "PAL"]:
			graphics_entries.append(entry)
	for entry in graphics_entries:
		resource_box.add_item(String(entry["name"]))
		resource_box.set_item_metadata(resource_box.item_count - 1, entry)
	if resource_box.item_count > 0 and resource_box.selected < 0:
		resource_box.select(0)
	status.text = "%d graphics resources indexed; %d palettes decoded" % [graphics_entries.size(), palettes.size()]

func _on_resource_changed() -> void:
	frame_box.clear()
	var entry: Dictionary = resource_box.get_item_metadata(resource_box.selected)
	var name := String(entry["name"])
	var result: Dictionary
	if decoded.has(name):
		result = decoded[name]
	else:
		var data := catalog.read_asset(name)
		if String(entry["type"]) == "BMP":
			result = DynamixFormats.decode_bmp(data)
		elif String(entry["type"]) == "SCR":
			result = DynamixFormats.decode_scr(data)
		else:
			result = DynamixFormats.decode_palette(data)
		decoded[name] = result
	if not result.get("ok", false):
		_show_decoder_error(name, String(result.get("error", "unknown error")))
		return
	var kind := _result_kind(entry, result)
	if kind == "palette":
		var colors_variant = result.get("colors", null)
		if not (colors_variant is Array):
			_show_decoder_error(name, "palette decoder returned no colors")
			return
		frame_box.add_item("Palette swatches")
		frame_box.disabled = true
	elif kind == "scr":
		frame_box.disabled = false
		frame_box.add_item("Screen %dx%d" % [int(result.get("width", 0)), int(result.get("height", 0))])
	elif kind == "bmp":
		var frames_variant = result.get("frames", null)
		if not frames_variant is Array or frames_variant.is_empty():
			_show_decoder_error(name, "BMP decoder returned no frames")
			return
		frame_box.disabled = false
		var frames: Array = frames_variant
		for index in range(frames.size()):
			if not (frames[index] is Dictionary):
				_show_decoder_error(name, "BMP frame %d is not a dictionary" % index)
				return
			var frame: Dictionary = frames[index]
			frame_box.add_item("Frame %d  %dx%d" % [index, int(frame.get("width", 0)), int(frame.get("height", 0))])
	else:
		_show_decoder_error(name, "decoder returned unknown kind: %s" % kind)
		return
	_refresh()

func _refresh() -> void:
	if resource_box == null or resource_box.item_count == 0:
		return
	var entry: Dictionary = resource_box.get_item_metadata(resource_box.selected)
	var name := String(entry["name"])
	if not decoded.has(name):
		_on_resource_changed()
		return
	var result: Dictionary = decoded[name]
	if not result.get("ok", false):
		return
	var kind := _result_kind(entry, result)
	var palette_name := _selected_palette(name)
	var palette: Array = palettes.get(palette_name, [])
	if kind == "palette":
		var colors_variant = result.get("colors", null)
		if colors_variant is Array:
			_show_palette(colors_variant)
		else:
			_show_decoder_error(name, "palette decoder returned no colors")
		return
	if palette.is_empty():
		details.text = "[b]%s[/b]\n\nNo VGA palette is available." % name
		preview.texture = null
		swatches.visible = false
		return
	var frame: Dictionary
	if kind == "scr":
		frame = {
			"width": int(result.get("width", 0)),
			"height": int(result.get("height", 0)),
			"pixels": result.get("pixels", PackedByteArray()),
		}
	elif kind == "bmp":
		var frames_variant = result.get("frames", null)
		if not (frames_variant is Array) or frames_variant.is_empty():
			_show_decoder_error(name, "BMP decoder returned no frames")
			return
		var frames: Array = frames_variant
		var frame_index := maxi(0, frame_box.selected)
		if frame_index >= frames.size() or not (frames[frame_index] is Dictionary):
			_show_decoder_error(name, "selected BMP frame is unavailable")
			return
		frame = frames[frame_index]
	else:
		_show_decoder_error(name, "decoder returned unknown kind: %s" % kind)
		return
	if not frame.has("width") or not frame.has("height") or not frame.has("pixels"):
		_show_decoder_error(name, "decoded frame is missing dimensions or pixels")
		return
	var image: Image = DynamixFormats.frame_to_image(frame, palette)
	preview.texture = ImageTexture.create_from_image(image)
	preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	swatches.visible = false
	var frame_pixels: PackedByteArray = frame["pixels"]
	details.text = "[b]%s[/b]\n\nDimensions: %dx%d\nPalette: %s\nPixels: %d indexed values\nDecoder: %s" % [
		name, int(frame.get("width", 0)), int(frame.get("height", 0)), palette_name, frame_pixels.size(), result.get("compression", "indexed")
	]
	status.text = "%s rendered from packaged bytes" % name

func _show_palette(colors: Array) -> void:
	preview.texture = null
	swatches.visible = true
	for child in swatches.get_children():
		child.free()
	for color in colors:
		var swatch := ColorRect.new()
		swatch.color = color
		swatch.custom_minimum_size = Vector2(16, 16)
		swatches.add_child(swatch)
	details.text = "[b]Palette[/b]\n\n256 VGA entries\nComponents are original 0–63 DAC values scaled to Godot colors."
	status.text = "palette swatches rendered"

func _show_decoder_error(name: String, message: String) -> void:
	details.text = "[b]%s[/b]\n\nDecoder error:\n%s" % [name, message]
	preview.texture = null
	swatches.visible = false
	status.text = "%s remains unsupported" % name

func _result_kind(entry: Dictionary, result: Dictionary) -> String:
	var kind := String(result.get("kind", ""))
	if not kind.is_empty():
		return kind
	# Keep the UI compatible with older cached decoder dictionaries while the
	# decoder contract is being migrated to explicit kinds.
	match String(entry.get("type", "")):
		"PAL": return "palette"
		"SCR": return "scr"
		"BMP": return "bmp"
	return ""

func _selected_palette(resource_name: String) -> String:
	if palette_box.selected > 0:
		return palette_box.get_item_text(palette_box.selected)
	var upper := resource_name.to_upper()
	if upper.begins_with("TITLE") and palettes.has("TITLE.PAL"):
		return "TITLE.PAL"
	if upper.begins_with("DYNAMIX") and palettes.has("DYNAMIX.PAL"):
		return "DYNAMIX.PAL"
	if palettes.has("GAME.PAL"):
		return "GAME.PAL"
	return String(palettes.keys()[0]) if not palettes.is_empty() else ""
