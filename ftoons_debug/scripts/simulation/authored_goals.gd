extends RefCounted
## Home Toons v1 goal vocabulary. Only construction data is serialized.
const Originals = preload("res://scripts/data/original_goal_catalog.gd")
const MAX_DEPTH := 16
const MAX_NODES := 256
const FIELDS := ["x", "y", "bottom", "height", "older_y", "state", "appearance",
	"trigger", "settings", "counter_value", "flags_08", "flags_0a"]
const COMPARISONS := ["eq", "ne", "lt", "le", "gt", "ge"]
const EVENTS := ["contact", "deactivated", "tunnel_from", "tunnel_to", "launched_by",
	"reaction", "rope_cut", "shot", "shot_contact", "destroyed_by_blast"]
const COMBINATIONS := ["all", "any", "at_least", "sequence"]
const WRAPPERS := ["not", "ever", "hold", "count_updates", "after_last"]
const TIMERS := ["hold", "count_updates", "after_last"]
const REQUIRED := {
	"all": ["of"], "any": ["of"], "at_least": ["of", "count"], "sequence": ["of"], "not": ["condition"],
	"ever": ["condition"], "hold": ["condition", "updates"],
	"count_updates": ["condition", "updates"], "after_last": ["condition", "updates"],
	"inactive": ["part"], "vacuumed": ["part"], "has_primary_rope": ["part"],
	"ghost_above_top": ["part"], "targets": ["part", "other"],
	"compare": ["part", "field", "op"], "in_area": ["part", "rect"],
	"crosses": ["part", "direction", "line", "span"], "event": ["part", "event"],
	"group": ["type", "chain", "selection", "match", "where"]
}
const OPTIONAL := {
	"compare": ["value", "other", "other_field"], "in_area": ["relative_to"],
	"event": ["other", "reason"], "group": ["minimum", "limit", "count"]
}

static func _integer(value: Variant, low: int, high: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and value == floorf(value) and value >= low and value <= high

static func _keys(row: Dictionary, required: Array, optional: Array, path: String) -> String:
	for key in required:
		if not row.has(key): return "%s is missing '%s'." % [path, key]
	for key in row:
		if key not in required and key not in optional: return "%s has an unknown field '%s'." % [path, key]
	return ""

static func validate(goals: Variant, part_ids: Dictionary) -> String:
	if not goals is Dictionary: return "goals must be an object."
	if goals.is_empty(): return ""
	if not _integer(goals.get("version"), 1, 1): return "Unsupported goal version."
	if goals.has("original"):
		var error := _keys(goals, ["version", "original"], [], "goals")
		if not error.is_empty(): return error
		if not goals.original is String or Originals.original_spec(goals.original).is_empty():
			return "Unknown or unavailable original goal '%s'." % str(goals.original)
		return ""
	var error := _keys(goals, ["version", "delay_updates", "when"], [], "goals")
	if not error.is_empty(): return error
	if not _integer(goals.delay_updates, 0, 65535): return "delay_updates must be an integer from 0 to 65535."
	return _validate_node(goals.when, part_ids, "goals.when", 1, [0], -1)

static func _validate_node(node: Variant, ids: Dictionary, path: String, depth: int, count: Array, member_type: int) -> String:
	count[0] += 1
	if depth > MAX_DEPTH or count[0] > MAX_NODES: return "%s exceeds the goal size limit." % path
	if not node is Dictionary or not node.get("kind") is String or not REQUIRED.has(node.kind):
		return "%s needs a recognized condition kind." % path
	var kind: String = node.kind
	var error := _keys(node, ["kind"] + REQUIRED[kind], OPTIONAL.get(kind, []), path)
	if not error.is_empty(): return error
	if member_type >= 0 and kind in ["ever", "hold", "count_updates", "after_last", "sequence", "crosses", "event", "ghost_above_top", "group"]:
		return "%s requires a single instantaneous test for a group member." % path
	for key in ["part", "other", "relative_to"]:
		if not node.has(key): continue
		var id: Variant = node[key]
		if not id is String or (not ids.has(id) and not (id == "$" and member_type >= 0)):
			return "%s.%s references an unknown part '%s'." % [path, key, str(id)]
	if kind in COMBINATIONS:
		if not node.of is Array or node.of.is_empty() or node.of.size() > MAX_NODES:
			return "%s.of needs a nonempty list of conditions (up to %d)." % [path, MAX_NODES]
		if kind == "at_least" and not _integer(node.count, 1, node.of.size()):
			return "%s.count must be between 1 and the number of conditions." % path
		for i in node.of.size():
			error = _validate_node(node.of[i], ids, "%s.of[%d]" % [path, i], depth+1, count, member_type)
			if not error.is_empty(): return error
	elif kind in WRAPPERS:
		if kind in TIMERS and not _integer(node.updates, 1, 65535):
			return "%s.updates must be an integer from 1 to 65535." % path
		return _validate_node(node.condition, ids, path + ".condition", depth+1, count, member_type)
	elif kind == "group":
		if not _integer(node.type, 0, 84) or node.chain not in ["moving", "static"] or node.selection not in ["initial", "live"] or node["match"] not in ["all", "any", "at_least"]:
			return "%s needs a part type, chain, selection and match mode." % path
		if not _integer(node.get("limit", 1024), 1, 1024) or not _integer(node.get("minimum", 1), 0, int(node.get("limit", 1024))):
			return "%s needs 0 <= minimum <= limit <= 1024 and a positive limit." % path
		if node["match"] == "at_least":
			if not _integer(node.get("count"), 1, int(node.get("limit", 1024))): return "%s needs a positive match count within its limit." % path
		elif node.has("count"): return "%s.count needs the at_least match mode." % path
		return _validate_node(node.where, ids, path + ".where", depth+1, count, int(node.type))
	elif kind == "compare":
		if node.field not in FIELDS or node.op not in COMPARISONS: return "%s has an unknown field or comparison." % path
		if node.has("value"):
			if node.has("other") or node.has("other_field") or not _integer(node.value, -65536, 65535):
				return "%s needs one integer comparison value in [-65536,65535]." % path
		elif not node.has("other") or node.get("other_field") not in FIELDS:
			return "%s needs a value or a second part and field." % path
	elif kind == "in_area":
		if not _coordinates(node.rect, 4) or node.rect[0] >= node.rect[2] or node.rect[1] >= node.rect[3]:
			return "%s.rect needs [left, top, right, bottom] with positive width and height." % path
	elif kind == "crosses":
		if node.direction not in ["left", "right", "up", "down"] or not _integer(node.line, -32768, 32767) or not _coordinates(node.span, 2) or node.span[0] >= node.span[1]:
			return "%s needs a direction, a line and an increasing two-coordinate span." % path
	elif kind == "event":
		if node.event not in EVENTS or (node.event not in ["deactivated", "shot"] and not node.has("other")):
			return "%s needs a supported event and its participant(s)." % path
		if node.event == "reaction":
			if not node.get("reason") is String or node.reason.is_empty(): return "%s needs the reaction reason." % path
		elif node.has("reason"):
			return "%s.reason is only used for reaction events." % path
		if node.event in ["tunnel_from", "tunnel_to"] and (ids[node.part] not in [36, 37] or ids[node.other] != 46):
			return "%s needs Al or Sid and a Tunnel endpoint." % path
		if node.event == "launched_by" and ids[node.other] != 68: return "%s.other must be Eunice." % path
		if node.event == "rope_cut" and (ids[node.part] != 16 or ids[node.other] != 14):
			return "%s needs Scissors and the cut Rope." % path
		if node.event == "shot" and (ids[node.part] != 20 or node.has("other")):
			return "%s needs the firing Pistol." % path
		if node.event == "shot_contact" and ids[node.other] != 20: return "%s.other must be a Pistol." % path
		if node.event == "destroyed_by_blast" and ids[node.other] not in [19,62]:
			return "%s.other must be a Ball Bomb or Bombshell." % path
	elif kind == "ghost_above_top" and ids[node.part] != 36:
		return "%s.part must be Al." % path
	return ""

static func _coordinates(value: Variant, size: int) -> bool:
	if not value is Array or value.size() != size: return false
	for number in value:
		if not _integer(number, -32768, 32768): return false
	return true

static func bind(goals: Dictionary, state: SimulationState) -> void:
	var types := {}
	var named_slots := {}
	for part in state.parts:
		if part.spawned or part.definition == null or part.definition.goal_id.is_empty(): continue
		var id := part.definition.goal_id
		types[id] = part.part_type
		state.goal.bindings[id] = part.index
		if part.placed: named_slots[part.index] = id
	state.goal.initialized = true
	state.goal.error = validate(goals, types)
	if not String(state.goal.error).is_empty(): return
	state.goal.previous_origins = {}
	_init_node(goals.when, state, "0")
	if state.goal.get("uses_events", false):
		state.goal.event_ids = named_slots
		state.goal.shot_origins = {}

static func _init_node(node: Dictionary, state: SimulationState, path: String) -> void:
	match node.kind:
		"group":
			if node.selection == "initial": state.goal.vars[path] = _members(node, state)
		"crosses":
			var part := _part(node.part, state)
			if part != null: state.goal.previous_origins[node.part] = _position(part)
		"event": state.goal.uses_events = true
	if node.has("of"):
		for i in node.of.size(): _init_node(node.of[i], state, path + "/" + str(i))
	if node.has("condition"): _init_node(node.condition, state, path + "/0")

static func satisfied(node: Dictionary, state: SimulationState, events: Array) -> bool:
	var observations: Array = []
	if state.goal.get("uses_events", false): observations = _observe_events(state.goal.event_ids, state.goal.shot_origins, events)
	var result: Variant = _evaluate(node, state, "0", null, observations)
	for id in state.goal.previous_origins:
		var part := _part(id, state)
		if part != null: state.goal.previous_origins[id] = _position(part)
	return result != null and bool(result)

static func _part(id: String, state: SimulationState, member: SimulationState.SimPart = null) -> SimulationState.SimPart:
	if id == "$": return member
	var index := int(state.goal.bindings.get(id, -1))
	if index < 0 or index >= state.parts.size(): return null
	var part := state.parts[index]
	if not part.placed or part.spawned or part.definition == null or part.definition.goal_id != id: return null
	return part

static func _position(part: SimulationState.SimPart) -> Vector2i:
	return Vector2i(part.goal_value("x"), part.goal_value("y"))

static func _members(node: Dictionary, state: SimulationState) -> Array:
	var result := []
	var mask := 0x1000 if node.chain == "moving" else 0x2000
	for index in state.query_chains.get(mask, []):
		var part := state.parts[int(index)]
		if part.placed and part.part_type == int(node.type):
			result.append(part.index)
			if result.size() == int(node.get("limit", 1024)): break
	return result

static func _evaluate(node: Dictionary, state: SimulationState, path: String, member: SimulationState.SimPart, events: Array) -> Variant:
	var kind: String = node.kind
	var memory: Dictionary = state.goal.vars
	if kind == "sequence":
		var next := int(memory.get(path, 0))
		if next == node.of.size(): return true
		var reached: Variant = _evaluate(node.of[next], state, path + "/" + str(next), member, events)
		if reached == null: return null
		if reached: memory[path] = next + 1
		return int(memory.get(path, 0)) == node.of.size()
	if kind in ["all", "any", "at_least"]:
		var results := []
		# Each child gets this update even if a sibling already decides the result.
		for i in node.of.size():
			results.append(_evaluate(node.of[i], state, path + "/" + str(i), member, events))
		return _combine(results, results.size() if kind == "all" else int(node.get("count", 1)))
	if kind in WRAPPERS:
		var value: Variant = _evaluate(node.condition, state, path + "/0", member, events)
		match kind:
			"not": return null if value == null else not value
			"ever":
				if value: memory[path] = true
				return true if memory.has(path) else value
			"hold", "count_updates":
				var count := int(memory.get(path, 0))
				if value: count = mini(count + 1, int(node.updates))
				elif kind == "hold": count = 0
				memory[path] = count
				if count >= int(node.updates): return true
				return null if value == null else false
			"after_last":
				if value: memory[path] = state.tick
				if value == null: return null
				return memory.has(path) and state.tick - int(memory[path]) == int(node.updates)
	if kind == "group":
		var indices: Array = _members(node, state) if node.selection == "live" else memory[path]
		if indices.size() < int(node.get("minimum", 1)): return false
		var results := []
		for index in indices:
			var part := state.parts[int(index)]
			var valid := part.placed and part.part_type == int(node.type)
			results.append(_evaluate(node.where, state, path + "/member", part, events) if valid else null)
		return _combine(results, results.size() if node["match"] == "all" else int(node.get("count", 1)))
	if kind == "event":
		# Events retain the IDs at the instant of the interaction even if a
		# later factory spawn reuses the native slot in this same update.
		var observation := [node.event, node.part, node.get("other", "")]
		if node.event == "reaction": observation.append(node.reason)
		if events.has(observation): return true
	var part := _part(node.part, state, member)
	if part == null: return null
	var other: SimulationState.SimPart
	if node.has("other"):
		other = _part(node.other, state, member)
		if other == null: return null
	match kind:
		"inactive": return (part.flags08 & 0x2000) != 0
		"vacuumed": return (part.flags0a & 0x100) != 0
		"has_primary_rope": return RopePhysics.has_primary_connection(state, part)
		"targets": return part.target_part == other.index
		"event": return false
		"compare":
			var rhs := int(node.value) if node.has("value") else int(other.goal_value(node.other_field))
			return _compare(int(part.goal_value(node.field)), node.op, rhs)
		"in_area":
			var position := _position(part)
			if node.has("relative_to"):
				var origin := _part(node.relative_to, state, member)
				if origin == null: return null
				position -= _position(origin)
			var r: Array = node.rect
			return position.x >= r[0] and position.x < r[2] and position.y >= r[1] and position.y < r[3]
		"crosses":
			if not state.goal.previous_origins.has(node.part): return null
			return _crossed(node, state.goal.previous_origins[node.part], _position(part))
		"ghost_above_top":
			if part.state == 16 and part.target_part >= 0 and part.target_part < state.parts.size() and state.parts[part.target_part].part_type == 36:
				memory[path] = part.target_part
			return memory.has(path) and int(state.parts[int(memory[path])].goal_value("bottom")) < 0
	return null

static func _combine(values: Array, required: int) -> Variant:
	var matches := 0
	var unknown := 0
	for value in values:
		if value == null: unknown += 1
		elif value: matches += 1
	if matches >= required: return true
	if matches + unknown < required: return false
	return null

static func _compare(left: int, op: String, right: int) -> bool:
	match op:
		"eq": return left == right
		"ne": return left != right
		"lt": return left < right
		"le": return left <= right
		"gt": return left > right
		"ge": return left >= right
	return false

static func _crossed(node: Dictionary, previous: Vector2i, current: Vector2i) -> bool:
	var horizontal: bool = node.direction in ["left", "right"]
	var start := previous.x if horizontal else previous.y
	var finish := current.x if horizontal else current.y
	var line := int(node.line)
	if node.direction in ["up", "left"]:
		if not (start >= line and finish < line): return false
	elif not (start <= line and finish > line): return false
	var across := previous.y if horizontal else previous.x
	var end_across := current.y if horizontal else current.x
	# Interpolate at the line using integers so an exact right/bottom endpoint is excluded.
	var distance := absi(finish - start)
	var scaled := across * distance + (end_across - across) * absi(line - start)
	return scaled >= int(node.span[0]) * distance and scaled < int(node.span[1]) * distance

static func _observe_events(named: Dictionary, shot_origins: Dictionary, events: Array) -> Array:
	var observations := []
	for event in events:
		var index := int(event.part_index)
		var id: String = named.get(index, "")
		match event.kind:
			"spawn":
				named.erase(index)
				shot_origins.erase(index)
				if event.get("type") == 21:
					var pistol: String = named.get(int(event.get("producer", -1)), "")
					if not pistol.is_empty():
						shot_origins[index] = pistol
						observations.append(["shot", pistol, ""])
			"contact", "moving_contact":
				var other_index := int(event.other)
				var other: String = named.get(other_index, "")
				if not id.is_empty() and not other.is_empty():
					observations.append(["contact", id, other])
					observations.append(["contact", other, id])
				if not id.is_empty() and shot_origins.has(other_index):
					observations.append(["shot_contact", id, shot_origins[other_index]])
				if not other.is_empty() and shot_origins.has(index):
					observations.append(["shot_contact", other, shot_origins[index]])
			"reaction_request":
				var producer: String = named.get(int(event.get("producer", -1)), "")
				if not id.is_empty() and not producer.is_empty():
					observations.append(["reaction", id, producer, event.reason])
			"rope_cut":
				var rope: String = named.get(int(event.get("cut_rope", -1)), "")
				if not id.is_empty() and not rope.is_empty(): observations.append(["rope_cut", id, rope])
			"deactivate":
				shot_origins.erase(index)
				if not id.is_empty():
					observations.append(["deactivated", id, ""])
					var producer: String = named.get(int(event.get("producer", -1)), "")
					if not producer.is_empty(): observations.append(["deactivated", id, producer])
					var charge: String = named.get(int(event.get("blast_source", -1)), "")
					if not charge.is_empty(): observations.append(["destroyed_by_blast", id, charge])
			"tunnel_exit":
				if not id.is_empty():
					observations.append(["tunnel_from", id, named.get(int(event.entrance), "")])
					observations.append(["tunnel_to", id, named.get(int(event.exit), "")])
			"Eunice_launch":
				if not id.is_empty(): observations.append(["launched_by", named.get(int(event.target), ""), id])
	return observations
