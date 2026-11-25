extends RefCounted
## A rolling bearing operates a row of Message Machines. The authored sequence
## requires their order. Each machine is driven by the bearing on a common ramp.
const Document := preload("res://scripts/io/home_toons_document.gd")
const Controls := preload("res://scripts/ui/construction_controls.gd")
const Checks = preload("res://scripts/generation/generation_checks.gd")
const LIMIT := 480

var reference: PuzzleDefinition

func build(rng: RandomNumberGenerator, level_seed: int, total: int) -> Dictionary:
	if reference == null:
		reference = LevelReader.new(ResourceCatalog.new()).read_level("CAKE1.LEV")
	var words := ["LIGHTSPEED", "SILVERMOON", "STAGECRAFT", "CANDLEWICK"]
	var letters := str(words[rng.randi_range(0, words.size() - 1)]).left(total)
	var lanes := 1 if total == 5 else 2
	var first_size := total if lanes == 1 else rng.randi_range(maxi(2, total - 5), mini(5, total - 2))
	var document := {"format": Document.FORMAT, "version": Document.VERSION,
		"title": "Marquee %d" % level_seed, "music": 0, "gravity": 272, "pressure": 67,
		"goal": "Roll a bearing along each rail. Open the letter curtains from left to right on each rail.",
		"parts": [], "belts": [], "ropes": []}
	var branches := []
	var conditions := []
	var placements := []
	for lane in lanes:
		var count := first_size if lane == 0 else total - first_size
		var origin := Vector2i(rng.randi_range(38, 100), rng.randi_range(88, 110) + 175 * lane)
		var starter := "bearing-%d" % (lane + 1)
		var gap_shift := rng.randi_range(-2, 2)
		var events := []
		var steps := []
		for i in count:
			var offset: Vector2i = [Vector2i(11,-66), Vector2i(63,-52), Vector2i(115,-39), Vector2i(254,0), Vector2i(308,12)][i]
			if i >= 3:
				offset += Vector2i(4 * gap_shift, gap_shift)
			var id := "marquee-%d-%d" % [lane + 1, i + 1]
			var row := _part(3, id, origin + offset, true)
			var letter_index := i if lane == 0 else first_size + i
			row.wire_terminal = letters.unicode_at(letter_index)
			document.parts.append(row)
			steps.append({"kind": "compare", "part": id, "field": "appearance", "op": "eq", "value": 1})
			events.append({"id": id, "description": "The bearing opens curtain %d (%s) on rail %d." % [i + 1, letters[letter_index], lane + 1],
				"depends_on": [] if i == 0 else [events[i-1].id], "dependency_type": "goal_order"})
		var segments := count if count <= 3 else 5
		for i in segments:
			var pos := origin + Vector2i(64*i, 16*i)
			var id := "rail-%d-%d" % [lane + 1, i + 1]
			document.parts.append(_part([4,6,9,8,7][i], id, pos, true))
		var start := origin + Vector2i(0, -15)
		document.parts.append(_part(23, starter, start, false))
		placements.append({"part": starter, "top_left": [start.x, start.y]})
		conditions.append({"kind": "sequence", "of": steps})
		branches.append({"starter": starter, "events": events})
	document.goals = {"version": 1, "delay_updates": 10, "when": {"kind": "all", "of": conditions}}
	document.generator = {"seed": level_seed, "goal_family": "Operate, damage, or read a gadget",
		"event_count": total, "longest_serial_chain": maxi(first_size, total - first_size), "branches": branches,
		"chain_definition": "Ordered curtain openings. Each rail's bearing strikes each machine. Edges within a rail describe the authored reading order.",
		"goal_requires": branches.map(func(lane): return lane.events.back().id), "solution_placements": placements}
	return document

func _part(source_index: int, id: String, pos: Vector2i, pinned: bool) -> Dictionary:
	var source := reference.parts[source_index]
	var row := {"id": id}
	for key in Document.FIELDS:
		row[key] = source.get(key)
	row.pos_x = pos.x
	row.pos_y = pos.y
	row.flags_1 &= ~0x800
	row.flags_3 = (int(row.flags_3) & ~0x40) | (0x40 if pinned else 0)
	return row

func verify(playable: PuzzleDefinition, plan: Dictionary, checks: Checks = null) -> bool:
	if checks == null: checks = Checks.new()
	var runner := SimulationRunner.new(playable)
	var controls := Controls.new()
	controls.set_runner(runner)
	var by_id := {}
	for part in runner.state.parts:
		by_id[part.definition.goal_id] = part.index
	if not checks.place_inventory(controls, by_id, plan.solution_placements): return false
	controls.play()
	var expected_producer := {}
	var strikes := {}
	for lane in plan.branches:
		for e in lane.events: expected_producer[by_id[e.id]] = by_id[lane.starter]
	var seen := {}
	for tick in LIMIT:
		await checks.yield_if_needed()
		runner.state.trace.clear()
		runner.step()
		for event in runner.state.trace:
			if event.kind == "reaction_request" and event.reason == "Message Machine contact":
				if expected_producer.get(event.part_index, -1) != event.producer: return false
				strikes.get_or_add(int(event.part_index), runner.state.tick)
		for lane in plan.branches:
			var count := int(seen.get(lane.starter, 0))
			if count >= lane.events.size(): continue
			var element: Dictionary = lane.events[count]
			var index := int(by_id[element.id])
			if runner.state.parts[index].appearance == 1 and strikes.has(index):
				if count > 0 and int(lane.events[count - 1].observed_update) >= int(strikes[index]): return false
				element.contact_update = strikes[index]
				element.observed_update = runner.state.tick
				seen[lane.starter] = count + 1
		if runner.state.goal.completed: break
	if not runner.state.goal.completed: return false
	for lane in plan.branches:
		if seen.get(lane.starter, 0) != lane.events.size(): return false
	plan.goal_update = runner.state.goal.trigger_tick
	plan.completion_update = runner.state.goal.completion_tick
	for lane in plan.branches:
		var trial := SimulationRunner.new(playable)
		var partial := Controls.new()
		partial.set_runner(trial)
		if not checks.place_inventory(partial, by_id, plan.solution_placements, lane.starter): return false
		partial.play()
		for update in LIMIT:
			await checks.yield_if_needed()
			trial.state.trace.clear()
			trial.step()
			if trial.state.goal.trigger_tick >= 0: return false
	plan.starter_omission_horizon = LIMIT
	return true
