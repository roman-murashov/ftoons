class_name SimulationState
extends RefCounted

const AudioPlayback = preload("res://scripts/audio/audio_playback_state.gd")
var audio := AudioPlayback.new()

class SimPart:
	var index: int = 0
	var part_type: int = 0
	var flags: int = 0
	var flags08: int = 0
	var flags0a: int = 0
	var settings: int = 0
	var width: int = 0
	var height: int = 0
	# DOS +59/+5B, distinct from logical +41/+43 and current frame +4D/+4F.
	var stored_extent: Vector2i = Vector2i(-1,-1)
	var frame_offset: Vector2i = Vector2i.ZERO
	var frame_size: Vector2i = Vector2i.ZERO
	# DOS +51/+53 and +55/+57: completed-update frame-size history.
	var previous_frame_size: Vector2i = Vector2i.ZERO
	var older_frame_size: Vector2i = Vector2i.ZERO
	var polygon_translation: Vector2i = Vector2i.ZERO
	var constructed_sections: int = -1
	var constructed_flip_x: bool = false
	# DOS list +00, and weighted speed +3D (signed 32-bit).
	var list_next: int = -1
	# Original list insertion can be independent of descriptor flag bits.
	# -1 uses ordinary placement/flag-derived membership.
	var chain_override: int = -1
	var collision_weight: int = 0
	var momentum: int = 0
	var x_fixed: int = 0
	var y_fixed: int = 0
	var vx_fixed: int = 0
	var vy_fixed: int = 0
	var state: int = 0
	var appearance: int = 0
	var triggered: bool = false
	var trigger_state: int = 0
	var reaction_state: int = 0
	var animation_tick: int = 0
	var contact_part: int = -1
	var contact_angle: int = 0
	var contact_edge: int = 0
	var contact_status_8f: int = 0
	var contact_status_90: int = 0
	var active: bool = true
	var placed: bool = true
	var rotation: int = 0
	var flip_x: bool = false
	var flip_y: bool = false
	# Explicit editor reflections on axes without a native DOS mirror. They
	# are separate from runtime facing changes, which retain DOS semantics.
	var editor_mirror_x: bool = false
	var editor_mirror_y: bool = false
	# Recovered reaction record values. DOS pointers become stable part indices.
	var authored_settings: int = 0
	var aux_a5: int = 0
	var scratch61: int = 0
	var target_part: int = -1
	var traversal_af: int = 0
	var previous_position: Vector2i = Vector2i.ZERO
	var older_position: Vector2i = Vector2i.ZERO
	var list_position: Vector2i = Vector2i.ZERO
	var previous_appearance: int = 0
	var older_appearance: int = 0
	var collision_enabled: bool = true
	var spawned: bool = false
	var definition: PartDefinition
	var links: Array[int] = []
	var reaction_data: Dictionary = {}

	## Values at the completed physics update. Position is the signed pixel
	## origin; the animated frame height is independent of the collision box.
	func goal_value(key: String) -> Variant:
		match key:
			"type": return part_type
			"state": return wrapi(state, -32768, 32768)
			"appearance": return wrapi(appearance, -32768, 32768)
			"settings": return wrapi(settings, -32768, 32768)
			"trigger": return wrapi(trigger_state, -32768, 32768)
			"x": return wrapi(x_fixed >> 15, -32768, 32768)
			"y": return wrapi(y_fixed >> 15, -32768, 32768)
			"older_y": return wrapi(older_position.y, -32768, 32768)
			"height": return wrapi(frame_size.y, -32768, 32768)
			"flags_08": return flags08 & 65535
			"flags_0a": return flags0a & 65535
			"target": return target_part
			"counter_value": return settings & 255
			"bottom": return int(goal_value("y")) + int(goal_value("height"))
		return null

	func copy() -> SimPart:
		var result := SimPart.new()
		_copy_into(result)
		return result

	func reset_for_reuse() -> void:
		# 298D:473B clears the payload and reconstructs the same allocation,
		# preserving its intrusive links. Keep the actual object instance so
		# callbacks holding it and incoming IDs still address this slot.
		var saved_index := index
		var saved_next := list_next
		var defaults := SimPart.new()
		defaults._copy_into(self)
		index = saved_index
		list_next = saved_next

	func _copy_into(result: SimPart) -> void:
		result.index = index
		result.part_type = part_type
		result.flags = flags
		result.flags08 = flags08
		result.flags0a = flags0a
		result.settings = settings
		result.width = width
		result.height = height
		result.x_fixed = x_fixed
		result.y_fixed = y_fixed
		result.vx_fixed = vx_fixed
		result.vy_fixed = vy_fixed
		result.state = state
		result.appearance = appearance
		result.triggered = triggered
		result.trigger_state = trigger_state
		result.reaction_state = reaction_state
		result.animation_tick = animation_tick
		result.contact_part = contact_part
		result.contact_angle = contact_angle
		result.contact_edge = contact_edge
		result.contact_status_8f = contact_status_8f
		result.contact_status_90 = contact_status_90
		result.active = active
		result.placed = placed
		result.rotation = rotation
		result.flip_x = flip_x
		result.flip_y = flip_y
		result.editor_mirror_x = editor_mirror_x
		result.editor_mirror_y = editor_mirror_y
		for key in ["stored_extent","frame_offset","frame_size","previous_frame_size","older_frame_size","polygon_translation","constructed_sections","constructed_flip_x","list_next","chain_override","collision_weight","momentum","authored_settings","aux_a5","scratch61","target_part","traversal_af","previous_position","older_position","list_position","previous_appearance","older_appearance","collision_enabled","spawned","definition"]:
			result.set(key,get(key))
		result.links = links.duplicate()
		result.reaction_data = reaction_data.duplicate(true)

# Original 298D:31F6 additive generator: ES:0420 words, DS:0626/0628 indices.
var random_words: Array[int] = []
var random_source: int = 24
var random_destination: int = 55
var digital_sound: Dictionary = {}

func next_random() -> int:
	if random_words.is_empty():
		var table := ReactionTables.new()
		for i in 56: random_words.append(table.u16(0x420+i*2))
	var value := (random_words[random_destination]+random_words[random_source])&0xffff
	random_words[random_destination]=value
	random_source=(random_source+1)%56
	random_destination=(random_destination+1)%56
	return value

func inherit_random(previous: SimulationState) -> void:
	# 298D:31F6 is process-global; loading/resetting gadgets does not reseed it.
	random_words.assign(previous.random_words)
	random_source=previous.random_source
	random_destination=previous.random_destination

func inherit_process_globals(previous: SimulationState) -> void:
	inherit_random(previous)
	# 7887:0011..0026 cycles main-DS4C64. 8A1E does not restore this
	# process-global counter from the saved gadget arrangement.
	explosion_variant=previous.explosion_variant
	audio=previous.audio.copy()

func completion_decoration() -> Dictionary:
	# 6D38:00B6/00CF/00ED/0109: four draws, interleaving art and delay.
	# Cache on the completed attempt so reopening/replacing a view cannot draw
	# again. Stop restores the arrangement, while retaining the advanced stream.
	if not goal.has("decoration"):
		var left:=next_random()
		var left_delay:=next_random()
		var right:=next_random()
		var right_delay:=next_random()
		goal["decoration"]={"variants":[left&1,2+(right&1)],
			"delays":[left_delay%15,right_delay%15],
			"draws":[left,left_delay,right,right_delay]}
	return goal.decoration.duplicate(true)

var tick: int = 0
# 298D:2E00 initializes the original playfield origin. Wall demolition rounds
# in that coordinate space, independently of Godot's camera/UI zoom.
var dos_view_origin: Vector2i = Vector2i(-91,-8)
var explosion_variant: int = 0
var running: bool = false
var goal: Dictionary = {}
var parts: Array[SimPart] = []
var ropes: Array[Dictionary] = []
var belts: Array[Dictionary] = []
var query_chains: Dictionary = {}
var pending_updates: Array[Dictionary] = []
var trace: Array[Dictionary] = []

func clone() -> SimulationState:
	var result := SimulationState.new()
	result.tick = tick
	result.dos_view_origin = dos_view_origin
	result.explosion_variant = explosion_variant
	result.audio = audio.copy()
	result.random_words.assign(random_words)
	result.random_source=random_source
	result.random_destination=random_destination
	result.digital_sound=digital_sound.duplicate(true)
	result.running = running
	result.goal = goal.duplicate(true)
	for part in parts:
		result.parts.append(part.copy())
	result.trace = trace.duplicate(true)
	result.ropes.assign(ropes.duplicate(true))
	result.belts.assign(belts.duplicate(true))
	result.query_chains = query_chains.duplicate(true)
	result.pending_updates = pending_updates.duplicate(true)
	return result

func snapshot() -> Dictionary:
	var result: Array = []
	for part in parts:
		result.append({"index": part.index, "type": part.part_type, "x_fixed": part.x_fixed, "y_fixed": part.y_fixed, "vx_fixed": part.vx_fixed, "vy_fixed": part.vy_fixed, "state": part.state, "flags": part.flags, "appearance": part.appearance, "triggered": part.triggered, "animation_tick": part.animation_tick, "contact_part": part.contact_part, "contact_angle": part.contact_angle, "contact_edge": part.contact_edge, "contact_status_8f": part.contact_status_8f, "contact_status_90": part.contact_status_90, "active": part.active, "placed": part.placed, "rotation": part.rotation, "flip_x": part.flip_x, "flip_y": part.flip_y})
		var record: Dictionary = result.back()
		record["flags08"] = part.flags08
		record["flags0a"] = part.flags0a
		record["settings"] = part.settings
		record["width"] = part.width
		record["height"] = part.height
		record["trigger_state"] = part.trigger_state
		record["reaction_state"] = part.reaction_state
		for key in ["stored_extent","frame_offset","frame_size","previous_frame_size","older_frame_size","polygon_translation","constructed_sections","constructed_flip_x","editor_mirror_x","editor_mirror_y","list_next","chain_override","collision_weight","momentum","authored_settings","aux_a5","scratch61","target_part","traversal_af","previous_position","older_position","list_position","previous_appearance","older_appearance","collision_enabled","spawned","links","reaction_data"]:
			var value = part.get(key)
			record[key] = value.duplicate(true) if value is Dictionary or value is Array else value
	return {"goal":goal.duplicate(true),"audio_playback":audio.snapshot(),"dos_view_origin":dos_view_origin,"explosion_variant":explosion_variant,"ropes":ropes.duplicate(true),"belts":belts.duplicate(true),"random_words":random_words.duplicate(),"random_source":random_source,"random_destination":random_destination,"tick": tick, "running": running, "parts": result,"query_chains":query_chains.duplicate(true),"pending_updates":pending_updates.duplicate(true)}
