extends RefCounted
## Physical room layouts and trackable objectives from the packaged campaign.
## Catalog aims and original finish times come from docs/random_levels/level_statistics.csv.
const Document := preload("res://scripts/io/home_toons_document.gd")
const CATALOG := preload("res://scripts/generation/campaign_rooms.json")
const TIERS := ["CAKE", "BRAN", "HARD", "LOON"]

static func candidates(tier: int) -> Array[String]:
	var result: Array[String] = []
	if tier < 1 or tier > TIERS.size():
		return result
	for room: Dictionary in CATALOG.data:
		if String(room.source).begins_with(TIERS[tier - 1]):
			result.append(room.source)
	return result

static func build(source: String) -> Dictionary:
	for room: Dictionary in CATALOG.data:
		if room.source == source:
			return _capture(room)
	return {}

static func _capture(room: Dictionary) -> Dictionary:
	var puzzle := LevelReader.new(null).read_level(String(room.source) + ".LEV")
	if puzzle == null or not puzzle.declared_counts_match or puzzle.campaign_goal_index < 0:
		return {}
	var runner := SimulationRunner.new(puzzle)
	runner.place_solution()
	var doc := Document.capture(runner)
	if doc.parts.size() != puzzle.parts.size():
		return {}
	var placements := []
	for p in runner.initial_state.parts:
		var row: Dictionary = doc.parts[p.index]
		if not p.placed:
			placements.append({"part": row.id, "top_left": [row.pos_x, row.pos_y]})
	doc.goal = room.aim
	doc.generator = {"solution_placements": placements, "goal_family": room.family,
		"campaign_finish": int(room.campaign_finish)}
	return doc
