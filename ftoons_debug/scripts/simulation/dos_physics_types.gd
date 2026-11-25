class_name DosPhysicsTypes
extends RefCounted

## Runtime-facing types for the recovered packed DOS structures.
## Layout/evidence: decompilation/physics_pass/reports/shared_physics_schema.json.
## These are values, not host representations of DOS pointers or packed memory.
const DATA_PATH := "res://assets/original/shared_physics.json"

class Descriptor:
	var part_type: int
	var part_name: String
	var force_input: int
	var collision_weight: int
	var rebound_q8: int
	var sliding_loss: int

	func _init(type_id: int, values: Dictionary) -> void:
		part_type = type_id
		part_name = String(values.name)
		force_input = int(values.f2)
		collision_weight = int(values.f4)
		rebound_q8 = int(values.f6)
		sliding_loss = int(values.f8)

class ForceState:
	var acceleration_q9: int = 0
	var speed_limit_q9: int = 0

class ContactBody:
	var fx: int = 0
	var fy: int = 0
	var x: int = 0
	var y: int = 0
	var ox: int = 0
	var oy: int = 0
	var vx: int = 0
	var vy: int = 0
	var flags: int = 0
	var contact: int = -1
	var angle: int = 0
	var edge: int = 0
	var b1: int = 0
	var b2: int = 0
	var points: Array = []
	# DOS +87 may expose only the first edge of a larger registered polygon.
	var point_count: int = -1
	var midpoint_x: int = 0
	var width: int = 0
	var height: int = 0
	var center_x_offset: int = 0
	var center_y_offset: int = 0
	var has_frame_center: bool = false

var data: Dictionary = {}
var descriptors: Dictionary = {}

func _init() -> void:
	var file := FileAccess.open(DATA_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary or int(parsed.get("schema", 0)) != 1:
		return
	data = parsed
	# JSON numbers arrive as floats; Array.has() requires matching Variant types.
	for key in ["rolling_types", "surface_types", "incline_types", "wall_types"]:
		var ids: Array[int] = []
		for value in data.get(key, []):
			ids.append(int(value))
		data[key] = ids
	for key in data.parameters:
		descriptors[int(key)] = Descriptor.new(int(key), data.parameters[key])

func descriptor(type_id: int) -> Descriptor:
	return descriptors.get(type_id)

func environment(type_id: int, pressure: int, gravity: int) -> ForceState:
	# 1000:2672. Keep F2 force input distinct from F4 collision weight.
	var result := ForceState.new()
	var physical := descriptor(type_id)
	if physical == null:
		return result
	var p := pressure >> 1 if pressure < 70 else pressure << 4
	var g := (gravity >> 2) + 1 if gravity < 140 else gravity * 2 if gravity > 278 else gravity
	if physical.force_input > p:
		result.acceleration_q9 = g - _divide(p * g, physical.force_input)
	elif physical.force_input < p:
		result.acceleration_q9 = _divide(physical.force_input * g, p) - g
	if type_id in [5, 11, 21]:
		result.acceleration_q9 = 0
	result.acceleration_q9 = _s16(result.acceleration_q9)
	result.speed_limit_q9 = 0x3000 if type_id in [6, 21] else _s16(0x2600 - p)
	if type_id == 5:
		result.speed_limit_q9 = 0x400
	return result

static func _s16(value: int) -> int:
	return ((value + 32768) & 65535) - 32768

static func _divide(a: int, b: int) -> int:
	@warning_ignore("integer_division")
	return a / b
