extends RefCounted
## Join fire and airflow sources to receivers at their native interaction ranges.
const Scene := preload("res://scripts/generation/action_rooms.gd")
const SOURCES := ["falling bearing", "rising balloon", "blower heat", "blower launch"]
const ENDINGS := ["boil", "send a bearing", "steam reaction", "pop a balloon", "clear a shutter"]

static func build(doc: Dictionary, tier: int, rng: RandomNumberGenerator, kit: Dictionary) -> Dictionary:
	var source: String = SOURCES[rng.randi_range(0, 2 if tier == 1 else 3)]
	var fire := source != "blower heat"
	var right := source == "blower launch"
	var finish: String = ENDINGS[rng.randi_range(0, (4 if fire and not right else 2))]
	var fork := tier >= 3 and fire and not right and rng.randf() < (0.29 if tier == 4 else 0.14)
	if fork: finish = "boil" if rng.randf() < 0.5 else "send a bearing"
	var pots := rng.randi_range(1 if tier <= 2 else 2, 1 if tier == 1 else (2 if tier <= 3 else 3))
	if right: pots = mini(pots, 1 if finish == "send a bearing" else 2)
	if fork and tier == 3: pots = 1
	var blasts := rng.randi_range(1, 2) if tier >= 3 else 1
	var lift := 16 * rng.randi_range(-2, 1)
	var shift := 16 * rng.randi_range(-1, 1)
	var anchor := Vector2i(385 + shift, 161 + lift)
	var route := Scene._route()
	var parts_to_place := ["starter"]
	var source_part := ""
	var heat := ""
	var steps := [source]
	match source:
		"falling bearing", "rising balloon":
			_dragon(doc, route, anchor, source == "rising balloon", kit, rng)
			source_part = "dragon"
			heat = "Dragon fire"
		"blower heat":
			_blower(doc, route, Vector2i(464+shift,146+lift), true, kit)
			parts_to_place.append("blower")
			source_part = "blower"
			heat = "Hair-Dryer airflow"
		"blower launch":
			var origin := Vector2i(53+shift,103+lift)
			_blower(doc, route, origin, false, kit)
			anchor = origin+Vector2i(256, rng.randi_range(50, 61))
			_station(doc, kit, "dragon", anchor, true)
			Scene._step(route, Scene._reaction("dragon", "wind-bearing", "contact"),
				"The wind-driven bearing strikes Bik Dragon.")
			parts_to_place.append_array(["blower", "wind-bearing"])
			steps.append("bearings wake dragon")
			source_part = "dragon"
			heat = "Dragon fire"
	var first_pot := anchor+Vector2i(74 if right else -88,5)
	var chains := [route]
	var name := ""
	var goal := ""
	var family := "Operate, damage, or read a gadget"
	if fork:
		var side := Scene._fork(route)
		var charge := anchor+Vector2i(-45,1)
		_light_charge(doc, side, source_part, charge, kit)
		Scene._step(side, {"kind":"inactive","part":"charge-1"}, "The Ball Bomb goes off in the other bay.")
		chains.append(side)
		parts_to_place.append("charge-1")
	if finish in ["boil", "send a bearing", "steam reaction"]:
		var tip := _pots(doc, route, source_part, heat, first_pot, right, pots, kit)
		for i in pots:
			steps.append("heat teapot" if i == 0 else "steam to teapot")
			if i < pots-1 or finish != "boil":
				parts_to_place.append("pot-%d" % (i+1))
		var last := "pot-%d" % pots
		match finish:
			"boil":
				name = "The Steam Cascade" if pots > 1 else "Bring to the Boil"
				goal = "Get the last Teapot steaming." if pots > 1 else "Get the Teapot steaming."
			"send a bearing":
				_steam_delivery(doc, route, tip, right, kit)
				steps.append("steam delivers bearing")
				name = "The Steam Courier"
				goal = "Use the steam to send the bearing off the ledge and into the lower bay."
				family = "Reach or leave a place"
			"steam reaction":
				_steam_actor(doc, route, last, tip, right, kit)
				steps.append("steam reaches actor")
				name = "The Steam Bath"
				goal = "Get the steam from the final Teapot to reach Sid."
				family = "Reach an action or animation milestone"
	elif finish == "pop a balloon":
		_balloon(doc, route, anchor+Vector2i(-88,-1), kit)
		steps.append("dragon pops tethered balloon")
		name = "The Fireproof Tether"
		goal = "Wake Bik Dragon and pop the tethered balloon with its fire."
		family = "Remove a part"
	else:
		var charge := anchor+Vector2i(-76,1)
		var shutter := charge+Vector2i(-44,-28) if blasts == 1 else charge+Vector2i(-112,59)
		_blasts(doc, route, blasts, source_part, charge, shutter, kit)
		parts_to_place.append("charge-1")
		if blasts == 2: parts_to_place.append("charge-2")
		steps.append("dragon lights bomb")
		if blasts == 2: steps.append("blast lights second bomb")
		steps.append("blast clears shutter")
		name = "The Fuse Relay" if blasts == 2 else "Open the Fire Door"
		goal = "Use the blast to knock out the short shutter."
	if fork:
		name = "Two Jobs for Bik"
		goal = goal.trim_suffix(".") + " and set off the Ball Bomb in the other bay."
	return {"name":name, "goal":goal, "family":family, "routes":chains, "steps":steps,
		"side_steps":["dragon lights bomb", "charge detonates"] if fork else [],
		"placeable":parts_to_place, "set_design":"heat/"+source}

static func _station(doc: Dictionary, kit: Dictionary, id: String, at: Vector2i, right: bool,
		open_bottom := false) -> void:
	var dragon := Scene._piece(doc, id, 35, at)
	if right: dragon.flags_2 |= 16
	# Leave the approach to the fire opening and the path from the launch shelf clear.
	var support_x := at.x-16 if right else at.x+(51 if open_bottom else 22)
	Scene._wall(doc, id+"-stand", kit.beam, support_x, at.y+32, 48)
	Scene._wall(doc, id+"-pier", kit.pier, support_x+(0 if right else 32), at.y+48, 16, 48)

static func _dragon(doc: Dictionary, route: Dictionary, at: Vector2i, rising: bool, kit: Dictionary,
		rng: RandomNumberGenerator) -> void:
	_station(doc, kit, "dragon", at, false, rising)
	var height := 16*rng.randi_range(4,6)
	if rising:
		Scene._piece(doc, "starter", 23, at+Vector2i(0,height))
		Scene._wall(doc, "start-well", kit.beam, at.x-20, at.y+height+50, 112)
		Scene._wall(doc, "well-side", kit.pier, at.x+76, at.y+height+2, 16, 48)
	else:
		Scene._piece(doc, "starter", 31, at+Vector2i(9,-height))
		Scene._wall(doc, "shaft-side", kit.pier, at.x+43, at.y-height-8, 16, 80)
		Scene._wall(doc, "shaft-cap", kit.beam, at.x-5, at.y-height-24, 64)
	var material := "rising balloon" if rising else "falling bearing"
	Scene._step(route, Scene._reaction("dragon", "starter", "contact"),
		"The %s wakes Bik Dragon." % material)

static func _blower(doc: Dictionary, route: Dictionary, origin: Vector2i, left: bool,
		kit: Dictionary) -> void:
	var lever := Scene._piece(doc, "switch", 2, origin)
	lever.outlet_plugged_1 = doc.parts.size()
	var at := origin+Vector2i(-61 if left else 62,15 if left else 13)
	var blower := Scene._piece(doc, "blower", 52, at)
	if left: blower.flags_2 |= 16
	Scene._piece(doc, "starter", 31, origin+Vector2i(9,-74 if left else -64))
	var base := origin.x+33
	var width := mini(44, 549-base)
	Scene._wall(doc, "switch-deck", kit.beam, base, origin.y+59, width)
	Scene._wall(doc, "switch-pier", kit.pier, base+width-16, origin.y+75, 16, 64)
	Scene._step(route, Scene._reaction("switch", "starter", "Electric Switch contact"),
		"The falling bearing presses the outlet switch.")
	Scene._step(route, _compare("switch", "appearance", "ge", 4), "The switch powers the Hair-Dryer.")
	if left:
		Scene._wall(doc, "blower-shelf", kit.beam, at.x, at.y+32, 48)
	else:
		Scene._piece(doc, "wind-bearing", 31, origin+Vector2i(130,11))
		Scene._wall(doc, "launch-shelf", kit.beam, origin.x+112, origin.y+40, 96)
		Scene._step(route, {"kind":"crosses","part":"wind-bearing","direction":"right","line":origin.x+204,
			"span":[origin.y-8,origin.y+70]}, "The Hair-Dryer blows the bearing off the launch shelf.")

static func _pots(doc: Dictionary, route: Dictionary, source: String, reason: String, first: Vector2i,
		right: bool, count: int, kit: Dictionary) -> Vector2i:
	var at := first
	for i in count:
		var pot := "pot-%d" % (i+1)
		var row := Scene._piece(doc, pot, 12, at)
		if not right: row.flags_2 |= 16
		Scene._wall(doc, pot+"-shelf", kit.beam, at.x, at.y+33, 48)
		var heat := ("The dragon's fire" if reason == "Dragon fire" else "The hot airflow") if i == 0 else "Steam from the previous Teapot"
		Scene._step(route, Scene._reaction(pot, source, reason), "%s heats Teapot %d." % [heat, i+1])
		Scene._step(route, _compare(pot, "appearance", "ge", 6), "Teapot %d starts steaming." % (i+1))
		source = pot
		reason = "steam"
		if i < count-1: at += Vector2i(63 if right else -61,6)
	return at

static func _steam_delivery(doc: Dictionary, route: Dictionary, pot: Vector2i, right: bool, kit: Dictionary) -> void:
	var payload := pot+Vector2i(59 if right else -38,6)
	Scene._piece(doc, "cargo", 31, payload)
	Scene._wall(doc, "cargo-ledge", kit.beam, pot.x+(45 if right else -48), pot.y+36, 48)
	var left := pot.x+65 if right else maxi(5,pot.x-180)
	var end := 549 if right else pot.x-36
	var bay_y := pot.y+118
	Scene._wall(doc, "dock", kit.beam, left,bay_y,end-left)
	var top := pot.y+(-8 if right else 38)
	Scene._wall(doc, "dock-stop", kit.pier, end-16 if right else left,top,16,bay_y-top)
	Scene._step(route, {"kind":"crosses","part":"cargo","direction":"right" if right else "left",
		"line":pot.x+(96 if right else -64),"span":[pot.y-64,pot.y+62]}, "Steam blows the bearing out of the launch bay.")
	Scene._step(route, Scene._event("contact", "cargo", "dock"), "The bearing lands in the lower receiving bay.")

static func _steam_actor(doc: Dictionary, route: Dictionary, source: String, pot: Vector2i,
		right: bool, kit: Dictionary) -> void:
	var at := pot+Vector2i(63 if right else -48,9)
	Scene._piece(doc, "sid", 37, at)
	var floor_x := pot.x+47 if right else pot.x-92
	Scene._wall(doc, "sid-platform", kit.beam, floor_x, pot.y+37, mini(88,549-floor_x))
	Scene._step(route, Scene._reaction("sid", source, "steam actor reaction"), "The last jet of steam reaches Sid.")
	Scene._step(route, _compare("sid", "state", "eq", 29), "Sid reacts to the steam.")

static func _balloon(doc: Dictionary, route: Dictionary, at: Vector2i, kit: Dictionary) -> void:
	Scene._piece(doc, "balloon", 23, at)
	Scene._piece(doc, "anchor", 15, at+Vector2i(22,68))
	Scene._rope(doc, "tether", ["balloon","anchor"], [0,0])
	Scene._wall(doc, "anchor-platform", kit.beam, at.x-8, at.y+91, 92)
	Scene._step(route, Scene._reaction("balloon", "dragon", "Dragon fire"), "Bik Dragon's fire reaches the tethered balloon.")
	Scene._step(route, {"kind":"inactive","part":"balloon"}, "The tethered balloon pops.")

static func _light_charge(doc: Dictionary, route: Dictionary, source: String, at: Vector2i, kit: Dictionary) -> void:
	Scene._piece(doc, "charge-1", 19, at)
	Scene._wall(doc, "fuse-deck", kit.beam, at.x-9, at.y+45, 64)
	Scene._step(route, Scene._reaction("charge-1", source, "Dragon fire"), "The dragon's fire lights the first Ball Bomb.")

static func _blasts(doc: Dictionary, route: Dictionary, count: int, source: String, at: Vector2i,
		shutter: Vector2i, kit: Dictionary) -> void:
	_light_charge(doc, route, source, at, kit)
	if count == 2:
		var second := at+Vector2i(-63,44)
		Scene._piece(doc, "charge-2", 19, second)
		Scene._wall(doc, "second-fuse-deck", kit.beam, second.x-13, second.y+43, 64)
		Scene._step(route, Scene._event("destroyed_by_blast", "charge-2", "charge-1"), "The first blast sets off the second Ball Bomb.")
	Scene._wall(doc, "shutter", kit.pier, shutter.x, shutter.y, 16, 48)
	Scene._step(route, Scene._event("destroyed_by_blast", "shutter", "charge-%d" % count), "The blast knocks out the shutter.")

static func _compare(part: String, field: String, op: String, value: int) -> Dictionary:
	return {"kind":"compare","part":part,"field":field,"op":op,"value":value}
