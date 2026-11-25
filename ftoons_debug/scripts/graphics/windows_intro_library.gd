extends RefCounted
## Native MPC intro timelines (NE segments 42, 45 and 46).
const Formats = preload("res://scripts/graphics/windows_graphics_formats.gd")
const ROOT := "res://dlc_win_data/intros/"
var error := ""
var manifest: Dictionary = {}
var sheets: Dictionary = {}
var palettes: Dictionary = {}
var cycles: Array[int] = [0, 0, 0]

func load_index() -> bool:
	if not manifest.is_empty(): return true
	var path := ROOT + "intro_index.json"
	var value = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	if not value is Dictionary or value.get("format") != "windows-level-intros-v1":
		error = "Windows intro index is missing or unreadable: " + ProjectSettings.globalize_path(path)
		return false
	manifest = value
	return true

func resource_bytes(key: String) -> PackedByteArray:
	if not load_index(): return PackedByteArray()
	var entry: Dictionary = manifest.resources.get(key, {})
	var path := String(entry.get("path", ""))
	if not path.begins_with(ROOT + "binary/") or path.simplify_path() != path or not FileAccess.file_exists(path):
		error = "Missing or unreadable intro resource: " + key
		return PackedByteArray()
	var data := FileAccess.get_file_as_bytes(path)
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(data)
	if data.size() != int(entry.size) or hash.finish().hex_encode() != entry.sha256:
		error = "Intro resource verification failed: " + key
		return PackedByteArray()
	return data

func palette(key: String = "TOONRSRC/CLU/TOON_PAL") -> Array:
	if palettes.has(key): return palettes[key]
	var result := Formats.decode_palette(resource_bytes(key))
	if not result.ok:
		error = result.error
		return []
	palettes[key] = result.colors
	return result.colors

func sheet(id: int) -> Array:
	if sheets.has(id): return sheets[id]
	var colors := palette()
	if colors.is_empty(): return []
	var decoded := Formats.decode_pak(resource_bytes("INTROS/PAK/%d" % id), true)
	if not decoded.ok:
		error = decoded.error
		return []
	var images: Array[Image] = []
	for frame in decoded.frames:
		if frame.is_empty():
			images.append(null)
			continue
		images.append(frame_image(frame, colors))
	sheets[id] = images
	return images

static func frame_image(frame: Dictionary, colors: Array) -> Image:
	var rgba := PackedByteArray()
	rgba.resize(frame.pixels.size() * 4)
	for i in frame.pixels.size():
		var color: Color = colors[frame.pixels[i]]
		rgba[i*4] = roundi(color.r*255)
		rgba[i*4+1] = roundi(color.g*255)
		rgba[i*4+2] = roundi(color.b*255)
		rgba[i*4+3] = frame.coverage[i]
	return Image.create_from_data(frame.width, frame.height, false, Image.FORMAT_RGBA8, rgba)

func timeline(level: String) -> Array[Dictionary]:
	error = ""
	var sequence: Array[Dictionary] = []
	if not load_index(): return sequence
	var lines: Array = manifest.levels.get(level.get_file().to_upper(), [])
	if lines.is_empty(): return sequence
	var speakers := 0
	for id in lines: speakers |= int(id) / 1000
	var group := speakers - 1
	if group < 0 or group > 2:
		error = "Invalid intro speaker group"
		return sequence
	cycles[group] = (cycles[group] + 1) % 3
	var variant := group * 3 + cycles[group]
	sequence.append(clip(100 + 10*variant, 100 + 10*variant, Vector2i.ZERO, "entrance"))
	for id in lines:
		var speaker := int(id) / 1000 - 1
		var xy: Array = manifest.mouth_origins[variant][speaker]
		sequence.append(clip(int(id), 200 + 10*variant + speaker, Vector2i(xy[0], xy[1]), "speech"))
	sequence.append(clip(101 + 10*variant, 101 + 10*variant, Vector2i.ZERO, "exit"))
	if sequence.any(func(item: Dictionary): return item.is_empty()): return []
	return sequence

func clip(id: int, sheet_id: int, origin: Vector2i, kind: String) -> Dictionary:
	if not manifest.clips.has(str(id)):
		error = "Missing intro clip %d" % id
		return {}
	var result: Dictionary = manifest.clips[str(id)].duplicate(true)
	result.id = id
	result.sheet = sheet_id
	result.kind = kind
	result.position = origin
	result.images = sheet(sheet_id)
	if result.images.is_empty(): return {}
	var positions: Array[Vector2i] = []
	var image_key := "INTROS/IMG/%d" % sheet_id
	if manifest.resources.has(image_key):
		var offsets := resource_bytes(image_key)
		if offsets.size() < result.images.size()*12:
			error = "Truncated intro image offsets"
			return {}
		for i in result.images.size(): positions.append(Vector2i(offsets.decode_s16(12*i), offsets.decode_s16(12*i+2)))
	else:
		positions.resize(result.images.size())
		positions.fill(Vector2i.ZERO)
	result.positions = positions
	result.wave = resource_bytes("INTROS/WAVE/%d" % id)
	if result.wave.is_empty(): return {}
	result.audio = wave_stream(result.wave)
	if result.audio == null: return {}
	return result

func wave_stream(data: PackedByteArray) -> AudioStreamWAV:
	if data.size() < 12 or data.slice(0,4).get_string_from_ascii() != "RIFF" or data.slice(8,12).get_string_from_ascii() != "WAVE":
		error = "Invalid intro WAVE header"
		return null
	var rate := 0
	var bits := 0
	var channels := 0
	var pcm := PackedByteArray()
	var end := mini(data.size(), int(data.decode_u32(4)) + 8)
	var cursor := 12
	while cursor + 8 <= end:
		var tag := data.slice(cursor,cursor+4).get_string_from_ascii()
		var length := int(data.decode_u32(cursor+4))
		cursor += 8
		if cursor + length > end:
			error = "Truncated intro WAVE chunk"
			return null
		if tag == "fmt " and length >= 16:
			if data.decode_u16(cursor) != 1:
				error = "Unsupported intro WAVE encoding"
				return null
			channels = data.decode_u16(cursor+2)
			rate = data.decode_u32(cursor+4)
			bits = data.decode_u16(cursor+14)
		elif tag == "data": pcm = data.slice(cursor,cursor+length)
		cursor += length + (length & 1)
	if rate <= 0 or not channels in [1,2] or not bits in [8,16] or pcm.is_empty():
		error = "Invalid intro WAVE format or samples"
		return null
	if bits == 8:
		for i in pcm.size(): pcm[i] ^= 128 # RIFF unsigned -> Godot signed PCM.
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_8_BITS if bits == 8 else AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.stereo = channels == 2
	stream.data = pcm
	return stream

func compose(item: Dictionary, tick: int, background: Image, previous_tick: int = -1) -> Image:
	var output := background.duplicate() as Image
	# Native playback samples at the MUV step, in 600-Hz time units.
	tick = mini(tick, int(item.duration)-1)
	tick = (tick / maxi(1, int(item.step))) * maxi(1, int(item.step))
	# Segment45:040C first restores the previous frame's full damage rectangle
	# from the pre-entrance screen, then draws the new frame. The overlay is
	# transparent in restored regions so the original level remains visible.
	if previous_tick >= 0:
		for command in item.commands:
			if int(command.start) > previous_tick: break
			if previous_tick >= int(command.start)+int(command.duration) or not int(command.op) in [4,5,6]: continue
			var index := int(command.frame)
			if index >= item.images.size() or item.images[index] == null: continue
			var point := command_position(item,command)
			var rectangle := Rect2i(point,item.images[index].get_size()).intersection(Rect2i(0,0,640,400))
			if rectangle.has_area(): output.fill_rect(rectangle,Color.TRANSPARENT)
	for command in item.commands:
		if int(command.start) > tick: break
		if tick >= int(command.start) + int(command.duration): continue
		if not int(command.op) in [4, 5, 6]: continue
		var index := int(command.frame)
		if index >= item.images.size() or item.images[index] == null: continue
		var image: Image = item.images[index]
		var point := command_position(item,command)
		output.blend_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), point)
	return output

func command_position(item: Dictionary, command: Dictionary) -> Vector2i:
	var point: Vector2i = item.position + item.positions[int(command.frame)]
	if int(command.op) in [5,6]: point += Vector2i(command.x,command.y)
	return point + Vector2i(item.origin[0],item.origin[1])
