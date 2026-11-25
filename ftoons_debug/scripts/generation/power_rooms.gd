extends RefCounted
## Size the collection bay from the nozzle or landing, then work upstream
## through the switch, launch shelf and feed chute. All coordinates are new.
const Board := preload("res://scripts/generation/room_board.gd")
const KITS := [
	{"name":"Canal Works", "beam":26, "pier":28, "roof":48},
	{"name":"The Cider Mill", "beam":27, "pier":29, "roof":50},
	{"name":"Candy Exchange", "beam":83, "pier":27, "roof":47},
	{"name":"Fossil Depot", "beam":82, "pier":28, "roof":84}
]
const RECIPES := {
	"intake-bay":["Bucket Brigade", "Start the vacuum and collect the marble from its well.", "drop-switch"],
	"air-freight":["Air Mail", "Aim the hair-dryer to blow the bearing into the receiving dock.", "aim-blower"],
	"intake-chute":["Night Shift", "Route the falling bearing onto the switch to vacuum the marble out of the well.", "build-feed-chute"],
	"wind-brake":["Last Stop", "Stop the wind-driven bearing over the receiving dock so it lands on the dock floor.", "brake-wind-freight"],
	"relay-dock":["Parcel Post", "Send the parcel bearing onto the second switch so the vacuum collects the marble.", "aim-relay-switch"],
	"crosswind":["Two Orders", "Use one switch to vacuum the marble from its well and blow the bearing into the receiving dock.", "split-power"],
	"relay-chute":["Late Connection", "Route the first bearing onto the blower switch. Use the launched bearing to operate the vacuum switch and collect the marble.", "build-switch-cascade"]
}

static func candidates(tier: int) -> Array:
	match tier:
		1: return ["intake-bay","air-freight"]
		2: return ["intake-chute","wind-brake"]
		3: return ["relay-dock","crosswind"]
		4: return ["relay-chute","crosswind"]
	return []

static func _place(doc: Dictionary, id: String, type: int, pos: Vector2i, loose := false, extent := Vector2i.ZERO) -> Dictionary:
	if loose: doc.generator.solution_placements.append({"part":id,"top_left":[pos.x,pos.y]})
	return Board.piece(doc, id, type, pos, not loose, extent)

static func _branch(doc: Dictionary) -> Dictionary:
	var branch := {"events":[], "conditions":[]}
	doc.generator.branches.append(branch)
	return branch

static func _step(branch: Dictionary, condition: Dictionary, description: String) -> void:
	branch.conditions.append(condition)
	branch.events.append({"description":description})

static func _touch(branch: Dictionary, part: String, other: String, text: String) -> void:
	_step(branch, {"kind":"event","event":"contact","part":part,"other":other}, text)

static func _switch_on(branch: Dictionary, id: String, description: String) -> void:
	_step(branch, {"kind":"compare","part":id,"field":"appearance","op":"ge","value":4}, description)

static func _switch_feed(doc: Dictionary, branch: Dictionary, switch_at: Vector2i, chute: bool, loose_key: bool,
		rng: RandomNumberGenerator, kit: Dictionary, release_height: int) -> Dictionary:
	if chute:
		# A factory incline drops 16 pixels over 32. These distances across
		# its runout put the bearing above the switch's 28-pixel lever.
		var drop := 48 if switch_at.x < 85 else 16 * rng.randi_range(3,5)
		var feed := switch_at - Vector2i(maxi(48,drop-16), drop)
		_place(doc,"feed-incline",kit.roof,feed,true,Vector2i(32,32))
		_place(doc,"key",31,feed+Vector2i(3,-37))
		_touch(branch,"key","feed-incline","The feed incline turns the falling bearing toward the lever.")
	else:
		_place(doc,"key",31,switch_at+Vector2i(rng.randi_range(1,12),-release_height),loose_key)
	var lever := _place(doc,"switch",2,switch_at)
	_switch_on(branch, "switch","The bearing presses the electrical switch.")
	return lever

static func _intake(doc: Dictionary, branch: Dictionary, lever: Dictionary, at: Vector2i, loose: bool,
		rng: RandomNumberGenerator, kit: Dictionary, outlet := 1, shallow := false) -> void:
	lever["outlet_plugged_%d" % outlet] = doc.parts.size()
	var pump := _place(doc,"vacuum",13,at,loose)
	var faces_left := at.x + 136 > 548
	if faces_left: pump.flags_2 = int(pump.flags_2) | 16
	var nozzle := at+Vector2i(26 if faces_left else 76,55)
	var depth := mini(rng.randi_range(34,42) if shallow else rng.randi_range(51,79), 374-nozzle.y)
	var floor_at := nozzle + Vector2i(-52,depth)
	_place(doc,"marble",11,Vector2i(nozzle.x-rng.randi_range(4,10),floor_at.y-16))
	_place(doc,"well-floor",kit.beam,floor_at,false,Vector2i(112,16))
	_place(doc,"well-doorpost",kit.pier,floor_at-Vector2i(0,48),false,Vector2i(16,48))
	_place(doc,"well-wall",kit.pier,floor_at+Vector2i(96,-64),false,Vector2i(16,64))
	if floor_at.y+32 < 391:
		_place(doc,"sump-pier",kit.pier,floor_at+Vector2i(96,16),false,Vector2i(16,392-floor_at.y-16))
	# The ledge supports the casing but stops short of the open nozzle.
	_place(doc,"pump-shelf",kit.beam,at+Vector2i(51 if faces_left else 0,56),false,Vector2i(48,16))
	_step(branch,{"kind":"compare","part":"vacuum","field":"state","op":"gt","value":0},
			"The outlet powers the vacuum above the collection well.")
	_step(branch,{"kind":"vacuumed","part":"marble"},"The suction lifts the marble into the nozzle.")

static func _blower(doc: Dictionary, branch: Dictionary, lever: Dictionary, origin: Vector2i, loose: bool,
		kit: Dictionary) -> void:
	lever.outlet_plugged_1 = doc.parts.size()
	_place(doc,"blower",52,origin+Vector2i(62,13),loose)
	_place(doc,"cargo",31,origin+Vector2i(130,11))
	_place(doc,"launch-shelf",kit.beam,origin+Vector2i(112,40),false,Vector2i(96,16))
	_step(branch,{"kind":"crosses","part":"cargo","direction":"right","line":origin.x+205,
			"span":[origin.y-14,origin.y+64]},"The blower sends the cargo bearing off the launch shelf.")

static func _catch_dock(doc: Dictionary, branch: Dictionary, origin: Vector2i, loose_brake: bool,
		rng: RandomNumberGenerator, kit: Dictionary) -> void:
	# Catch the fast bearing while it is still above the dock. Without a
	# stop at the dock's outer edge it flies over the landing.
	var brake_x := origin.x + 16 * rng.randi_range(16,18)
	var landing_y := origin.y + 112
	var dock := Vector2i(brake_x-144,landing_y)
	_place(doc,"dock-floor",kit.beam,dock,false,Vector2i(160,16))
	_place(doc,"brake",kit.pier,Vector2i(brake_x,landing_y-96),loose_brake,Vector2i(16,96))
	_place(doc,"dock-pier",kit.pier,dock+Vector2i(0,16),false,Vector2i(16,48))
	_place(doc,"dock-ladder",45,dock+Vector2i(64,16),false,Vector2i(32,48))
	_touch(branch,"cargo","brake","The receiving wall stops the bearing over the lower dock.")
	_touch(branch,"cargo","dock-floor","The bearing lands on the dock floor.")

static func _dress(doc: Dictionary, origin: Vector2i, kit: Dictionary, rng: RandomNumberGenerator) -> void:
	# Build the switch house around the lever's clear drop shaft.
	var base := origin+Vector2i(32,64)
	var width := 16*rng.randi_range(5,7)
	_place(doc,"switch-deck",kit.beam,base,false,Vector2i(width,16))
	_place(doc,"service-stairs",45,base+Vector2i(16,16),false,Vector2i(32,64))
	_place(doc,"service-pier",kit.pier,base+Vector2i(width-16,16),false,Vector2i(16,64))
	var roof_y := origin.y-96
	var bay_x := maxi(5, origin.x-64)
	for i in 2:
		var roof := _place(doc,"gable-%d"%i,kit.roof,Vector2i(bay_x+i*32,roof_y),false,Vector2i(32,32))
		roof.appearance=1
		roof.height_2=16
		if i==0: roof.flags_2=int(roof.flags_2)|16
	_place(doc,"canopy-post",kit.pier,Vector2i(bay_x,roof_y+32),false,Vector2i(16,208))
	var landing_width := base.x + width - bay_x
	_place(doc,"lower-walk",kit.beam,Vector2i(bay_x,origin.y+144),false,Vector2i(landing_width,16))

static func build(id: String, tier: int, rng: RandomNumberGenerator) -> Dictionary:
	if id not in candidates(tier): return {}
	var kit: Dictionary=KITS[rng.randi_range(0,KITS.size()-1)]
	var recipe: Array=RECIPES[id]
	var doc := Board.blank()
	doc.title = "%s at %s" % [recipe[0],kit.name]
	doc.goal = recipe[1]
	var relay := id in ["relay-dock","relay-chute"]
	var has_dock := id in ["air-freight","wind-brake","crosswind"]
	var chute := id in ["intake-chute","relay-chute"] or (id=="crosswind" and tier==4)
	# Reserve the terminal bay at the required elevation, then size the
	# upstream room so the launch and receiving trajectories meet it.
	var landing := Vector2i(5+16*rng.randi_range(21,24),8+16*rng.randi_range(14,16))
	var origin := landing-Vector2i(272,64) if relay else landing-Vector2i(224,80)
	if relay:
		landing = Vector2i(5 + 16*rng.randi_range(20,21),8 + 16*rng.randi_range(12,14))
		var runout := Vector2i(256,64) if id=="relay-dock" else Vector2i(288,48)
		origin = landing-runout
		# The chute needs room on the upstream side. A mirrored vacuum can
		# face back over the lower station when that station lies far right.
		if id=="relay-chute":
			landing.x += 32
			origin.x += 32
	if id in ["intake-bay","intake-chute"]: origin.x += rng.randi_range(0,4)*16
	if id == "crosswind": origin.x = 165 + 16*rng.randi_range(0,1)
	var family := "Reach or leave a place" if has_dock else "Vacuum up this part"
	var set_design := "well"
	if relay: set_design = "relay"
	elif id == "crosswind": set_design = "split"
	elif has_dock: set_design = "dock"
	doc.generator={"room_name":kit.name,"mechanism":recipe[1],"challenge_key":"power/"+recipe[2],
			"set_design":"power/" + set_design,
			"goal_family":family, "solution_placements":[], "branches":[], "replay_limit":170}
	var main := _branch(doc)
	var loose_key := id=="intake-bay"
	var release_height := 60 if relay or has_dock else rng.randi_range(35,69)
	var lever := _switch_feed(doc,main,origin,chute,loose_key,rng,kit,release_height)
	if id == "crosswind": main.events.back().shared_step = "power-switch"
	if not relay and not has_dock:
		_intake(doc,main,lever,origin+Vector2i(62,13),false,rng,kit,1,chute)
	else:
		_blower(doc,main,lever,origin,id in ["air-freight","relay-dock","crosswind"],kit)
		if relay:
			var lower := _place(doc,"relay-switch",2,landing,true)
			_switch_on(main,"relay-switch","The flying bearing closes the switch at the lower station.")
			_intake(doc,main,lower,landing+Vector2i(62,13),false,rng,kit)
		else:
			_catch_dock(doc,main,origin,id in ["wind-brake","crosswind"],rng,kit)
		if id=="crosswind":
			var side := _branch(doc)
			_switch_on(side,"switch","The same switch feeds a second outlet.")
			# Both sequences witness one switch closing. Give that event one ID in the plan.
			side.events[0].shared_step = "power-switch"
			_intake(doc,side,lever,origin+Vector2i(-152,8),true,rng,kit,2)
	if id == "crosswind":
		# Keep the two outputs in separate bays. The shared outlet controls
		# the collection well on its left and the elevated freight line.
		_place(doc,"arcade-floor",kit.beam,origin+Vector2i(0,160),false,Vector2i(128,16))
		_place(doc,"arcade-post",kit.pier,origin+Vector2i(112,80),false,Vector2i(16,80))
		_place(doc,"arcade-landing",kit.beam,origin+Vector2i(64,64),false,Vector2i(64,16))
	elif not chute: _dress(doc,origin,kit,rng)
	else:
		_place(doc,"switch-deck",kit.beam,origin+Vector2i(-48,64),false,Vector2i(64,16))
		_place(doc,"deck-pier",kit.pier,origin+Vector2i(-48,80),false,Vector2i(16,80))
		_place(doc,"deck-ladder",45,origin+Vector2i(-16,80),false,Vector2i(32,80))
	var sequences := []
	for branch: Dictionary in doc.generator.branches:
		sequences.append({"kind":"sequence","of":branch.conditions})
		branch.erase("conditions")
	doc.goals={"version":1,"delay_updates":6,"when":sequences[0] if sequences.size()==1 else {"kind":"all","of":sequences}}
	return doc
