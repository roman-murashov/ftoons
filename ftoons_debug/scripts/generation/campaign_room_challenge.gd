extends RefCounted
## Restage a campaign objective by giving the player control of its triggers.
## Each candidate signal was previously suppressed in a campaign replay.
## The complete placement and observed signals are tested again on the new set.
const Rooms := preload("res://scripts/generation/campaign_room_source.gd")
const Architecture := preload("res://scripts/generation/room_architecture.gd")
const Route := preload("res://scripts/generation/room_route.gd")
const Document := preload("res://scripts/io/home_toons_document.gd")
const Controls := preload("res://scripts/ui/construction_controls.gd")
const Checks := preload("res://scripts/generation/generation_checks.gd")
# Each chain contains [producer index, recipient index, request value, reason].
# Derived from the individual trials documented in docs/random_levels/request_dependence.md.
const SIGNALS := preload("res://scripts/generation/campaign_room_signals.json")
const STAGE := Rect2i(0, 0, 552, 400)

static func candidates(tier: int) -> Array[String]:
	var result: Array[String] = []
	for room in Rooms.candidates(tier):
		if SIGNALS.data.has(room): result.append(room)
	return result

func generate(source: String, tier: int, level_seed: int, rng: RandomNumberGenerator, checks: Checks) -> Dictionary:
	if not SIGNALS.data.has(source): return {}
	var doc := Rooms.build(source)
	if doc.is_empty(): return {}
	var options: Dictionary = SIGNALS.data[source]
	var starters: Array = options.starters[rng.randi_range(0, options.starters.size()-1)]
	var chosen := []
	var drops := []
	for row: Dictionary in doc.parts:
		row.flags_1 = int(row.flags_1) & ~0x800
		row.flags_3 = int(row.flags_3) | 0x40
	for slot in starters:
		var chain: Array = options.signals[str(int(slot))]
		var row: Dictionary = doc.parts[int(slot)]
		row.flags_3 = int(row.flags_3) & ~0x40
		chosen.append(chain)
		drops.append({"part":row.id, "top_left":[row.pos_x, row.pos_y]})
	# A different inventory changes which choices the player makes. If the
	# choices match the source, relocate a real free-standing trigger.
	var original: Array = doc.generator.solution_placements.map(func(d): return d.part)
	var revised: Array = drops.map(func(d): return d.part)
	var changed_choice := original.size() != revised.size()
	for id in revised:
		if not original.has(id): changed_choice = true
	if not changed_choice or rng.randf() < 0.25:
		var selected := rng.randi_range(0, chosen.size()-1)
		var row: Dictionary = doc.parts[int(chosen[selected][0][0])]
		var delta := Vector2i(0, -rng.randi_range(7, 24)) if int(row.flags_3) & 8 else Vector2i(0, -16)
		var shifted := Vector2i(row.pos_x, row.pos_y) + delta
		if STAGE.encloses(Rect2i(shifted, Vector2i(row.width_1,row.height_1))):
			row.pos_y = shifted.y
			drops[selected].top_left = [shifted.x, shifted.y]
		elif not changed_choice: return {}
	# Swept occupied rectangles from the native solution, in 16-pixel tiles.
	# Prevent new beams and platforms from obstructing actors and projectiles.
	var route_space: Array[Rect2i] = []
	for bounds in options.clearance:
		route_space.append(Rect2i(int(bounds[0])*16, int(bounds[1])*16, int(bounds[2])*16, int(bounds[3])*16))
	var art := Architecture.compose(doc,rng,route_space)
	if art.is_empty(): return {}
	var puzzle := Document.new().decode(doc,"generated.json",false)
	if puzzle == null: return {}
	var limit := int(doc.generator.campaign_finish) + 90
	var manual := await _replay(puzzle, chosen, drops, checks, limit, "manual")
	if not manual.get("won",false): return {}
	var preset := await _replay(puzzle, chosen, drops, checks, limit, "solution")
	if not preset.get("won",false): return {}
	for i in chosen.size():
		# A restaged route may cut across the original sequence. Retain the
		# contiguous signals the player and preset runs both actually produced.
		var witnessed := mini(manual.times[i].size(), preset.times[i].size())
		if witnessed == 0: return {}
		chosen[i] = chosen[i].slice(0, witnessed)
	for omit in drops:
		var result := await _replay(puzzle, [], drops, checks, limit, omit.part)
		if not result.get("no_trigger",false): return {}
	if drops.size() > 1:
		var empty := await _replay(puzzle, [], [], checks, limit, "empty")
		if not empty.get("no_trigger",false): return {}
	_finish(doc, source, tier, level_seed, art, chosen, drops, preset, limit)
	return doc

func _replay(puzzle: PuzzleDefinition, chains: Array, drops: Array, checks: Checks, limit: int, mode: String) -> Dictionary:
	var runner := SimulationRunner.new(puzzle)
	var controls := Controls.new()
	controls.set_runner(runner)
	if mode == "solution": controls.reset(true)
	else:
		var by_id := {}
		for part in runner.state.parts: by_id[part.definition.goal_id] = part.index
		if not checks.place_inventory(controls, by_id, drops, mode): return {}
	controls.play()
	var times := []
	for chain in chains: times.append([])
	for tick in limit:
		await checks.yield_if_needed()
		runner.state.trace.clear()
		runner.step()
		if not str(runner.state.goal.error).is_empty(): return {}
		if not chains.is_empty() and (runner.state.goal.trigger_tick < 0 or runner.state.goal.trigger_tick == runner.state.tick):
			for event: Dictionary in runner.state.trace:
				if event.kind != "reaction_request": continue
				var producer := int(event.producer)
				var recipient := int(event.part_index)
				if producer < 0 or recipient < 0 or runner.state.parts[producer].spawned or runner.state.parts[recipient].spawned: continue
				for i in chains.size():
					var n: int = times[i].size()
					if n >= chains[i].size(): continue
					var signature: Array = chains[i][n]
					if producer == int(signature[0]) and recipient == int(signature[1]) \
							and int(event.request) == int(signature[2]) and event.reason == signature[3]:
						times[i].append(runner.state.tick)
		if runner.state.goal.completed or (chains.is_empty() and runner.state.goal.trigger_tick >= 0): break
	return {"won":runner.state.goal.completed, "no_trigger":runner.state.goal.trigger_tick < 0,
		"times":times,"trigger":runner.state.goal.trigger_tick,"finish":runner.state.goal.completion_tick}

func _finish(doc: Dictionary, source: String, tier: int, level_seed: int, art: Dictionary, chains: Array,
		drops: Array, replay: Dictionary, limit: int) -> void:
	var labels := Route.new(int(chains[0][0][0]), doc.parts)
	var branches := []
	var last := []
	var total := 0
	var longest := 0
	for i in chains.size():
		var events := []
		for j in chains[i].size():
			var signal_: Array = chains[i][j]
			var producer := labels.part_name(int(signal_[0]))
			var receiver := labels.part_name(int(signal_[1]))
			var reason := String(signal_[3])
			var description := _describe(reason, producer, receiver)
			events.append({"id":"interaction-%d-%d" % [i,j], "description":description,
				"depends_on":[] if j == 0 else [events.back().id], "observed_update":replay.times[i][j]})
		last.append(events.back().id)
		longest = maxi(longest, events.size()+1)
		total += events.size()
		branches.append({"starter":drops[i].part,"events":events})
	branches.back().events.append({"id":"objective", "description":doc.goal,
		"depends_on":last, "observed_update":replay.trigger})
	doc.title = "%s at the %s" % [String(doc.title).trim_suffix("!").trim_suffix("."), art.theme]
	var key := "campaign/" + String(doc.goal).to_lower().trim_suffix(".")
	doc.generator.merge({"seed":level_seed,"campaign_tier":Rooms.TIERS[tier-1],"difficulty":tier,
		"room_id":source,"source_room":source,"room_name":"%s · %s" % [art.theme,art.layout],
		"challenge_key":key, "challenge_keys":[key],
		"architecture":art,"mechanism":branches[0].events[0].description, "branches":branches,
		"event_count":total+1,"longest_serial_chain":longest,"goal_requires":["objective"],
		"solution_placements":drops, "goal_update":replay.trigger,"completion_update":replay.finish,
		"starter_omission_horizon":limit},true)

func _describe(reason: String, producer: String, receiver: String) -> String:
	match reason:
		"sight": return "%s spots %s" % [receiver, producer]
		"belt drive": return "%s drives %s through the belt" % [producer, receiver]
		"outlet power": return "%s switches on %s" % [producer, receiver]
		"rope pulls Pistol trigger": return "%s pulls the trigger on %s" % [producer, receiver]
		"rope event": return "%s pulls the rope attached to %s" % [producer, receiver]
		"Dragon fire": return "%s breathes fire on %s" % [producer, receiver]
		"Chow-Man accepts food", "Eunice stores contacting object":
			return "%s takes %s" % [receiver, producer]
		"Teeter-Totter impact": return "%s tips %s" % [producer, receiver]
		"Hair-Dryer actor reaction": return "%s blows air at %s" % [producer, receiver]
		"hard-object impact": return "%s strikes %s" % [producer, receiver]
	return "%s touches %s" % [receiver, producer]
