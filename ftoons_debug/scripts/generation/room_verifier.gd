extends RefCounted
## Prove the proposed route in the same tracker and construction controls as Play.
const Document := preload("res://scripts/io/home_toons_document.gd")
const Controls := preload("res://scripts/ui/construction_controls.gd")
const Checks := preload("res://scripts/generation/generation_checks.gd")

static func verify(doc: Dictionary, checks: Checks) -> bool:
	var puzzle := Document.new().decode(doc, "new-room.json", false)
	if puzzle == null or not puzzle.authored_goals.has("when"): return false
	if not doc.ropes.is_empty():
		_save_pulley_orientations(doc, puzzle)
		puzzle = Document.new().decode(doc, "new-room.json", false)
	var rule: Dictionary = doc.goals.when
	var conditions: Array = rule.of if rule.kind == "all" else [rule]
	var plan: Dictionary = doc.generator
	var branches: Array = plan.branches
	var drops: Array = plan.solution_placements
	if branches.is_empty() or branches.size() > conditions.size() or drops.is_empty(): return false
	var inventory := {}
	for p in puzzle.inventory_parts: inventory[p.goal_id] = true
	if inventory.size() != drops.size(): return false
	for drop: Dictionary in drops:
		if not inventory.erase(drop.part): return false
	var paths := []
	var terminals := []
	for i in branches.size():
		# An authored guard after the sequences can watch a hazard throughout
		# the run. Branches describe the visible progress milestones.
		var sequence: Dictionary = conditions[i]
		if sequence.kind != "sequence" or sequence.of.size() != branches[i].events.size(): return false
		paths.append("0/%d" % i if rule.kind == "all" else "0")
		terminals.append({"kind":"ever", "condition":sequence.of.back()})
	var limit := int(plan.get("replay_limit", 450))
	var manual := await _trial(puzzle, drops, checks, "manual", limit, paths)
	if not manual.get("won", false): return false
	var saved := await _trial(puzzle, drops, checks, "preset", limit, paths)
	if not saved.get("won", false): return false
	# Expose the physical endpoint to each omission run, independently of all the
	# earlier milestones. A marble reaching its bin by a shortcut still counts.
	puzzle.authored_goals = {"version":1, "delay_updates":0, "when":{"kind":"all", "of":terminals}}
	var horizon := maxi(manual.finish, saved.finish) + 60
	var omissions := []
	for drop: Dictionary in drops:
		var trial := await _trial(puzzle, drops, checks, "omit", horizon, [], drop.part)
		if trial.is_empty() or trial.trigger >= 0: return false
		omissions.append({"part":drop.part, "observed_through":horizon, "endpoint_reached":false})
	if drops.size() > 1:
		var empty := await _trial(puzzle, [], checks, "manual", horizon, [])
		if empty.is_empty() or empty.trigger >= 0: return false
	plan.goal_update = saved.trigger
	plan.completion_update = saved.finish
	plan.starter_omission_horizon = horizon
	plan.omission_checks = omissions
	plan.goal_requires = []
	plan.event_count = 0
	plan.longest_serial_chain = 0
	var shared_steps := {}
	var depth := {"":0}
	for i in branches.size():
		var events: Array = branches[i].events
		if saved.times[i].size() != events.size(): return false
		var previous := ""
		for j in events.size():
			var event: Dictionary = events[j]
			var shared: String = event.get("shared_step", "")
			if shared_steps.has(shared):
				var first: Dictionary = shared_steps[shared]
				if first.observed_update != saved.times[i][j]: return false
				event.id = first.id
				event.depends_on = first.depends_on
				event.observed_update = first.observed_update
			else:
				event.id = "route-%d-step-%d" % [i+1, j+1]
				event.depends_on = [] if previous.is_empty() else [previous]
				event.observed_update = saved.times[i][j]
				depth[event.id] = int(depth[previous]) + 1
				plan.event_count += 1
				if not shared.is_empty(): shared_steps[shared] = event
			previous = event.id
		plan.goal_requires.append(previous)
		plan.longest_serial_chain = maxi(plan.longest_serial_chain, int(depth[previous]))
	return true

static func _save_pulley_orientations(doc: Dictionary, puzzle: PuzzleDefinition) -> void:
	# Sketches store the route. The native editor computes each wheel's drawing
	# frame and entry/exit knots when the player connects it. Save the same
	# orientation for the preset arrangement and the binary export.
	var runner := SimulationRunner.new(puzzle)
	runner.place_solution()
	for rope in runner.state.ropes:
		RopeEditor.refresh_pulleys(runner.state, rope.route, rope.slots, runner.world_physics.kernel)
		for index: int in rope.route.slice(1, -1):
			var part := runner.state.parts[index]
			var anchors := RopePhysics.anchors(part)
			var row: Dictionary = doc.parts[index]
			row.appearance = part.appearance
			row.rope_1_connect_pos_x = anchors[0].x
			row.rope_1_connect_pos_y = anchors[0].y
			row.rope_2_connect_pos_x = anchors[1].x
			row.rope_2_connect_pos_y = anchors[1].y

static func _trial(puzzle: PuzzleDefinition, drops: Array, checks: Checks, mode: String,
		limit: int, paths: Array, omit := "") -> Dictionary:
	var runner := SimulationRunner.new(puzzle)
	var controls := Controls.new()
	controls.set_runner(runner)
	if mode == "preset":
		runner.place_solution()
	else:
		var by_id := {}
		for p in runner.state.parts: by_id[p.definition.goal_id] = p.index
		if not checks.place_inventory(controls, by_id, drops, omit): return {}
	var times := []
	for path in paths: times.append([])
	runner.run()
	for tick in limit:
		await checks.yield_if_needed()
		runner.state.trace.clear()
		runner.step()
		for i in paths.size():
			var progress := int(runner.state.goal.vars.get(paths[i], 0))
			if progress > times[i].size(): times[i].append(runner.state.tick)
		if runner.state.goal.completed: break
	return {"won":runner.state.goal.completed, "finish":runner.state.goal.completion_tick,
		"trigger":runner.state.goal.trigger_tick, "times":times}
