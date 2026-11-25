extends RefCounted
## Build new routes into a furnished campaign room and keep only witnessed solutions.
const Rooms := preload("res://scripts/generation/campaign_room_source.gd")
const Architecture := preload("res://scripts/generation/room_architecture.gd")
const Route := preload("res://scripts/generation/room_route.gd")
const Checks := preload("res://scripts/generation/generation_checks.gd")
const Document := preload("res://scripts/io/home_toons_document.gd")
const Controls := preload("res://scripts/ui/construction_controls.gd")
const STAGE := Rect2i(0, 0, 552, 400)
const TARGETS := [2,3,13,22,24,35,36,37,39,40,41,43,47,48,49,50,51,63,68,78,80,84]
const LEDGES := [26,27,28,29,82,83]
const RECEIVERS := [3,22,24,35,68,78]
const ROLLERS := [7,8,9,10,11,31,32,33,34]
const UPDATES := 105

func generate(source: String, tier: int, level_seed: int, rng: RandomNumberGenerator, checks: Checks, recent_keys: Array = []) -> Dictionary:
	var base: Dictionary = Rooms.build(source)
	if base.is_empty(): return {}
	var counts := {}
	for row: Dictionary in base.parts:
		var type := int(row.part_type)
		counts[type] = int(counts.get(type, 0)) + 1
		row.flags_1 = int(row.flags_1) & ~0x800
		row.flags_3 = int(row.flags_3) | 0x40
	# Exclude rooms dominated by the two repeaters from the earlier generator.
	if int(counts.get(42,0)) > 2 or int(counts.get(69,0)) > 2: return {}
	var architecture := Architecture.compose(base, rng)
	if architecture.is_empty(): return {}
	base.goals = {}
	for attempt in 4:
		await checks.yield_if_needed()
		var doc: Dictionary = base.duplicate(true)
		var drops := []
		var starters := []
		var required := []
		var branches := 2 if tier >= 3 else 1
		for branch in branches:
			var choice := _add_station(doc, rng, tier, starters, recent_keys)
			if choice.is_empty(): break
			starters.append(choice.slot)
			drops.append_array(choice.drops)
			required.append(choice.receiver)
		if starters.size() < branches: continue
		var codec := Document.new()
		var puzzle := codec.decode(doc,"Generated.json",false)
		if puzzle == null: continue
		var runner := SimulationRunner.new(puzzle)
		var controls := Controls.new()
		controls.set_runner(runner)
		var by_id := {}
		for part in runner.state.parts: by_id[part.definition.goal_id] = part.index
		if not checks.place_inventory(controls, by_id, drops): continue
		var routes: Array[Route] = []
		for slot: int in starters: routes.append(Route.new(slot, doc.parts))
		controls.play()
		var complete_route_at := -1
		for update in UPDATES:
			await checks.yield_if_needed()
			runner.state.trace.clear()
			runner.step()
			var strong := true
			var ready := true
			for route in routes:
				route.observe(runner)
				strong = strong and int(route.result.get("score",0)) >= 95
				ready = ready and int(route.result.get("score",0)) >= 60
			if ready and complete_route_at == -1: complete_route_at = update
			if strong or (complete_route_at >= 0 and update - complete_route_at >= 20): break
		var good := true
		for i in routes.size():
			var route := routes[i]
			good = good and not route.result.is_empty() and (int(required[i]) < 0 or route.first.get("slot",-1) == required[i])
		if not good: continue
		var plan := _finish(doc, routes, drops, architecture, source, tier, level_seed)
		var final_puzzle := codec.decode(doc,"Generated.json",false)
		if final_puzzle == null: continue
		if await _verify(final_puzzle, drops, by_id, checks, plan):
			doc.generator = plan
			return doc
	return {}

func _add_station(doc: Dictionary, rng: RandomNumberGenerator, tier: int, starters: Array, recent_keys: Array) -> Dictionary:
	var ports := []
	var new_receiver := (tier in [2,4] and starters.is_empty()) or rng.randf() < 0.25
	var receivers := RECEIVERS.filter(func(t): return not recent_keys.has("delivery/operate-%d" % t))
	if receivers.is_empty(): receivers = RECEIVERS
	for i in doc.parts.size():
		var row: Dictionary = doc.parts[i]
		var rect := _bounds(row)
		if rect.position.y < 49 or not STAGE.intersects(rect): continue
		var is_ledge := int(row.part_type) in LEDGES and rect.size.x >= 45
		var is_target := int(row.part_type) in TARGETS
		if new_receiver and not is_ledge: continue
		if not new_receiver and not is_target and not is_ledge: continue
		ports.append({"slot":i, "rank":rng.randf() + (0.85 if is_target else 0.0)})
	ports.sort_custom(func(a,b): return a.rank > b.rank)
	for port: Dictionary in ports:
		var target: Dictionary = doc.parts[int(port.slot)]
		var rect := _bounds(target)
		for sample in 4:
			var receiver := {}
			var type := int(target.part_type)
			var surface := rect
			if new_receiver:
				type = receivers[rng.randi_range(0, receivers.size()-1)]
				if doc.parts.any(func(p): return String(p.id).begins_with("receiver-") and int(p.part_type) == type): continue
				receiver = Document.factory_row(type, "receiver-%d" % (starters.size()+1))
				var size := Vector2i(receiver.width_1, receiver.height_1)
				if type == 35: size = Vector2i(32,26)
				if size.x > rect.size.x + 20: continue
				var start := maxi(2,rect.position.x-8)
				var end := mini(STAGE.end.x-size.x-2, rect.end.x-size.x+8)
				if start > end: continue
				var pos := Vector2i(rng.randi_range(start,end),rect.position.y-size.y)
				if not int(receiver.flags_3) & 8:
					pos = Vector2i(((pos.x+91)&~15)-91, ((pos.y+8)&~15)-8)
				surface = Rect2i(pos,size)
				if not _clear(doc, surface): continue
				receiver.pos_x = pos.x
				receiver.pos_y = pos.y
				if tier not in [2,4]: receiver.flags_3 = int(receiver.flags_3) | 0x40
			var payload_type: int = ROLLERS[rng.randi_range(0,ROLLERS.size()-1)]
			match type:
				36: payload_type = 56
				37: payload_type = 57
				68: payload_type = 58 if rng.randf() < 0.6 else payload_type
				80: payload_type = [54,56,57,58][rng.randi_range(0,3)]
			if starters.any(func(previous): return int(doc.parts[previous].part_type) == payload_type): continue
			var payload := Document.factory_row(payload_type, "delivery-%d" % (starters.size()+1))
			# The zero-extents factory ball templates derive their size from the sprite.
			# Use a conservative clearance here; the native placement check is decisive.
			var size := Vector2i(maxi(16,payload.width_1),maxi(16,payload.height_1))
			var x := rng.randi_range(surface.position.x+2,maxi(surface.position.x+2,surface.end.x-4)) - (size.x >> 1)
			var y := surface.position.y-size.y-rng.randi_range(16,81)
			var drop := Rect2i(Vector2i(x,y),size)
			if not _clear(doc,drop): continue
			var separate := true
			for previous: int in starters:
				if absi(int(doc.parts[previous].pos_x)-x) < 70: separate = false
			if not separate: continue
			payload.pos_x = x
			payload.pos_y = y
			var drops := []
			var required := -1
			if new_receiver:
				required = doc.parts.size()
				doc.parts.append(receiver)
				if not int(receiver.flags_3) & 0x40: drops.append(_drop(receiver))
			var slot: int = doc.parts.size()
			doc.parts.append(payload)
			drops.append(_drop(payload))
			return {"slot":slot,"receiver":required,"drops":drops}
	return {}

func _bounds(row: Dictionary) -> Rect2i:
	return Rect2i(int(row.pos_x),int(row.pos_y),maxi(1,int(row.width_1)),maxi(1,int(row.height_1)))

func _clear(doc: Dictionary, area: Rect2i) -> bool:
	if not STAGE.encloses(area): return false
	for row: Dictionary in doc.parts:
		if int(row.part_type) not in [1,14,76] and area.intersects(_bounds(row)): return false
	return true

func _drop(row: Dictionary) -> Dictionary:
	return {"part":row.id,"top_left":[row.pos_x,row.pos_y]}

func _finish(doc: Dictionary, routes: Array[Route], drops: Array, art: Dictionary, source: String, tier: int, level_seed: int) -> Dictionary:
	var conditions := []
	var descriptions := PackedStringArray()
	var branches := []
	var goals := []
	var families := PackedStringArray()
	var keys := []
	var total_events := 0
	var longest_branch := 0
	for route in routes:
		var result := route.result
		conditions.append(result.condition)
		descriptions.append(result.description + ".")
		branches.append({"starter":route.source,"events":result.events})
		longest_branch = maxi(longest_branch, result.events.size())
		total_events += result.events.size()
		goals.append(result.events.back().id)
		if not families.has(result.family): families.append(result.family)
		if not keys.has(result.challenge_key): keys.append(result.challenge_key)
	doc.title = "%s at the %s" % [routes[0].result.title, art.theme]
	doc.goal = " ".join(descriptions)
	doc.goals = {"version":1,"delay_updates":8,"when":conditions[0] if conditions.size()==1 else {"kind":"all","of":conditions}}
	return {"seed":level_seed,"campaign_tier":["CAKE","BRAN","HARD","LOON"][tier-1],"difficulty":tier,
		"challenge_key":keys[0], "challenge_keys":keys,
		"room_id":source, "source_room":source, "room_name":"%s · %s" % [art.theme, art.layout],
		"architecture":art, "mechanism":doc.goal, "goal_family":", ".join(families), "branches":branches,
		"event_count":total_events, "longest_serial_chain":longest_branch,"goal_requires":goals,"solution_placements":drops}

func _verify(puzzle: PuzzleDefinition, drops: Array, by_id: Dictionary, checks: Checks, plan: Dictionary) -> bool:
	# Native placement and Place Solution can differ in insertion order. Both
	# construction paths must actually win with the shipped executable goal.
	for mode in ["placed","solution"]:
		var runner := SimulationRunner.new(puzzle)
		var controls := Controls.new()
		controls.set_runner(runner)
		if mode == "solution": controls.reset(true)
		elif not checks.place_inventory(controls, by_id, drops): return false
		controls.play()
		var reached := []
		reached.resize(plan.branches.size())
		reached.fill(0)
		for tick in UPDATES + 12:
			await checks.yield_if_needed()
			runner.state.trace.clear()
			runner.step()
			# Read the actual tracker on the same run the Place solution button uses.
			if mode == "solution":
				for i in plan.branches.size():
					var path := "0" if reached.size()==1 else "0/%d" % i
					var count := int(runner.state.goal.vars.get(path,0))
					if count > int(reached[i]):
						plan.branches[i].events[count-1].observed_update = runner.state.tick
						reached[i] = count
			if runner.state.goal.completed: break
		if not runner.state.goal.completed: return false
		if mode == "solution":
			plan.goal_update = runner.state.goal.trigger_tick
			plan.completion_update = runner.state.goal.completion_tick
	plan.omission_checks = []
	var omission_horizon := clampi(2 * int(plan.completion_update), 60, UPDATES + 12)
	for drop: Dictionary in drops:
		var runner := SimulationRunner.new(puzzle)
		var controls := Controls.new()
		controls.set_runner(runner)
		if not checks.place_inventory(controls, by_id, drops, drop.part): return false
		controls.play()
		for tick in omission_horizon:
			await checks.yield_if_needed()
			runner.state.trace.clear()
			runner.step()
			if runner.state.goal.trigger_tick >= 0: return false
		plan.omission_checks.append({"part":drop.part,"observed_through":runner.state.tick,"goal_triggered":false})
	plan.starter_omission_horizon = omission_horizon
	return true
