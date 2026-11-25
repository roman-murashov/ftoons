class_name ReactionTables
extends RefCounted

## Original data only. Behavior is native GDScript, not DOS code execution.
var metadata: Dictionary = {}
var bytes: PackedByteArray = PackedByteArray()

func _init() -> void:
	var file := FileAccess.open("res://assets/original/special_reactions.json",FileAccess.READ)
	if file != null:
		var parsed = JSON.parse_string(file.get_as_text())
		if parsed is Dictionary:
			metadata = parsed
	file = FileAccess.open("res://assets/original/reaction_tables.bin",FileAccess.READ)
	if file != null:
		bytes = file.get_buffer(file.get_length())

func u8(offset: int) -> int:
	return int(bytes[offset & 65535]) if bytes.size()==65536 else 0

func s8(offset: int) -> int:
	var v := u8(offset)
	return v-256 if v>=128 else v

func u16(offset: int) -> int:
	return u8(offset) | (u8(offset+1)<<8)

func s16(offset: int) -> int:
	return ((u16(offset)+32768)&65535)-32768

func actor(type_id: int, state_id: int) -> Dictionary:
	var rows: Array = metadata.get("actor_states",{}).get(str(type_id),[])
	return rows[state_id] if state_id>=0 and state_id<rows.size() else {}

func branch(site: String, key: int) -> int:
	var target := String(metadata.get("switches",{}).get(site,{}).get(str(key),""))
	return target.get_slice(":",1).hex_to_int() if not target.is_empty() else -1

func sheet(type_id: int, state_id: int) -> String:
	return String(actor(type_id,state_id).get("sheet",""))
