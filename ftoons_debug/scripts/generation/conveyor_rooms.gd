extends RefCounted
## Two belt runs hand the same delivery through an open-sided engine room.
const Board := preload("res://scripts/generation/room_board.gd")
const Scene := preload("res://scripts/generation/action_rooms.gd")
const Mill := preload("res://scripts/generation/mill_works.gd")
const THEMES := [
	{"name":"the Packing House", "deck":26, "pier":27},
	{"name":"the Cheese Works", "deck":27, "pier":28},
	{"name":"the Canary Wharf", "deck":82, "pier":29}
]

static func candidates(tier: int) -> Array:
	match tier:
		3: return ["switchback-delivery"]
		4: return ["reverse-shift"]
	return []

static func build(id: String, tier: int, rng: RandomNumberGenerator) -> Dictionary:
	if id not in candidates(tier): return {}
	var reverse := id == "reverse-shift"
	var theme: Dictionary = THEMES[rng.randi_range(0, THEMES.size()-1)]
	var offset := rng.randi_range(0, 1)*16
	var upper := Vector2i(257+offset,104)
	var lower := Vector2i(85,168)
	var receiving_y := 344+16*rng.randi_range(0, 1)
	var doc := Board.blank()
	var name := "The Reverse Shift" if reverse else "Switchback Delivery"
	doc.title = "%s at %s" % [name, theme.name]
	doc.goal = "Set both conveyors running so Sid gets the cheese from the upper loading deck."
	if reverse:
		doc.goal = "Reverse the lower drive to pass the cheese from the upper loading deck down to Sid."
	doc.generator = {"room_name":theme.name, "mechanism":name, "set_design":"conveyors/switchback",
		"challenge_key":"conveyors/"+id, "goal_family":"Reach an action or animation milestone",
		"solution_placements":[], "branches":[], "replay_limit":255}
	var delivery := Scene._route()
	var drive := Scene._route()
	var high_motor := upper+Vector2i(117,16)
	var low_motor := lower+Vector2i(-60,16)
	Scene._piece(doc,"high-engine",80,high_motor)
	var engine := Scene._piece(doc,"low-engine",80,low_motor,true)
	if not reverse: engine.flags_2 |= 16
	Scene._piece(doc,"high-belt",0,upper,false,Vector2i(112,32))
	Scene._piece(doc,"low-belt",0,lower,false,Vector2i(256+offset,32))
	Scene._piece(doc,"high-fuel",57,high_motor+Vector2i(11,-56),true)
	Scene._piece(doc,"low-fuel",57,low_motor+Vector2i(11,-45))
	Scene._piece(doc,"cargo",57,upper+Vector2i(56,-31))
	Mill._belt(doc,"upper-drive","high-engine","high-belt",false)
	if reverse:
		Scene._piece(doc,"input-gear",18,lower+Vector2i(48,64))
		Scene._piece(doc,"output-gear",18,lower+Vector2i(16,64),true)
		Mill._belt(doc,"lower-input","low-engine","input-gear",true)
		Mill._belt(doc,"lower-output","output-gear","low-belt",true)
	else:
		Mill._belt(doc,"lower-drive","low-engine","low-belt",true)

	# The engine frames leave the center open for the first drop. The roof
	# on the receiving booth leaves a second opening above Sid's platform.
	Scene._wall(doc,"loading-roof",theme.deck,high_motor.x-16,16,112)
	Scene._wall(doc,"loading-support",theme.pier,high_motor.x+80,32,16,148)
	Scene._wall(doc,"loading-bed",theme.deck,high_motor.x+24,180,72)
	Scene._wall(doc,"motor-roof",theme.deck,5,88,96)
	Scene._wall(doc,"motor-wall",theme.pier,5,104,16,140)
	Scene._wall(doc,"motor-bed",theme.deck,5,244,80)
	Scene._wall(doc,"receiving-platform",theme.deck,341,receiving_y,208)
	Scene._wall(doc,"receiving-wall",theme.pier,533,224,16,receiving_y-224)
	Scene._wall(doc,"receiving-roof",theme.deck,453,208,96)
	Scene._wall(doc,"divider",theme.pier,341,receiving_y-64,16,64)
	Scene._piece(doc,"sid",37,Vector2i(410+offset,receiving_y-28))
	for row: Dictionary in doc.parts:
		if int(row.flags_1) & 0x6000: row.flags_1 |= 0x2000

	Scene._step(delivery,Scene._event("deactivated","high-fuel","high-engine"),"The loading motor eats its cheese.")
	Scene._step(delivery,{"kind":"compare","part":"high-belt","field":"settings","op":"lt","value":0},
		"The upper belt starts moving left.")
	Scene._step(delivery,{"kind":"compare","part":"cargo","field":"x","op":"lt","value":upper.x-16},
		"The delivery drops through the left opening.")
	Scene._step(delivery,Scene._event("contact","cargo","low-belt"),"The lower belt catches the delivery.")
	Scene._step(delivery,{"kind":"crosses","part":"cargo","direction":"right","line":lower.x+218+offset,"span":[140,231]},
		"The lower belt carries the cheese back toward the serving booth.")
	Scene._step(delivery,Scene._event("deactivated","cargo","sid"),"Sid catches and eats the delivered cheese.")
	Scene._step(drive,Scene._event("deactivated","low-fuel","low-engine"),"The lower motor eats its cheese.")
	if reverse:
		Scene._step(drive,{"kind":"compare","part":"output-gear","field":"appearance","op":"ne","value":0},
			"The meshed gears turn the lower drive around.")
	Scene._step(drive,{"kind":"compare","part":"low-belt","field":"settings","op":"gt","value":0},
		"The lower belt starts moving right.")
	var conditions := []
	for route: Dictionary in [delivery,drive]:
		doc.generator.branches.append({"events":route.events})
		conditions.append({"kind":"sequence","of":route.nodes})
	doc.goals = {"version":1,"delay_updates":9,"when":{"kind":"all","of":conditions}}
	return doc
