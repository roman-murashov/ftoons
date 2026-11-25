extends RefCounted

## Win16 1130:06FF loads CLU colours. The 32-bit 1128:0246 dispatcher
## decodes PAK runs through the jump table at DS:2F44.
const MAX_LOOP_DEPTH := 12
const MAX_FRAME_PIXELS := 16777216

static func decode_palette(data: PackedByteArray) -> Dictionary:
	if data.size() < 8:
		return {"ok": false, "error": "Windows CLU header is truncated"}
	var count := _big_u16(data, 6) + 1
	if count > 256 or data.size() < 8 + count * 8:
		return {"ok": false, "error": "Windows CLU colour table is truncated or invalid"}
	var colors: Array[Color] = []
	for index in count:
		var offset := 8 + index * 8
		colors.append(Color8(data[offset + 2], data[offset + 4], data[offset + 6]))
	return {"ok": true, "colors": colors}

static func decode_pak(data: PackedByteArray, track_coverage: bool = false) -> Dictionary:
	if data.size() < 6 or data.decode_u16(0) != 2:
		return {"ok": false, "error": "Unsupported or truncated Windows PAK header"}
	var count := data.decode_u16(2)
	var transparent := data.decode_u16(4)
	# MPC intro archives leave this field uninitialized. Their renderer uses
	# skip commands, not a palette colour key, for transparency.
	if track_coverage: transparent = 0
	var header_size := 6 + count * 4
	if count == 0 or transparent > 255 or data.size() < header_size:
		return {"ok": false, "error": "Invalid Windows PAK frame table"}
	var frames: Array[Dictionary] = []
	for index in count:
		var start := data.decode_u32(6 + index * 4)
		var end := data.decode_u32(10 + index * 4) if index + 1 < count else data.size()
		if start < header_size or end > data.size() or start + 4 > end:
			return {"ok": false, "error": "Windows PAK frame %d has an invalid range" % index}
		var width := _big_u16(data, start)
		var height := _big_u16(data, start + 2)
		if width == 65535 and height == 65535:
			frames.append({})
			continue
		if width == 0 or height == 0 or width * height > MAX_FRAME_PIXELS:
			return {"ok": false, "error": "Windows PAK frame %d has invalid dimensions" % index}
		var frame := _decode_frame(data, start + 4, end, width, height, transparent, track_coverage)
		if not frame.ok:
			return {"ok": false, "error": "Windows PAK frame %d: %s" % [index, frame.error]}
		frames.append(frame)
	return {"ok": true, "frames": frames, "transparent_index": transparent}

static func _decode_frame(data: PackedByteArray, start: int, end: int, width: int, height: int, transparent: int, track_coverage: bool = false) -> Dictionary:
	var pixels := PackedByteArray()
	pixels.resize(width * height)
	pixels.fill(transparent)
	var coverage := PackedByteArray()
	if track_coverage: coverage.resize(pixels.size())
	var cursor := start
	var x := 0
	var y := 0
	var loops: Array[Vector2i] = []
	# The encoder's loop depth is twelve. This also bounds malformed loops
	# whose bodies never write a pixel or reach a terminator.
	var budget := (end - start + pixels.size()) * 32
	while cursor < end and budget > 0:
		budget -= 1
		var command := data[cursor]
		cursor += 1
		var operation := command >> 5
		var count := command & 31
		if count == 0:
			if cursor + 2 > end:
				return {"ok": false, "error": "Truncated extended run length"}
			count = _big_u16(data, cursor)
			cursor += 2
		if operation >= 4:
			y += 1
			x = 0
		match operation & 3:
			0:
				if count > 1:
					if loops.size() >= MAX_LOOP_DEPTH:
						return {"ok": false, "error": "Nested scanline repeats exceed the native limit"}
					loops.append(Vector2i(cursor, count))
				else:
					if loops.is_empty():
						return {"ok": false, "error": "Scanline repeat has no matching start"}
					var loop := loops.pop_back() as Vector2i
					loop.y -= 1
					if loop.y > 0:
						loops.append(loop)
						cursor = loop.x
			1:
				x += count
			2:
				if count <= 1:
					return {"ok": true, "width": width, "height": height, "pixels": pixels, "coverage": coverage}
				if cursor >= end:
					return {"ok": false, "error": "Missing repeat colour"}
				if y >= height or x + count > width:
					return {"ok": false, "error": "Repeat writes outside the frame"}
				var color := data[cursor]
				cursor += 1
				var position := y * width + x
				for pixel in count:
					pixels[position + pixel] = color
					if track_coverage: coverage[position + pixel] = 255
				x += count
			3:
				if cursor + count > end:
					return {"ok": false, "error": "Literal run exceeds the frame stream"}
				if y >= height or x + count > width:
					return {"ok": false, "error": "Literal run writes outside the frame"}
				var position := y * width + x
				for pixel in count:
					pixels[position + pixel] = data[cursor + pixel]
					if track_coverage: coverage[position + pixel] = 255
				cursor += count
				x += count
	return {"ok": false, "error": "Windows PAK frame has no terminator within its bounds"}

static func _big_u16(data: PackedByteArray, offset: int) -> int:
	return (int(data[offset]) << 8) | int(data[offset + 1])
