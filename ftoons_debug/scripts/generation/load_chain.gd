extends RefCounted
## A released load can strike a receiver itself or power one or two rope outputs.
const Scene := preload("res://scripts/generation/action_rooms.gd")
const DESTINATIONS := [
	["piano break", "piano impact", "tip"],
	["piano break", "piano impact", "whistle", "feed"],
	["piano impact", "whistle", "feed", "vacuum", "shutter", "piano delivery"],
	["whistle", "feed", "vacuum", "shutter", "piano delivery"],
]

static func build(doc: Dictionary, tier: int, rng: RandomNumberGenerator, kit: Dictionary) -> Dictionary:
	var choices: Array = DESTINATIONS[tier-1]
	var finish: String = choices[rng.randi_range(0, choices.size()-1)]
	var piano := finish in ["piano break", "piano impact"]
	var hoist := tier >= 3 or (finish != "tip" and rng.randf() < (0.29 if tier == 1 else 0.64))
	var double := tier >= 3 and not piano and finish != "shutter" and rng.randf() < (0.48 if tier == 4 else 0.18)
	var booth := Vector2i(5+16*rng.randi_range(0,2),136-16*rng.randi_range(0,1))
	var pivot := Vector2i(277+16*rng.randi_range(-1,0),216-16*rng.randi_range(0,1))
	var route := Scene._route()
	var steps := []
	var placeable := []
	var chambers := [route]
	var name := ""
	var goal := ""
	var family := "Operate, damage, or read a gadget"
	var load_name := "Piano" if piano else "Anvil"
	var weight := pivot+Vector2i(42 if piano else 47,-66 if hoist else -116)
	Scene._piece(doc, "load", 60 if piano else 61, weight)
	if hoist:
		_hoist(doc, route, kit, booth, weight, piano, tier >= 3 and rng.randf() < 0.55, placeable)
		steps.append("scissors release "+load_name.to_lower())
	else:
		_drop_shaft(doc, kit, weight, piano, rng)
		placeable.append("load")
		steps.append("falling "+load_name.to_lower())
		Scene._step(route, _test("load", "y", "gt", weight.y+25), "The %s falls down the shaft." % load_name)
	if piano:
		var floor_y := pivot.y+108
		_piano(doc, route, kit, pivot, floor_y, finish == "piano impact")
		steps.append("piano hits actor" if finish == "piano impact" else "piano breaks on deck")
		name = "Piano Drop" if finish == "piano break" else "The Piano Lesson"
		goal = "Break the Piano on the lower deck." if finish == "piano break" else "Drop the Piano onto Sid on the lower deck."
		if finish == "piano impact": family = "Reach an action or animation milestone"
	else:
		_lever(doc, route, kit, pivot)
		steps.append("anvil tips lever")
		if double:
			var second := Scene._fork(route)
			_shutter(doc, second, kit, pivot, placeable)
			chambers.append(second)
		match finish:
			"tip":
				Scene._step(route, _test("teeter", "appearance", "ge", 2), "The lever reaches the other side.")
				name = "The Counterbalance"
				goal = "Use the Anvil to tip the Teeter-Totter."
			"whistle":
				_whistle(doc, route, kit, pivot, hoist, placeable)
				steps.append("lever blows whistle")
				name = "The Lunch Signal"
				goal = "Use the falling Anvil to blow the lunch whistle."
			"feed", "vacuum", "piano delivery":
				_hatch(doc, route, kit, pivot, finish, placeable)
				steps.append("lever opens hatch")
				if finish == "feed":
					steps.append("hatch feeds sid")
					name = "Supper by Hoist"
					goal = "Deliver the cheese through the hatch to Sid in the lower room."
					family = "Reach an action or animation milestone"
				elif finish == "vacuum":
					steps.append_array(["bearing closes switch","vacuum collects marble"])
					name = "The Overhead Switch"
					goal = "Drop the bearing onto the outlet switch so the vacuum collects the marble."
					family = "Vacuum up this part"
				else:
					steps.append("hatch drops piano onto stage")
					name = "Sound Check"
					goal = "Use the Anvil to open the hatch and drop the Piano onto the lower deck."
			"shutter":
				_shutter(doc, route, kit, pivot, placeable)
				steps.append_array(["lever fires pistol","shot lights bomb","blast clears shutter"])
				name = "Strike the Set"
				goal = "Use the dropping Anvil to pull the trigger and clear the short shutter."
	if double:
		name = "The Split Hoist"
		goal = goal.trim_suffix(".") + " and knock out the shutter in the other bay."
	return {"name":name, "goal":goal, "family":family, "routes":chambers, "steps":steps,
		"side_steps":["lever fires pistol","shot lights bomb","blast clears shutter"] if double else [],
		"placeable":placeable, "set_design":"load/"+("hoist" if hoist else "shaft")+"/"+finish}

static func _hoist(doc: Dictionary, route: Dictionary, kit: Dictionary, booth: Vector2i,
		weight: Vector2i, piano: bool, gap: bool, placeable: Array) -> void:
	var cutter := booth+Vector2i(203,-49)
	var roof_y := booth.y-112
	Scene._wall(doc,"booth-roof",kit.beam,booth.x,roof_y,272)
	Scene._wall(doc,"booth-jamb",kit.pier,booth.x,roof_y+16,16,96)
	Scene._wall(doc,"booth-end",kit.pier,booth.x+256,roof_y+16,16,96)
	if gap:
		Scene._wall(doc,"entry",kit.beam,booth.x,booth.y,96)
		Scene._wall(doc,"bridge",kit.beam,booth.x+96,booth.y,64)
		Scene._wall(doc,"cutting-deck",kit.beam,booth.x+160,booth.y,112)
		placeable.append("bridge")
	else:
		Scene._wall(doc,"booth-deck",kit.beam,booth.x,booth.y,272)
	Scene._piece(doc,"al",36,booth+Vector2i(43,-37))
	Scene._piece(doc,"shears",16,cutter).flags_2 |= 16
	Scene._piece(doc,"head-wheel",17,Vector2i(weight.x+(25 if piano else 19),booth.y-80))
	Scene._piece(doc,"cut-wheel",17,Vector2i(cutter.x+21,booth.y-88))
	Scene._piece(doc,"tie",15,Vector2i(cutter.x+22,booth.y+26))
	Scene._rope(doc,"hoist",["load","head-wheel","cut-wheel","tie"],[0,0])
	Scene._step(route, Scene._reaction("al","shears","sight"),"Al sees the cutting station upstairs.")
	if gap:
		Scene._step(route, Scene._event("contact","al","bridge"),"Al crosses the catwalk.")
	Scene._step(route, Scene._reaction("al","shears","Scissors contact"),"Al reaches the shears.")
	Scene._step(route, Scene._event("rope_cut","shears","hoist"),"Al cuts the rope and releases the hanging load.")
	placeable.append("shears")

static func _drop_shaft(doc: Dictionary, kit: Dictionary, at: Vector2i, piano: bool, rng: RandomNumberGenerator) -> void:
	var left := at.x-51-16*rng.randi_range(0,1)
	var width := (77 if piano else 56)+at.x-left+46
	Scene._wall(doc,"shaft-arch",kit.beam,left,at.y-31,width)
	Scene._wall(doc,"shaft-post",kit.pier,left,at.y-15,16,128)
	Scene._wall(doc,"shaft-end",kit.pier,left+width-16,at.y-15,16,112)

static func _piano(doc: Dictionary, route: Dictionary, kit: Dictionary, pivot: Vector2i, floor_y: int, sid: bool) -> void:
	Scene._wall(doc,"stage",kit.beam,pivot.x,floor_y,240)
	Scene._wall(doc,"backdrop",kit.pier,pivot.x+224,floor_y-128,16,128)
	Scene._wall(doc,"side-balcony",kit.beam,pivot.x+143,floor_y-128,81)
	if sid:
		Scene._piece(doc,"sid",37,Vector2i(pivot.x+68,floor_y-28))
		Scene._step(route, Scene._reaction("load","sid","Piano broke"),"The Piano strikes Sid and breaks.")
		Scene._step(route, Scene._event("deactivated","sid","load"),"Sid disappears into the broken Piano.")
	else:
		Scene._step(route, Scene._reaction("load","stage","Piano broke"),"The Piano breaks on the stage floor.")
		Scene._step(route, _test("load","appearance","eq",7),"The Piano reaches its broken pose.")

static func _lever(doc: Dictionary, route: Dictionary, kit: Dictionary, pivot: Vector2i) -> void:
	Scene._piece(doc,"teeter",3,pivot)
	Scene._wall(doc,"catch-shelf",kit.beam,pivot.x+80,pivot.y+64,80)
	Scene._wall(doc,"catch-stop",kit.pier,pivot.x+144,pivot.y,16,64)
	Scene._wall(doc,"catch-brace",kit.pier,pivot.x+80,pivot.y+80,16,48)
	Scene._step(route,Scene._reaction("teeter","load","Teeter-Totter impact"),"The falling Anvil tips the lever.")

static func _whistle(doc: Dictionary, route: Dictionary, kit: Dictionary, pivot: Vector2i,
		hoist: bool, placeable: Array) -> void:
	Scene._piece(doc,"whistle",53,Vector2i(445,pivot.y+14))
	Scene._piece(doc,"guide",17,Vector2i(394,pivot.y+87))
	Scene._rope(doc,"signal-line",["teeter","guide","whistle"],[0,0])
	Scene._wall(doc,"platform",kit.beam,421,368,128)
	Scene._wall(doc,"platform-wall",kit.pier,533,288,16,80)
	Scene._wall(doc,"platform-roof",kit.beam,485,272,64)
	Scene._piece(doc,"sid",37,Vector2i(454,340))
	Scene._step(route,Scene._reaction("whistle","teeter","rope event"),"The line pulls the Lunch Whistle.")
	Scene._step(route,Scene._reaction("sid","whistle","Lunch Whistle"),"Sid hears the whistle.")
	placeable.append("guide")
	if hoist: placeable.append("whistle")

static func _hatch(doc: Dictionary, route: Dictionary, kit: Dictionary, pivot: Vector2i,
		finish: String, placeable: Array) -> void:
	var door_y := pivot.y+23
	var delivery := "delivery"
	Scene._piece(doc,"hatch",78,Vector2i(442,door_y))
	Scene._piece(doc,"guide",17,Vector2i(403,pivot.y+70))
	Scene._rope(doc,"hatch-line",["teeter","guide","hatch"],[0,0])
	match finish:
		"feed": Scene._piece(doc,delivery,57,Vector2i(465,door_y-41))
		"vacuum": Scene._piece(doc,delivery,31,Vector2i(465,door_y-46))
		"piano delivery": Scene._piece(doc,delivery,60,Vector2i(445,door_y-45))
	Scene._step(route,Scene._reaction("hatch","teeter","rope event"),"The lever pulls the hatch rope.")
	Scene._step(route,_test("hatch","appearance","gt",0),"The hatch swings open.")
	Scene._step(route,_test(delivery,"y","gt",door_y+4),"The delivery falls to the lower station.")
	placeable.append("guide")
	if finish == "vacuum":
		var s := Vector2i(458,pivot.y+102)
		var lever := Scene._piece(doc,"switch",2,s)
		lever.outlet_plugged_1 = doc.parts.size()
		Scene._piece(doc,"vacuum",13,s+Vector2i(-239,-14))
		Scene._piece(doc,"marble",11,s+Vector2i(-165,46))
		Scene._wall(doc,"pump-floor",kit.beam,251,s.y+61,128)
		Scene._wall(doc,"pump-end",kit.pier,529,s.y+27,16,44)
		Scene._step(route,Scene._reaction("switch",delivery,"Electric Switch contact"),"The bearing lands on the switch.")
		Scene._step(route,{"kind":"vacuumed","part":"marble"},"The powered vacuum collects the marble.")
		placeable.append("vacuum")
	elif finish == "piano delivery":
		Scene._wall(doc,"stage",kit.beam,405,370,144)
		Scene._wall(doc,"stage-back",kit.pier,405,310,16,60)
		Scene._step(route,Scene._reaction(delivery,"stage","Piano broke"),"The Piano crashes onto the stage floor.")
	else:
		var floor_y := 376
		Scene._wall(doc,"floor",kit.beam,277,floor_y,272)
		Scene._wall(doc,"end-post",kit.pier,533,door_y+41,16,floor_y-door_y-41)
		Scene._wall(doc,"eave",kit.beam,505,door_y+25,44)
		Scene._piece(doc,"sid",37,Vector2i(327,floor_y-28))
		Scene._step(route,Scene._reaction("sid",delivery,"sight"),"Sid spots the cheese.")
		Scene._step(route,Scene._event("deactivated",delivery,"sid"),"Sid eats the cheese.")

static func _shutter(doc: Dictionary, route: Dictionary, kit: Dictionary, pivot: Vector2i, placeable: Array) -> void:
	var shelf_y := pivot.y-16
	Scene._wall(doc,"fuse-ledge",kit.beam,37,shelf_y,144)
	Scene._wall(doc,"shutter",kit.pier,37,shelf_y-48,16,48)
	Scene._wall(doc,"projection-brace",kit.pier,37,shelf_y+16,16,64)
	Scene._pistol(doc,"pistol",Vector2i(242,shelf_y-32),true)
	Scene._piece(doc,"charge",19,Vector2i(71,shelf_y-45))
	# Slot 1 leaves slot 0 available for another chamber.
	Scene._piece(doc,"left-sheave",17,pivot+Vector2i(77,-68))
	Scene._piece(doc,"pistol-guide",17,Vector2i(298,shelf_y-15))
	Scene._rope(doc,"trigger-line",["teeter","left-sheave","pistol-guide","pistol"],[1,0])
	Scene._shot(route,"pistol","charge","shutter booth")
	Scene._step(route,Scene._event("destroyed_by_blast","shutter","charge"),"The Ball Bomb blasts the shutter open.")
	placeable.append("pistol-guide")

static func _test(part: String, field: String, op: String, value: int) -> Dictionary:
	return {"kind":"compare","part":part,"field":field,"op":op,"value":value}
