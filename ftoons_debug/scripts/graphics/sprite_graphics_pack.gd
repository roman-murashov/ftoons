extends RefCounted

signal changed

const Formats = preload("res://scripts/graphics/dynamix_formats.gd")
const WindowsFormats = preload("res://scripts/graphics/windows_graphics_formats.gd")
const PACK_FOLDER := "res://dlc_win_data/graphics"
const BINARY_INDEX := PACK_FOLDER + "/binary/resource_index.json"

var palette: Array
var alternate_enabled := false
var load_error := ""
var fallback_sheets: Dictionary = {}
var _catalog: ResourceCatalog
var _sheets: Dictionary = {}
var _originals: Dictionary[ImageTexture, Image] = {}
var _alternates: Dictionary[ImageTexture, Image] = {}
var _pack_loaded := false
var _binary_entries: Dictionary = {}
var _windows_palette: Array = []
var _png_folders: Dictionary = {}
var _native_windows_sheets: Dictionary = {}

## Windows-only UI has no DOS frame mapping. Decode verified binaries directly,
## using encoded run coverage for alpha. Keep these outside the graphics toggle.
func windows_ui_frames(sheet: String) -> Array[Texture2D]:
	if _native_windows_sheets.has(sheet): return _native_windows_sheets[sheet]
	if _binary_entries.is_empty(): _load_binary_index()
	var textures: Array[Texture2D]=[]
	if not _binary_entries.has(sheet) or _windows_palette.is_empty():
		load_error="Missing Windows UI resource: "+sheet
		return textures
	var decoded:=WindowsFormats.decode_pak(_read_binary(_binary_entries[sheet]),true)
	if not decoded.ok:
		load_error=decoded.error
		return textures
	for frame: Dictionary in decoded.frames:
		if frame.is_empty():
			textures.append(null)
			continue
		var image:=Formats.frame_to_image(frame,_windows_palette,-1)
		for y in int(frame.height):
			for x in int(frame.width):
				var color:=image.get_pixel(x,y)
				color.a=float(frame.coverage[y*int(frame.width)+x])/255.0
				image.set_pixel(x,y,color)
		textures.append(ImageTexture.create_from_image(image))
	_native_windows_sheets[sheet]=textures
	return textures

func _init(catalog: ResourceCatalog) -> void:
	_catalog = catalog
	palette = Formats.decode_palette(catalog.read_asset("GAME.PAL")).get("colors", [])

func frames(sheet: String, decoded: Dictionary = {}) -> Array[Texture2D]:
	if _sheets.has(sheet):
		return _sheets[sheet]
	if decoded.is_empty():
		decoded = Formats.decode_bmp(_catalog.read_asset(sheet))
	var textures: Array[Texture2D] = []
	for frame in decoded.get("frames", []):
		var image := Formats.frame_to_image(frame, palette, 0)
		textures.append(ImageTexture.create_from_image(image))
	_sheets[sheet] = textures
	if _pack_loaded:
		_load_sheet_alternates(sheet, textures)
		if alternate_enabled:
			for texture: ImageTexture in textures:
				if _alternates.has(texture):
					texture.update(_alternates[texture])
	return textures

func set_alternate_enabled(enabled: bool) -> bool:
	if alternate_enabled == enabled:
		return alternate_enabled
	if enabled and _alternates.is_empty():
		_load_alternates()
		if _alternates.is_empty():
			return false
	var images := _alternates if enabled else _originals
	# Keep texture references held by the canvas, cursor, and dialogs valid.
	for texture: ImageTexture in images:
		texture.update(images[texture])
	alternate_enabled = enabled
	changed.emit()
	return alternate_enabled

func replacement_count() -> int:
	return _alternates.size()

func _load_alternates() -> void:
	_load_binary_index()
	# Mounted ZIP entries are readable with FileAccess even when DirAccess
	# only lists the physical project directories.
	if DirAccess.dir_exists_absolute(PACK_FOLDER):
		for folder in DirAccess.get_directories_at(PACK_FOLDER):
			_png_folders[folder.to_upper() + ".BMP"] = PACK_FOLDER.path_join(folder)
	_pack_loaded = true
	for sheet: String in _sheets:
		_load_sheet_alternates(sheet, _sheets[sheet])

func _load_binary_index() -> void:
	if not FileAccess.file_exists(BINARY_INDEX):
		load_error = "Windows binary graphics index is missing or unreadable: " + ProjectSettings.globalize_path(BINARY_INDEX)
		return
	var index = JSON.parse_string(FileAccess.get_file_as_string(BINARY_INDEX))
	if not index is Dictionary or index.get("format") != "windows-ne-graphics-pack-v1" or not index.get("entries") is Array:
		load_error = "Windows binary graphics index is invalid."
		return
	var colors: Dictionary = {}
	for entry in index.entries:
		if not entry is Dictionary:
			continue
		if entry.get("type") == "PAK":
			_binary_entries[String(entry.get("name", "")) + ".BMP"] = entry
		elif entry.get("type") == "CLU" and entry.get("name") == "TOON_PAL":
			colors = entry
	if colors.is_empty():
		load_error = "Windows TOON_PAL resource is missing."
		return
	var decoded := WindowsFormats.decode_palette(_read_binary(colors))
	if not decoded.ok:
		load_error = decoded.error
		return
	_windows_palette = decoded.colors
	load_error = ""

func _read_binary(entry: Dictionary) -> PackedByteArray:
	var path := String(entry.get("asset_path", ""))
	if not path.begins_with(PACK_FOLDER + "/binary/") or path.simplify_path() != path or not FileAccess.file_exists(path):
		load_error = "Missing or invalid Windows graphics path."
		return PackedByteArray()
	var bytes := FileAccess.get_file_as_bytes(path)
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(bytes)
	if bytes.size() != int(entry.get("byte_length", -1)) or digest.finish().hex_encode() != entry.get("sha256"):
		load_error = "Windows graphics resource failed verification: " + path.get_file()
		return PackedByteArray()
	return bytes

func _load_sheet_alternates(sheet: String, textures: Array) -> void:
	if _binary_entries.has(sheet) and not _windows_palette.is_empty():
		var decoded := WindowsFormats.decode_pak(_read_binary(_binary_entries[sheet]))
		if decoded.ok:
			var images: Array = decoded.frames
			# Some archives append non-drawing FFFF slots after the real frames.
			while not images.is_empty() and images.back().is_empty():
				images.pop_back()
			if images.size() == textures.size():
				for index in images.size():
					var frame: Dictionary = images[index]
					if frame.is_empty() or Vector2i(frame.width, frame.height) != Vector2i(textures[index].get_size()):
						fallback_sheets[sheet] = "Frames with changed dimensions use DOS graphics."
						continue
					_replace_frame(textures[index], Formats.frame_to_image(frame, _windows_palette, decoded.transparent_index))
			else:
				fallback_sheets[sheet] = "Changed frame counts need a verified frame mapping."
		else:
			fallback_sheets[sheet] = decoded.error
	if not _png_folders.has(sheet):
		return
	var path: String = _png_folders[sheet]
	for filename in DirAccess.get_files_at(path):
		var stem := filename.get_basename()
		if filename.get_extension().to_lower() != "png" or not stem.is_valid_int():
			continue
		var index := int(stem)
		if index < 0 or index >= textures.size() or stem != str(index):
			continue
		var image := Image.new()
		if image.load_png_from_buffer(FileAccess.get_file_as_bytes(path.path_join(filename))) != OK:
			continue
		if image.get_size() != Vector2i(textures[index].get_size()):
			continue
		image.convert(Image.FORMAT_RGBA8)
		_replace_frame(textures[index], image)

func _replace_frame(texture: ImageTexture, image: Image) -> void:
	if not _originals.has(texture):
		_originals[texture] = texture.get_image()
	_alternates[texture] = image
