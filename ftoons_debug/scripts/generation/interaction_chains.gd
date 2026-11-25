extends RefCounted
## Assemble a seeded chain on an empty board and leave working links for the
## player to complete. The normal room verifier must witness every handoff.
const Board := preload("res://scripts/generation/room_board.gd")
const Heat := preload("res://scripts/generation/heat_chain.gd")
const Load := preload("res://scripts/generation/load_chain.gd")
const SETS := [
	{"name":"the Boiler House", "beam":26, "pier":28},
	{"name":"the Freight Theatre", "beam":27, "pier":29},
	{"name":"the Switchyard", "beam":29, "pier":27},
	{"name":"the Fossil Works", "beam":82, "pier":26},
	{"name":"the Caramel Foundry", "beam":83, "pier":28},
]
const MIN_PIECES := [1, 1, 2, 2]
const MAX_PIECES := [1, 2, 3, 4]

static func build(tier: int, rng: RandomNumberGenerator) -> Dictionary:
	var stage: Dictionary = SETS[rng.randi_range(0, SETS.size()-1)]
	var doc := Board.blank()
	var plan := {"solution_placements":[], "branches":[], "replay_limit":270}
	doc.generator = plan
	var spec: Dictionary
	if rng.randf() < 0.59:
		spec = Heat.build(doc, tier, rng, stage)
	else:
		spec = Load.build(doc, tier, rng, stage)
	var key := "chain/" + ">".join(spec.steps)
	if not spec.side_steps.is_empty(): key += "+" + ">".join(spec.side_steps)
	plan.challenge_key = key
	plan.set_design = spec.set_design
	plan.room_name = stage.name
	plan.mechanism = spec.name
	plan.goal_family = spec.family
	plan.interaction_chain = {"main":spec.steps, "side":spec.side_steps}
	doc.title = "%s at %s" % [spec.name, stage.name]
	doc.goal = spec.goal
	var goals := []
	for route: Dictionary in spec.routes:
		plan.branches.append({"events":route.events})
		goals.append({"kind":"sequence","of":route.nodes})
	doc.goals = {"version":1, "delay_updates":8,
		"when":goals[0] if goals.size() == 1 else {"kind":"all","of":goals}}
	_inventory(doc, spec.placeable, rng.randi_range(MIN_PIECES[tier-1], MAX_PIECES[tier-1]), rng)
	# Match native static-chain membership for sight and region queries in both formats.
	for row: Dictionary in doc.parts:
		if int(row.flags_1) & 0x6000: row.flags_1 |= 0x2000
	return doc

static func _inventory(doc: Dictionary, placeable: Array, count: int, rng: RandomNumberGenerator) -> void:
	var chosen := {}
	for i in mini(count, placeable.size()):
		var draw := rng.randi_range(i, placeable.size()-1)
		var id: String = placeable[draw]
		placeable[draw] = placeable[i]
		placeable[i] = id
		chosen[id] = true
	var missing_indices := {}
	var placements: Array = doc.generator.solution_placements
	for i in doc.parts.size():
		var row: Dictionary = doc.parts[i]
		if not chosen.has(row.id): continue
		missing_indices[i] = true
		row.flags_3 &= ~0x40
		placements.append({"part":row.id,"top_left":[row.pos_x,row.pos_y]})
	# In native construction, removing a rope endpoint puts the associated
	# rope back in the bin. Reconnect it after dropping all its gadgets.
	for rope: Dictionary in doc.ropes:
		if not rope.route.any(func(index): return missing_indices.has(index)): continue
		var owner: Dictionary = doc.parts[rope.owner]
		owner.flags_3 &= ~0x40
		var names: Array = rope.route.map(func(index): return doc.parts[index].id)
		placements.append({"part":owner.id,"rope_route":names,"rope_slots":rope.slots})
