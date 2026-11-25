extends RefCounted
## Win16 NE resource directory and Microsoft SZDD installation compression.
const NATIVE_GRAPHICS := {1:"CURSOR",2:"BITMAP",3:"ICON",12:"GROUP_CURSOR",14:"GROUP_ICON"}

static func _name(raw: PackedByteArray, table: int, value: int, type: bool) -> String:
	if value & 0x8000:
		var id := value & 0x7fff
		return NATIVE_GRAPHICS.get(id,"TYPE_%d"%id) if type else str(id)
	var start := table+value
	if start >= raw.size() or start+1+raw[start] > raw.size(): return ""
	var name := raw.slice(start+1,start+1+raw[start]).get_string_from_ascii()
	if not name.is_valid_filename() or "." in name: return ""
	return name

static func resources(raw: PackedByteArray) -> Array:
	if raw.size()<64 or raw.decode_u16(0)!=0x5a4d: return []
	var ne := raw.decode_u32(60)
	if ne+0x34 > raw.size() or raw.decode_u16(ne)!=0x454e: return []
	var table := ne + raw.decode_u16(ne+0x24)
	if table+2>raw.size(): return []
	var shift := raw.decode_u16(table)
	if shift>16: return []
	var pos := table+2
	var rows := []
	while pos+2<=raw.size():
		var word := raw.decode_u16(pos)
		if word == 0: return rows
		var type := _name(raw,table,word,true)
		if type.is_empty() or pos+8>raw.size(): return []
		var count := raw.decode_u16(pos+2)
		pos+=8
		if pos+12*count>raw.size(): return []
		for i in count:
			var offset := raw.decode_u16(pos)<<shift
			var size := raw.decode_u16(pos+2)<<shift
			var name := _name(raw,table,raw.decode_u16(pos+6),false)
			if offset+size>raw.size() or name.is_empty(): return []
			rows.append({"type":type,"name":name,"offset":offset,"data":raw.slice(offset,offset+size)})
			pos+=12
	return []

static func expand(raw: PackedByteArray) -> PackedByteArray:
	var empty := PackedByteArray()
	if raw.size()<14 or raw.slice(0,9) != PackedByteArray([83,90,68,68,136,240,39,51,65]): return empty
	var size := raw.decode_u32(10)
	if size>16*1024*1024: return empty
	var ring := PackedByteArray()
	ring.resize(4096)
	ring.fill(32)
	var cursor := 4080
	var result := PackedByteArray()
	result.resize(size)
	var pos := 14
	var written := 0
	while written<size and pos<raw.size():
		var flags := raw[pos]
		pos+=1
		for i in 8:
			if written==size: break
			var literal := bool(flags & (1<<i))
			var length := 1
			var src := 0
			var value := 0
			if literal:
				if pos>=raw.size(): return empty
				value=raw[pos]
				pos+=1
			else:
				if pos+2>raw.size(): return empty
				src = raw[pos] | ((raw[pos+1]&0xf0)<<4)
				length=(raw[pos+1]&0xf)+3
				pos+=2
			if written+length>size: return empty
			for j in length:
				if not literal: value=ring[(src+j)&4095]
				ring[cursor]=value
				cursor=(cursor+1)&4095
				result[written]=value
				written+=1
	return result if written==size else empty
