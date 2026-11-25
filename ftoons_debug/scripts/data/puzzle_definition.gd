class_name PuzzleDefinition
extends RefCounted

var name: String = ""
var source_name: String = ""
var construction_context: String = "campaign"
## JSON editor documents store logical dimensions; native LEV/ITL records
## store drawing extents that require the original constructor rules.
var authored_logical_extents: bool = false
## Only the original resource reader binds compiled campaign objectives.
## Editor documents retain -1 even if named like a campaign level.
var campaign_goal_index: int = -1
## Trusted MPC callback translation, bound only by HeadToHeadLibrary.
## Custom editor documents never supply executable goal expressions.
var head_to_head_goal: Dictionary = {}
## A validated Home Toons win condition. An empty object selects manual judging.
var authored_goals: Dictionary = {}
var _reserved_goal_ids: Dictionary = {}
var _next_goal_id: int = 1
var magic: String = ""
var format_magic: int = 0
var format_version: int = 0
var title: String = ""
var instructions: String = ""
var source_size: int = 0
var logical_length: int = 0
var header_offset: int = 0
var pressure: int = 0
var gravity: int = 0
var unknown_4: int = 0
var unknown_6: int = 0
var music: int = 0
var fixed_count: int = 0
var moving_count: int = 0
var parts: Array[PartDefinition] = []
var fixed_parts: Array[PartDefinition] = []
var moving_parts: Array[PartDefinition] = []
var inventory_parts: Array[PartDefinition] = []
var actor_candidates: Array[PartDefinition] = []
var record_gaps: Array[PackedByteArray] = []
var tail_offset: int = 0
var tail: PackedByteArray = PackedByteArray()
var scan_error: String = ""
var declared_counts_match: bool = false
## Explicit Godot editor transforms; native flips remain flags_2.
var editor_transforms: Array[Dictionary] = []

func assign_goal_id(part: PartDefinition, saved_id: String = "") -> void:
	if saved_id.is_empty():
		saved_id = "part-%d" % _next_goal_id
		while _reserved_goal_ids.has(saved_id):
			_next_goal_id += 1
			saved_id = "part-%d" % _next_goal_id
		_next_goal_id += 1
	else:
		_reserved_goal_ids[saved_id] = true
	part.goal_id = saved_id

func observed_counts() -> Dictionary:
	var result := {"fixed": fixed_parts.size(), "moving": moving_parts.size(), "parts-bin": inventory_parts.size(), "unclassified": 0, "inventory": inventory_parts.size(), "actors": actor_candidates.size()}
	for part in parts:
		if not part.is_fixed() and not part.is_moving() and not part.is_in_parts_bin():
			result["unclassified"] += 1
	return result

func has_unparsed_tail() -> bool:
	return not tail.is_empty()

func summary() -> String:
	return "%s: %d parts, tail %d bytes" % [title, parts.size(), tail.size()]
