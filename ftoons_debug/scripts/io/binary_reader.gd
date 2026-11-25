class_name BinaryReader
extends RefCounted

## Bounds-checked little-endian reader for the original binary payloads.
## A failed read records an error and returns a neutral value; callers must
## check has_error() before accepting a decoded structure.

var data: PackedByteArray
var offset: int = 0
var error: String = ""

func _init(bytes: PackedByteArray = PackedByteArray()) -> void:
	data = bytes

func remaining() -> int:
	return maxi(0, data.size() - offset)

func has_error() -> bool:
	return not error.is_empty()

func read_u8() -> int:
	if not _require(1):
		return 0
	var value: int = data[offset]
	offset += 1
	return value

func read_i8() -> int:
	var value := read_u8()
	return value if value < 128 else value - 256

func read_u16_le() -> int:
	if not _require(2):
		return 0
	var value := data[offset] | (data[offset + 1] << 8)
	offset += 2
	return value

func read_i16_le() -> int:
	var value := read_u16_le()
	return value if value < 32768 else value - 65536

func read_u32_le() -> int:
	if not _require(4):
		return 0
	var value := data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (data[offset + 3] << 24)
	offset += 4
	return value

func read_bytes(count: int) -> PackedByteArray:
	if count < 0 or not _require(count):
		return PackedByteArray()
	var value := data.slice(offset, offset + count)
	offset += count
	return value

func read_c_string(max_bytes: int = -1) -> String:
	var limit := remaining() if max_bytes < 0 else mini(max_bytes, remaining())
	var start := offset
	for i in range(limit):
		if data[offset + i] == 0:
			var raw := data.slice(start, offset + i)
			offset += i + 1
			return raw.get_string_from_ascii()
	var raw := data.slice(start, start + limit)
	offset += limit
	_set_error("unterminated string at 0x%X" % start)
	return raw.get_string_from_ascii()

func _require(count: int) -> bool:
	if count < 0 or offset < 0 or offset + count > data.size():
		_set_error("read outside payload: offset=0x%X count=%d size=%d" % [offset, count, data.size()])
		return false
	return true

func _set_error(message: String) -> void:
	if error.is_empty():
		error = message
