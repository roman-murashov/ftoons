class_name DynamixFormats
extends RefCounted

## Readers for the Sierra/Dynamix chunk, palette, SCR, and TIM-style BMP data.
## These readers return dictionaries with an explicit `ok` flag and preserve
## malformed input as an error instead of silently producing a blank image.

static func parse_chunks(data: PackedByteArray) -> Dictionary:
	var chunks: Array = []
	var cursor := 0
	while cursor < data.size():
		if cursor + 8 > data.size():
			return {"ok": false, "error": "truncated chunk header at 0x%X" % cursor, "chunks": chunks}
		var type := data.slice(cursor, cursor + 4).get_string_from_ascii()
		var stored_length := _u32(data, cursor + 4)
		var length := stored_length & 0x7fffffff
		var payload_start := cursor + 8
		if payload_start + length > data.size():
			return {"ok": false, "error": "chunk %s exceeds payload at 0x%X" % [type, cursor], "chunks": chunks}
		chunks.append({
			"type": type,
			"length": length,
			"container": (stored_length & 0x80000000) != 0,
			"offset": cursor,
			"payload": data.slice(payload_start, payload_start + length),
		})
		cursor = payload_start + length
	return {"ok": true, "chunks": chunks}

static func decode_ttm(data: PackedByteArray) -> Dictionary:
	# 2F9C:0BBA/0D7A: a TT3 compressed word stream, not an image sequence.
	var outer:=parse_chunks(data)
	if not outer.ok: return outer
	var script: Dictionary=_find_chunk(outer.chunks,"TT3:")
	if script.is_empty(): return {"ok":false,"error":"TTM has no TT3: script"}
	var decoded:=_decode_bin(script.payload)
	if not decoded.ok: return decoded
	var bytes: PackedByteArray=decoded.bytes
	var cursor:=0
	var commands: Array=[]
	while cursor<bytes.size():
		if cursor+2>bytes.size(): return {"ok":false,"error":"truncated TTM opcode"}
		var start:=cursor
		var opcode:=_u16(bytes,cursor)
		cursor+=2
		if opcode==0: break # Original loader also appends a zero sentinel.
		var count:=opcode&15
		var args: Variant=[]
		if count==15:
			var end:=cursor
			while end<bytes.size() and bytes[end]!=0: end+=1
			if end>=bytes.size(): return {"ok":false,"error":"unterminated TTM string"}
			args=bytes.slice(cursor,end).get_string_from_ascii()
			cursor=(end+2)&~1
		else:
			if cursor+count*2>bytes.size(): return {"ok":false,"error":"truncated TTM arguments"}
			for i in count:
				var value:=_u16(bytes,cursor)
				args.append(value-65536 if value>=32768 else value)
				cursor+=2
		if cursor>bytes.size(): return {"ok":false,"error":"truncated TTM alignment"}
		commands.append({"offset":start,"opcode":opcode,"args":args})
	return {"ok":true,"commands":commands,"bytes":bytes}

static func decode_font(data: PackedByteArray) -> Dictionary:
	# 1EA3:6946: FF proportional one-bit font, followed by a compressed
	# offset/advance/bitmap block. TUXEDO.FNT is used by Message Machines.
	var outer:=parse_chunks(data)
	if not outer.ok or outer.chunks.size()!=1 or outer.chunks[0].type!="FNT:":
		return {"ok":false,"error":"expected one FNT: chunk"}
	var payload: PackedByteArray=outer.chunks[0].payload
	if payload.size()<13 or payload[0]!=0xff:
		return {"ok":false,"error":"unsupported or truncated proportional font"}
	var height:=int(payload[2])
	var first:=int(payload[4])
	var count:=int(payload[5])
	var unpacked:=_decode_bin(payload.slice(8))
	if not unpacked.ok: return unpacked
	var block: PackedByteArray=unpacked.bytes
	if height==0 or count==0 or block.size()!=_u16(payload,6) or block.size()<count*3:
		return {"ok":false,"error":"invalid font metrics/block size"}
	var glyphs: Dictionary={}
	for index in count:
		var width:=int(block[count*2+index])
		var start:=count*3+_u16(block,index*2)
		var stride: int=(width+7)/8
		if start+height*stride>block.size():
			return {"ok":false,"error":"font glyph exceeds bitmap block"}
		var mask:=PackedByteArray()
		mask.resize(width*height)
		for y in height:
			for x in width:
				mask[y*width+x]=1 if block[start+y*stride+x/8]&(128>>(x%8)) else 0
		glyphs[first+index]={"width":width,"height":height,"pixels":mask}
	return {"ok":true,"height":height,"first":first,"count":count,"glyphs":glyphs}

static func decode_palette(data: PackedByteArray) -> Dictionary:
	var outer := parse_chunks(data)
	if not outer.ok or outer.chunks.is_empty():
		return {"ok": false, "error": outer.get("error", "empty palette")}
	var pal: Dictionary = outer.chunks[0]
	if pal.type != "PAL:":
		return {"ok": false, "error": "expected PAL: root"}
	var inner := parse_chunks(pal.payload)
	if not inner.ok:
		return {"ok": false, "error": inner.error}
	var vga: Dictionary = _find_chunk(inner.chunks, "VGA:")
	if vga.is_empty() or vga.payload.size() < 768:
		return {"ok": false, "error": "palette has no complete 256-entry VGA block"}
	var colors: Array[Color] = []
	for index in range(256):
		var base := index * 3
		colors.append(Color(
			float(vga.payload[base]) / 63.0,
			float(vga.payload[base + 1]) / 63.0,
			float(vga.payload[base + 2]) / 63.0,
			1.0
		))
	return {"ok": true, "kind": "palette", "colors": colors, "vga_bytes": vga.payload.size(), "chunks": inner.chunks}

static func decode_bmp(data: PackedByteArray) -> Dictionary:
	if data.size() < 4 or data.slice(0, 4).get_string_from_ascii() != "BMP:":
		return {"ok": false, "error": "payload does not begin with BMP:; preserved as non-image evidence"}
	var outer := parse_chunks(data)
	if not outer.ok or outer.chunks.is_empty():
		return {"ok": false, "error": outer.get("error", "empty BMP")}
	var bmp: Dictionary = outer.chunks[0]
	if bmp.type != "BMP:":
		return {"ok": false, "error": "expected BMP: root"}
	var inner := parse_chunks(bmp.payload)
	if not inner.ok:
		return {"ok": false, "error": inner.error}
	var inf: Dictionary = _find_chunk(inner.chunks, "INF:")
	if inf.is_empty():
		return {"ok": false, "error": "BMP has no INF: frame metadata"}
	var info := _read_frame_info(inf.payload)
	if not info.ok:
		return info
	var scn: Dictionary = _find_chunk(inner.chunks, "SCN:")
	var frames: Array = []
	if not scn.is_empty():
		var off: Dictionary = _find_chunk(inner.chunks, "OFF:")
		if off.is_empty():
			return {"ok": false, "error": "SCN: image has no OFF: index"}
		var offsets := _read_offsets(off.payload, int(info.count))
		if not offsets.ok:
			return offsets
		var decoded_frames: Dictionary = _decode_scn_frames(scn.payload, offsets.offsets, info.widths, info.heights)
		if not decoded_frames.ok:
			return decoded_frames
		frames = decoded_frames.frames
	else:
		var bin: Dictionary = _find_chunk(inner.chunks, "BIN:")
		if bin.is_empty():
			return {"ok": false, "error": "BMP has neither SCN/OFF nor BIN"}
		var unpacked := _decode_bin(bin.payload)
		if not unpacked.ok:
			return unpacked
		var split_frames: Dictionary = _split_packed_frames(unpacked.bytes, info.widths, info.heights)
		if not split_frames.ok:
			return split_frames
		frames = split_frames.frames
	return {"ok": true, "kind": "bmp", "widths": info.widths, "heights": info.heights, "frames": frames, "chunks": inner.chunks}

static func decode_scr(data: PackedByteArray) -> Dictionary:
	var outer := parse_chunks(data)
	if not outer.ok or outer.chunks.is_empty():
		return {"ok": false, "error": outer.get("error", "empty SCR")}
	var scr: Dictionary = outer.chunks[0]
	if scr.type != "SCR:":
		return {"ok": false, "error": "expected SCR: root"}
	var inner := parse_chunks(scr.payload)
	if not inner.ok:
		return {"ok": false, "error": inner.error}
	var dim: Dictionary = _find_chunk(inner.chunks, "DIM:")
	var bin: Dictionary = _find_chunk(inner.chunks, "BIN:")
	if dim.is_empty() or bin.is_empty() or dim.payload.size() < 4:
		return {"ok": false, "error": "SCR requires DIM: and BIN: chunks"}
	var width := _u16(dim.payload, 0)
	var height := _u16(dim.payload, 2)
	var unpacked := _decode_bin(bin.payload)
	if not unpacked.ok:
		return unpacked
	var pixels := _unpack_4bpp(unpacked.bytes, width * height)
	if pixels.size() != width * height:
		return {"ok": false, "error": "SCR decoded pixel count does not match DIM"}
	return {"ok": true, "kind": "scr", "width": width, "height": height, "pixels": pixels, "compression": unpacked.algorithm, "chunks": inner.chunks}

static func frame_to_image(frame: Dictionary, palette: Array, transparent_index: int = -1) -> Image:
	var width := int(frame.width)
	var height := int(frame.height)
	var pixels: PackedByteArray = frame.pixels
	var image := Image.create(width, height, false, Image.FORMAT_RGBA8)
	for y in range(height):
		for x in range(width):
			var index := int(pixels[y * width + x])
			var color := Color(1.0, 0.0, 1.0, 1.0)
			if index >= 0 and index < palette.size():
				color = palette[index]
			if index == transparent_index:
				color.a = 0.0
			image.set_pixel(x, y, color)
	return image

static func scr_to_image(scr: Dictionary, palette: Array) -> Image:
	return frame_to_image({"width": scr.width, "height": scr.height, "pixels": scr.pixels}, palette)

static func _read_frame_info(payload: PackedByteArray) -> Dictionary:
	if payload.size() < 2:
		return {"ok": false, "error": "INF: is truncated"}
	var count := _u16(payload, 0)
	if count <= 0 or payload.size() < 2 + count * 4:
		return {"ok": false, "error": "INF: frame arrays are truncated"}
	var widths: Array[int] = []
	var heights: Array[int] = []
	for index in range(count):
		widths.append(_u16(payload, 2 + index * 2))
	for index in range(count):
		heights.append(_u16(payload, 2 + count * 2 + index * 2))
	return {"ok": true, "count": count, "widths": widths, "heights": heights}

static func _read_offsets(payload: PackedByteArray, count: int) -> Dictionary:
	if payload.size() < count * 4:
		return {"ok": false, "error": "OFF: index is truncated"}
	var offsets: Array[int] = []
	for index in range(count):
		offsets.append(_u32(payload, index * 4))
	return {"ok": true, "offsets": offsets}

static func _decode_scn_frames(data: PackedByteArray, offsets: Array, widths: Array, heights: Array) -> Dictionary:
	var frames: Array = []
	for index in range(offsets.size()):
		var start := int(offsets[index])
		var end := data.size() if index + 1 == offsets.size() else int(offsets[index + 1])
		if start < 0 or start >= end or end > data.size():
			return {"ok": false, "error": "SCN/OFF frame range is invalid at index %d" % index}
		var frame := _decode_scn_frame(data, start, end, int(widths[index]), int(heights[index]))
		if not frame.ok:
			return frame
		frames.append(frame.frame)
	return {"ok": true, "frames": frames}

static func _decode_scn_frame(data: PackedByteArray, start: int, end: int, width: int, height: int) -> Dictionary:
	if start >= end:
		return {"ok": false, "error": "empty SCN frame"}
	var add_value := int(data[start])
	var pixels := PackedByteArray()
	pixels.resize(width * height)
	var cursor := start + 1
	var position := 0
	var terminated := false
	while cursor < end:
		var command_byte := int(data[cursor])
		cursor += 1
		var command := command_byte >> 6
		var value := command_byte & 0x3f
		if command == 0:
			if cursor < end and (int(data[cursor]) >> 6) == 0 and (int(data[cursor]) & 0x3f) != 0:
				value |= (int(data[cursor]) & 0x3f) << 6
				cursor += 1
			position += width - value
		elif command == 1:
			if value == 0:
				terminated = true
				break
			position += value
		elif command == 2:
			if cursor >= end:
				return {"ok": false, "error": "SCN repeat command has no value"}
			var pixel := int(data[cursor]) & 0x0f
			cursor += 1
			pixel = pixel if add_value == 0xff else mini(255, add_value + pixel)
			for repeat_index in range(value):
				if position + repeat_index >= 0 and position + repeat_index < pixels.size():
					pixels[position + repeat_index] = pixel
			position += value
		else:
			var byte_count := (value + 1) / 2
			if cursor + byte_count > end:
				return {"ok": false, "error": "SCN copy command exceeds frame"}
			for copy_index in range(value):
				var packed := int(data[cursor + copy_index / 2])
				var pixel := (packed >> 4) & 0x0f if copy_index % 2 == 0 else packed & 0x0f
				pixel = pixel if add_value == 0xff else mini(255, add_value + pixel)
				if position + copy_index >= 0 and position + copy_index < pixels.size():
					pixels[position + copy_index] = pixel
			cursor += byte_count
			position += value
	if not terminated:
		return {"ok": false, "error": "SCN frame has no 0x40 terminator"}
	return {"ok": true, "frame": {"width": width, "height": height, "pixels": pixels, "add_value": add_value}}

static func _split_packed_frames(data: PackedByteArray, widths: Array, heights: Array) -> Dictionary:
	var frames: Array = []
	var cursor := 0
	for index in range(widths.size()):
		var pixel_count := int(widths[index]) * int(heights[index])
		var byte_count := (pixel_count + 1) / 2
		if cursor + byte_count > data.size():
			return {"ok": false, "error": "BIN image data ends before frame %d" % index}
		frames.append({
			"width": int(widths[index]),
			"height": int(heights[index]),
			"pixels": _unpack_4bpp(data.slice(cursor, cursor + byte_count), pixel_count),
			"add_value": 0,
		})
		cursor += byte_count
	if cursor != data.size():
		return {"ok": false, "error": "BIN image has %d trailing bytes" % (data.size() - cursor)}
	return {"ok": true, "frames": frames}

static func _unpack_4bpp(data: PackedByteArray, pixel_count: int) -> PackedByteArray:
	var pixels := PackedByteArray()
	pixels.resize(pixel_count)
	for index in range(pixel_count):
		var packed := int(data[index / 2])
		pixels[index] = (packed >> 4) & 0x0f if index % 2 == 0 else packed & 0x0f
	return pixels

static func _decode_bin(payload: PackedByteArray) -> Dictionary:
	if payload.size() < 5:
		return {"ok": false, "error": "BIN: compression header is truncated"}
	var algorithm := int(payload[0])
	var expected := _u32(payload, 1)
	var encoded := payload.slice(5)
	var bytes := PackedByteArray()
	if algorithm == 0:
		bytes = encoded.slice(0, mini(expected, encoded.size()))
	elif algorithm == 1:
		bytes = _decode_rle(encoded, expected)
	elif algorithm == 2:
		bytes = _decode_lzw(encoded, expected)
	else:
		return {"ok": false, "error": "unsupported BIN compression method %d" % algorithm, "algorithm": algorithm}
	if bytes.size() != expected:
		return {"ok": false, "error": "BIN decompressed %d bytes, expected %d" % [bytes.size(), expected], "algorithm": algorithm}
	return {"ok": true, "bytes": bytes, "algorithm": algorithm}

static func _decode_rle(encoded: PackedByteArray, expected: int) -> PackedByteArray:
	var output := PackedByteArray()
	var cursor := 0
	while cursor < encoded.size() and output.size() < expected:
		var code := int(encoded[cursor])
		cursor += 1
		var count := code & 0x7f
		if (code & 0x80) != 0:
			if cursor >= encoded.size():
				break
			var value := encoded[cursor]
			cursor += 1
			for _index in range(count):
				output.append(value)
		else:
			for _index in range(count):
				if cursor >= encoded.size():
					break
				output.append(encoded[cursor])
				cursor += 1
	return output.slice(0, mini(expected, output.size()))

static func _decode_lzw(encoded: PackedByteArray, expected: int) -> PackedByteArray:
	var dictionary: Array = []
	for index in range(256):
		dictionary.append(PackedByteArray([index]))
	dictionary.append(PackedByteArray())
	var next_code := 257
	var code_width := 9
	var bit_position := 0
	var code_count := 0
	var previous := PackedByteArray()
	var has_previous := false
	var output := PackedByteArray()
	while output.size() < expected:
		var code_result := _read_bits(encoded, bit_position, code_width)
		if not code_result.ok:
			break
		bit_position = code_result.next_bit
		var code := int(code_result.value)
		code_count += 1
		if code == 256:
			var old_width := code_width
			while code_count % 8 != 0:
				var ignored := _read_bits(encoded, bit_position, old_width)
				if not ignored.ok:
					return output
				bit_position = ignored.next_bit
				code_count += 1
			dictionary.clear()
			for index in range(256):
				dictionary.append(PackedByteArray([index]))
			dictionary.append(PackedByteArray())
			next_code = 257
			code_width = 9
			has_previous = false
			previous = PackedByteArray()
			continue
		var entry := PackedByteArray()
		if code >= 0 and code < dictionary.size() and not dictionary[code].is_empty():
			entry = dictionary[code]
		elif has_previous and code == next_code:
			entry = previous.duplicate()
			entry.append(previous[0])
		else:
			return output
		for value in entry:
			output.append(value)
		if has_previous:
			var added := previous.duplicate()
			added.append(entry[0])
			if next_code == dictionary.size():
				dictionary.append(added)
			elif next_code < dictionary.size():
				dictionary[next_code] = added
			next_code += 1
			if next_code >= (1 << code_width) and code_width < 12:
				code_width += 1
		previous = entry
		has_previous = true
	return output.slice(0, mini(expected, output.size()))

static func _read_bits(data: PackedByteArray, bit_position: int, width: int) -> Dictionary:
	if bit_position + width > data.size() * 8:
		return {"ok": false}
	var value := 0
	for index in range(width):
		var source_bit := bit_position + index
		value |= ((int(data[source_bit / 8]) >> (source_bit & 7)) & 1) << index
	return {"ok": true, "value": value, "next_bit": bit_position + width}

static func _find_chunk(chunks: Array, type: String) -> Dictionary:
	for chunk in chunks:
		if String(chunk.type) == type:
			return chunk
	return {}

static func _u16(data: PackedByteArray, offset: int) -> int:
	return int(data[offset]) | (int(data[offset + 1]) << 8)

static func _u32(data: PackedByteArray, offset: int) -> int:
	return int(data[offset]) | (int(data[offset + 1]) << 8) | (int(data[offset + 2]) << 16) | (int(data[offset + 3]) << 24)
