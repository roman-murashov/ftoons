extends RefCounted
## Builds a solved Home Toons document after witnessing its goal and physical event plan.
const Document = preload("res://scripts/io/home_toons_document.gd")
const Controls = preload("res://scripts/ui/construction_controls.gd")
const Curtains = preload("res://scripts/generation/random_curtains.gd")
const Checks = preload("res://scripts/generation/generation_checks.gd")
const MAX_UPDATES := 240
const MAX_ATTEMPTS := 40
const EGG := 55
const HEN := 69
const AL := 36
const SID := 37
const FLOOR := 26
const HEN_GOAL := "Reach an action or animation milestone"
const CURTAIN_GOAL := "Operate, damage, or read a gadget"
const Pantry := preload("res://scripts/generation/pantry_rooms.gd")
const Power := preload("res://scripts/generation/power_rooms.gd")
const Delivery := preload("res://scripts/generation/delivery_works.gd")
const Stage := preload("res://scripts/generation/stage_works.gd")
const Mill := preload("res://scripts/generation/mill_works.gd")
const Action := preload("res://scripts/generation/action_rooms.gd")
const Stacked := preload("res://scripts/generation/stacked_rooms.gd")
const Conveyors := preload("res://scripts/generation/conveyor_rooms.gd")
const Chains := preload("res://scripts/generation/interaction_chains.gd")
const Verifier := preload("res://scripts/generation/room_verifier.gd")
const Similarity := preload("res://scripts/generation/room_similarity.gd")
const BUILDERS := [Pantry, Power, Delivery, Stage, Mill, Action, Stacked, Conveyors]
const TIERS := [{"name":"CAKE"}, {"name":"BRAN"}, {"name":"HARD"}, {"name":"LOON"}]
const STAGE_HEIGHT := 400.0
const CHAIN_PROPOSALS := 12
const CHAIN_TRIALS := 6
const MIN_CHAIN_STEPS := [2, 3, 4, 5]

var error := ""
signal candidate_started(number: int)

func generate_level(difficulty: int, level_seed: int, tree: SceneTree = null, used_layouts: Array = [],
		recent_keys: Array = [], recent_boards: Array = []) -> Dictionary:
	error = ""
	if difficulty < 1 or difficulty > TIERS.size():
		error = "Select a difficulty from 1 to 4."
		return {}
	var rng := RandomNumberGenerator.new()
	rng.seed = level_seed
	var checks := Checks.new(tree)
	var attempts := 0
	var chains := await _chain_proposals(difficulty, rng, used_layouts, recent_keys, recent_boards, checks)
	for proposal: Dictionary in chains.slice(0, CHAIN_TRIALS):
		await checks.yield_if_needed()
		attempts += 1
		candidate_started.emit(attempts)
		var comparison := Similarity.compare(proposal.signature, recent_boards)
		if comparison.accepted and await Verifier.verify(proposal.doc, checks):
			return _finish(proposal.doc, proposal.id, difficulty, level_seed, attempts, comparison)

	# Construct a fresh proposal for each available mechanism. Ranking the
	# player decisions before running physics keeps recolored variants from
	# crowding out an entirely different puzzle in the same session.
	for round_number in 4:
		var proposals := []
		var has_fresh_decision := false
		for builder in BUILDERS:
			for id: String in builder.candidates(difficulty):
				await checks.yield_if_needed()
				var doc: Dictionary = builder.build(id, difficulty, rng)
				if doc.is_empty(): continue
				var key: String = doc.generator.challenge_key
				var room_age := used_layouts.find(id) + 1
				var decision_age := recent_keys.find(key) + 1
				var fresh := room_age == 0 and decision_age == 0
				has_fresh_decision = has_fresh_decision or fresh
				var family := key.get_slice("/", 0)
				var family_age := 0
				for i in range(maxi(0, recent_keys.size()-3), recent_keys.size()):
					if String(recent_keys[i]).get_slice("/", 0) == family:
						family_age = 4 - (recent_keys.size()-i)
				# Even below the rejection threshold, choose a different silhouette
				# when several unused puzzles are available in the same tier.
				var signature := Similarity.fingerprint(doc)
				var nearest := 0.0
				var matching_sets := 0
				for board: Dictionary in recent_boards:
					nearest = maxf(nearest, Similarity.similarity(signature, board))
					if board.get("set_design", "") == doc.generator.set_design: matching_sets += 1
				var resemblance := 40.0 * maxf(0.0, nearest - 0.5) + matching_sets * 4.0
				var rank := room_age * 1000.0 + decision_age * 10.0 + family_age + resemblance
				proposals.append({"id":id, "doc":doc, "fresh":fresh, "signature":signature,
					"rank":rank + _scene_preference(doc, difficulty) + rng.randf()})
		proposals.sort_custom(func(a,b): return a.rank < b.rank)
		for proposal: Dictionary in proposals:
			if round_number < 3 and has_fresh_decision and not proposal.fresh: continue
			await checks.yield_if_needed()
			attempts += 1
			candidate_started.emit(attempts)
			var doc: Dictionary = proposal.doc
			var comparison := Similarity.compare(proposal.signature, recent_boards)
			if not comparison.accepted: continue
			if not await Verifier.verify(doc, checks): continue
			return _finish(doc, proposal.id, difficulty, level_seed, attempts, comparison)
	error = "Could not verify a sufficiently different room for this seed. Generate again for another arrangement."
	return {}

func _chain_proposals(tier: int, rng: RandomNumberGenerator, used_layouts: Array,
		recent_keys: Array, recent_boards: Array, checks: Checks) -> Array:
	var proposals := []
	var tried_keys := {}
	var recent_starts := {}
	var close_history := recent_keys.slice(-20)
	for key: String in recent_keys.slice(-6):
		if not key.begins_with("chain/"): continue
		var start := key.get_slice("/",1).get_slice(">",0)
		recent_starts[start] = int(recent_starts.get(start, 0)) + 1
	for draw in CHAIN_PROPOSALS:
		await checks.yield_if_needed()
		var doc := Chains.build(tier, rng)
		var plan: Dictionary = doc.generator
		var id: String = plan.challenge_key
		if close_history.has(id) or tried_keys.has(id): continue
		var milestones := 0
		for branch: Dictionary in plan.branches:
			milestones = maxi(milestones, branch.events.size())
		if milestones < int(MIN_CHAIN_STEPS[tier-1]): continue
		tried_keys[id] = true
		var signature := Similarity.fingerprint(doc)
		var nearest := 0.0
		for previous: Dictionary in recent_boards:
			nearest = maxf(nearest, Similarity.similarity(signature, previous))
		# Seeded variation stays meaningful after the first click. Favor a
		# different source and room outline when the session already has one.
		var start: String = plan.interaction_chain.main[0]
		var rank := 32.0 * nearest + 6.0 * int(recent_starts.get(start, 0)) + rng.randf_range(0.0, 10.0)
		if used_layouts.has(id) or recent_keys.has(id): rank += 48.0
		proposals.append({"doc":doc,"id":id,"signature":signature,"rank":rank})
	proposals.sort_custom(func(a, b): return a.rank < b.rank)
	return proposals

func _finish(doc: Dictionary, id: String, tier: int, seed_value: int, attempts: int, comparison: Dictionary) -> Dictionary:
	var plan: Dictionary = doc.generator
	plan.seed = seed_value
	plan.difficulty = tier
	plan.campaign_tier = TIERS[tier-1].name
	plan.generation_method = "empty_board"
	plan.room_id = id
	plan.challenge_keys = [plan.challenge_key]
	plan.originality = comparison
	plan.candidates_tried = attempts
	return doc

func _scene_preference(doc: Dictionary, difficulty: int) -> float:
	var cast := {}
	var participants := {}
	if difficulty >= 3: _collect_participants(doc.goals.when, participants)
	var active_by_height := [0, 0, 0]
	var elevated_cast := 0
	var drops: Array = doc.generator.solution_placements
	var single_ball := false
	for row: Dictionary in doc.parts:
		var type := int(row.part_type)
		var actor := type in [36,37,68]
		var placed := (int(row.flags_3) & 0x40) != 0
		if actor and placed: cast[type] = true
		if drops.size() == 1 and row.id == drops[0].part and type in Similarity.BALLS: single_ball = true
		if not placed or not participants.has(row.id): continue
		if type in Similarity.WALLS or type in Similarity.SLOPES or type in [1,14,45]: continue
		var center_y := float(row.pos_y) + float(row.height_1) / 2
		var band := clampi(floori(3 * center_y / STAGE_HEIGHT), 0, 2)
		active_by_height[band] += 1
		if actor and band < 2: elevated_cast += 1
	var preference := -8.0 * cast.size()
	if single_ball: preference += 8.0
	# Stage scenes reserve this preference for a verified chase or a toss
	# that drives an entire rig. Room history still favors new puzzles.
	if doc.generator.get("action_scene", false): preference -= 10.0
	# A high shelf only helps the score when a placed gadget or actor there
	# takes part in the goal. Simple tiers can keep a compact stage.
	preference -= 4.0 * mini(active_by_height[0], 3)
	preference -= 4.0 * mini(elevated_cast, 2)
	if 0 not in active_by_height: preference -= 6.0
	return preference

func _collect_participants(node: Dictionary, participants: Dictionary) -> void:
	if node.kind == "not": return
	for key in ["part", "other"]:
		var id: String = node.get(key, "")
		if not id.is_empty(): participants[id] = true
	for child: Dictionary in node.get("of", []):
		_collect_participants(child, participants)
	if node.has("condition"):
		_collect_participants(node.condition, participants)

func generate_recipe(rng: RandomNumberGenerator, level_seed: int, count: int, motif: String, tree: SceneTree = null) -> Dictionary:
	error = ""
	if (count < 5 or (count > 10 and count != 13)) or motif not in ["hens", "curtains"] or (count == 13 and motif != "hens"):
		error = "Unsupported event count or generator pattern."
		return {}
	var curtains := Curtains.new() if motif == "curtains" else null
	var codec := Document.new()
	var checks := Checks.new(tree)
	for attempt in range(1, MAX_ATTEMPTS + 1):
		await checks.yield_if_needed()
		var doc := build(rng, level_seed, count) if motif == "hens" else curtains.build(rng, level_seed, count)
		var playable := codec.decode(doc, "Generated.json", false)
		if playable == null:
			error = codec.error
			return {}
		var plan: Dictionary = doc.generator
		var succeeds: bool
		if motif == "hens":
			succeeds = await verify(playable, plan, checks)
		else:
			succeeds = await curtains.verify(playable, plan, checks)
		if succeeds:
			plan.motif = motif
			plan.candidates_tried = attempt
			return doc
	error = "No verified arrangement found for seed %d." % level_seed
	return {}

func build(rng: RandomNumberGenerator, level_seed: int, total: int) -> Dictionary:
	# Every hen contributes an incoming hit and an egg laid. Each branch ends in an actor hit.
	var sizes: Array[int]
	if total == 13:
		# Three columns fit in the 400-pixel-high playfield. Five hens give
		# ten hit/lay events followed by three independent actor hits.
		sizes = [1, 1, 1]
		for extra in 2: sizes[rng.randi_range(0, 2)] += 1
	elif total % 2 == 1:
		sizes = [(total - 1) / 2]
	else:
		var hen_count := (total - 2) / 2
		var first_size := rng.randi_range(1, hen_count - 1)
		sizes = [first_size, hen_count - first_size]
	var branches := sizes.size()
	var branches_plan := []
	var placements := []
	var conditions := []
	var actor_names := PackedStringArray()
	var doc := {"format": Document.FORMAT, "version": Document.VERSION,
		"title": "Egg Relay %d" % level_seed, "music": 0, "pressure": 67, "gravity": 272,
		"parts": [], "ropes": [], "belts": []}
	for lane in branches:
		var count := sizes[lane]
		var prefix := "lane%d-" % (lane + 1)
		var x: int
		match branches:
			1: x = rng.randi_range(50, 415)
			2: x = rng.randi_range(55, 100) + 320 * lane
			3: x = rng.randi_range(46, 65) + 175 * lane
		var base_y := rng.randi_range(238, 252)
		var spacing := rng.randi_range(57, 66)
		var first_y := base_y - (count - 1) * spacing
		var starter_id := prefix + "starter"
		var egg_pos := Vector2i(x + rng.randi_range(18, 28), maxi(4, first_y - rng.randi_range(32, 45)))
		add_part(doc, starter_id, EGG, egg_pos, false)
		placements.append({"part": starter_id, "top_left": [egg_pos.x, egg_pos.y]})
		var hens: Array[String] = []
		var events := []
		var missing := rng.randi_range(0, count - 1)
		for i in count:
			var id := prefix + "hen%d" % (i + 1)
			var pos := Vector2i(x, first_y + i * spacing)
			add_part(doc, id, HEN, pos, i != missing)
			if i == missing: placements.append({"part": id, "top_left": [pos.x, pos.y]})
			conditions.append(ever_equal(id, "appearance", 3)) # The frame that releases the egg.
			var source := starter_id if i == 0 else "the egg from " + hens[i - 1]
			var previous := "" if i == 0 else hens[i - 1] + "-lays"
			events.append(node(id + "-hit", "%s activates %s on contact" % [source, id], previous))
			events.append(node(id + "-lays", "%s lays one egg" % id, id + "-hit"))
			hens.append(id)
			if i + 1 < count: x += rng.randi_range(-5, 5)
		var actor := AL if rng.randi_range(0, 1) == 0 else SID
		var actor_name := "Al" if actor == AL else "Sid"
		var directions := [" on the left", " in the middle", " on the right"] if branches == 3 else [" on the left", " on the right"]
		actor_names.append(actor_name + str(directions[lane]) if branches > 1 else actor_name)
		var actor_id := prefix + actor_name.to_lower()
		var floor_y := base_y + rng.randi_range(116, 126)
		var actor_pos := Vector2i(x + (10 if actor == AL else 15), floor_y - (40 if actor == AL else 33))
		add_part(doc, actor_id, actor, actor_pos, true)
		var floor_row := add_part(doc, prefix + "floor", FLOOR, Vector2i(x - 35, floor_y), true)
		floor_row.width_1 = 152
		floor_row.width_2 = 152
		floor_row.height_1 = 16
		floor_row.height_2 = 16
		conditions.append(ever_equal(actor_id, "state", 59 if actor == AL else 55))
		events.append(node(actor_id + "-hit", "The egg from %s hits %s" % [hens.back(), actor_id], hens.back() + "-lays"))
		branches_plan.append({"starter": starter_id, "hens": hens, "actor": actor_id, "events": events})
	if branches == 1:
		doc.goal = "Make every hen lay an egg. Hit %s with an egg." % actor_names[0]
	elif branches == 2:
		doc.goal = "Make every hen lay an egg. Hit both targets with eggs (%s)." % " and ".join(actor_names)
	else:
		doc.goal = "Make every hen lay an egg. Hit all three targets with eggs (%s, %s, and %s)." % [actor_names[0], actor_names[1], actor_names[2]]
	doc.goals = {"version": 1, "when": {"kind": "all", "of": conditions}, "delay_updates": 10}
	var depth := 2 * int(sizes.max()) + 1
	doc.generator = {"seed": level_seed, "goal_family": HEN_GOAL,
		"event_count": total, "longest_serial_chain": depth, "branches": branches_plan,
		"goal_requires": branches_plan.map(func(lane): return lane.events.back().id),
		"solution_placements": placements}
	return doc

func ever_equal(id: String, field: String, value: int) -> Dictionary:
	return {"kind": "ever", "condition": {"kind": "compare", "part": id, "field": field, "op": "eq", "value": value}}

func node(id: String, description: String, previous: String) -> Dictionary:
	return {"id": id, "description": description, "depends_on": [] if previous.is_empty() else [previous]}

func add_part(doc: Dictionary, id: String, type: int, position: Vector2i, pinned: bool) -> Dictionary:
	var definition := Document.factory(type)
	var row := {"id": id}
	for field in Document.FIELDS: row[field] = definition.get(field)
	# The editor stores the solution. Playable mode puts each unpinned part in inventory.
	row.flags_1 &= ~0x800
	if pinned: row.flags_3 |= 0x40
	row.pos_x = position.x
	row.pos_y = position.y
	doc.parts.append(row)
	return row

func verify(playable: PuzzleDefinition, plan: Dictionary, checks: Checks) -> bool:
	var runner := SimulationRunner.new(playable)
	var controls := Controls.new()
	controls.set_runner(runner)
	var by_id := {}
	for part in runner.state.parts: by_id[part.definition.goal_id] = part.index
	if not checks.place_inventory(controls, by_id, plan.solution_placements): return false
	controls.play()
	var by_hen := {}
	var egg_spawn_positions := {}
	var by_actor := {}
	var egg_parent := {}
	var verified := {}
	for lane in plan.branches:
		egg_parent[by_id[lane.starter]] = lane.starter
		for i in lane.hens.size():
			var hen: String = lane.hens[i]
			var index := int(by_id[hen])
			by_hen[index] = {"id": hen, "source": lane.starter if i == 0 else lane.hens[i - 1]}
			# The Hen factory reports its Egg's origin on the release frame.
			egg_spawn_positions[RopePhysics.xy(runner.state.parts[index]) + Vector2i(23, 35)] = hen
		by_actor[by_id[lane.actor]] = {"id": lane.actor, "source": lane.hens.back()}
	for i in MAX_UPDATES:
		await checks.yield_if_needed()
		runner.state.trace.clear()
		runner.step()
		for e in runner.state.trace:
			var index: int = e.part_index
			if e.kind == "spawn" and e.type == EGG:
				var origin := Vector2i(int(e.position[0]), int(e.position[1]))
				var hen: String = egg_spawn_positions.get(origin, "")
				if hen == "" or not verified.has(hen + "-hit"): return false
				egg_parent[index] = hen
				verified[hen + "-lays"] = e.tick
			elif e.kind == "reaction_request" and e.request > 0:
				if e.reason == "contact" and by_hen.has(index):
					if not record_hit(e, by_hen[index], egg_parent, verified): return false
				elif e.reason == "Egg impact" and by_actor.has(index):
					if not record_hit(e, by_actor[index], egg_parent, verified): return false
		if runner.state.goal.completed: break
	if not runner.state.goal.completed or verified.size() != plan.event_count: return false
	for lane in plan.branches:
		for e in lane.events:
			if not verified.has(e.id): return false
			e.observed_update = verified[e.id]
			if e.observed_update > runner.state.goal.trigger_tick: return false
			for parent in e.depends_on:
				if verified[parent] > e.observed_update: return false
	plan.goal_update = runner.state.goal.trigger_tick
	plan.completion_update = runner.state.goal.completion_tick
	# A missing starter must break its branch even with every other piece in place.
	# Use the same placement path as for the successful attempt.
	for lane in plan.branches:
		var trial := SimulationRunner.new(playable)
		var partial := Controls.new()
		partial.set_runner(trial)
		if not checks.place_inventory(partial, by_id, plan.solution_placements, lane.starter): return false
		partial.play()
		for i in MAX_UPDATES:
			await checks.yield_if_needed()
			trial.step()
			if trial.state.goal.trigger_tick >= 0: return false
			trial.state.trace.clear()
	plan.starter_omission_horizon = MAX_UPDATES
	return true

func record_hit(event: Dictionary, target: Dictionary, egg_parent: Dictionary, verified: Dictionary) -> bool:
	var id: String = target.id + "-hit"
	if verified.has(id): return true
	if egg_parent.get(event.producer) != target.source: return false
	verified[id] = event.tick
	return true
