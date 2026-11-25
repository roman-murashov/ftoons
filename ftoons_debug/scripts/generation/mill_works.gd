extends RefCounted
## Size the receiving bin, put a conveyor within throwing distance, then
## build a transmission back to the food-powered motor.
const Board := preload("res://scripts/generation/room_board.gd")
const DESIGNS := ["mill-breakfast", "drive-belt", "mill-gate", "gear-train"]
const TITLES := ["Breakfast Shift", "The Broken Drive", "Hold the Shipment", "Change of Direction"]
const INSTRUCTIONS := [
	"Feed the Chow-Man Motor and deliver the bearing into the lower bin.",
	"Get the idle conveyor running and deliver the bearing to the lower bin.",
	"Bring the loading bay back into service and keep the arriving bearing inside.",
	"The motor turns the wrong way for this delivery. Drive the conveyor toward the bin and keep the bearing there."
]
const THEMES := [
	{"name":"Canal Warehouse", "deck":27, "pier":28, "roof":48},
	{"name":"Railway Workshop", "deck":26, "pier":27, "roof":49},
	{"name":"Orchard Press", "deck":29, "pier":27, "roof":50}
]

static func candidates(tier: int) -> Array:
	return [DESIGNS[tier-1]]

static func _belt(doc: Dictionary, id: String, first: String, last: String, loose: bool) -> void:
	var ends := []
	for name in [first, last]:
		ends.append(doc.parts.find_custom(func(row): return row.id == name))
	var owner: int = doc.parts.size()
	Board.piece(doc, id, 1, Vector2i.ZERO, not loose)
	doc.belts.append({"owner":owner, "ends":ends})
	if loose:
		doc.generator.solution_placements.append({"part":id, "belt_ends":[first, last]})

static func build(_id: String, tier: int, rng: RandomNumberGenerator) -> Dictionary:
	var mill: Dictionary = THEMES[rng.randi_range(0, THEMES.size()-1)]
	var doc := Board.blank()
	doc.title = "%s at the %s" % [TITLES[tier-1], mill.name]
	doc.goal = INSTRUCTIONS[tier-1]
	var decisions := ["feed-motor", "connect-transmission", "connect-and-contain", "reverse-with-gears"]
	var events := []
	var drops := []
	doc.generator = {"room_name":mill.name, "mechanism":"Chow-Man belt drive",
		"set_design":"mill/engine-house",
		"challenge_key":"mill/"+decisions[tier-1], "goal_family":"Reach or leave a place",
		"solution_placements":drops, "branches":[{"events":events}], "replay_limit":210}
	var right := rng.randi_range(0,1) == 1
	var bin_left := 5 + 16*rng.randi_range(0, 3) if not right else 325 + 16*rng.randi_range(0, 3)
	var bin_width := 16*rng.randi_range(8, 10)
	var bin_floor := 248 + 16*rng.randi_range(0, 5)
	var fall := 16*rng.randi_range(4, 7)
	var deck_y := bin_floor-fall
	var width := 16*rng.randi_range(4, 6)
	var deck_x := bin_left+bin_width if not right else bin_left-width
	var motor_x := deck_x+width+5 if not right else deck_x-60
	var motor_y := deck_y+16
	var motor := Board.piece(doc, "motor", 80, Vector2i(motor_x, motor_y), tier == 1)
	if tier != 1: drops.append({"part":"motor", "top_left":[motor_x, motor_y]})
	if right != (tier == 4): motor.flags_2 = int(motor.flags_2) | 0x10
	Board.piece(doc, "carrier", 0, Vector2i(deck_x, deck_y), true, Vector2i(width,32))
	var feed_pos := Vector2i(motor_x+rng.randi_range(6,16), motor_y-rng.randi_range(42,75))
	Board.piece(doc, "fuel", 57, feed_pos, tier != 1)
	if tier == 1: drops.append({"part":"fuel", "top_left":[feed_pos.x, feed_pos.y]})
	Board.piece(doc, "bearing", 31, Vector2i(deck_x+width/2, deck_y-26))
	Board.piece(doc, "bin", mill.deck, Vector2i(bin_left,bin_floor), true, Vector2i(bin_width,16))
	var outer := bin_left if not right else bin_left+bin_width-16
	Board.piece(doc, "stop", mill.pier, Vector2i(outer,bin_floor-64), tier != 3, Vector2i(16,64))
	if tier == 3: drops.append({"part":"stop", "top_left":[outer,bin_floor-64]})
	# The machine house stands behind the loading edge, leaving the freight flight open.
	var platform := Vector2i(motor_x-8, motor_y+60)
	Board.piece(doc, "engine-bed", mill.deck, platform, true, Vector2i(80,16))
	Board.piece(doc, "engine-base", mill.pier, platform+Vector2i(32,16), true, Vector2i(16,392-platform.y-16))
	for i in 2:
		var x := bin_left+i*(bin_width-16)
		Board.piece(doc, "dock-post-%d"%i, mill.pier, Vector2i(x, bin_floor+16), true, Vector2i(16,392-bin_floor-16))
	var roof_y := maxi(8, feed_pos.y-52)
	for i in 2:
		var roof := Board.piece(doc, "roof-%d"%i, mill.roof, Vector2i(platform.x-8+48*i,roof_y), true, Vector2i(48,32))
		roof.appearance = 2
		roof.height_2 = 16
		if i == 0: roof.flags_2 = int(roof.flags_2)|0x10
	Board.piece(doc, "lintel", mill.deck, Vector2i(platform.x-8,roof_y+32), true, Vector2i(96,16))
	if tier == 4:
		var gear := Vector2i(deck_x+16, deck_y+64)
		var mate := gear+Vector2i(32,0)
		Board.piece(doc, "input-gear", 18, mate)
		Board.piece(doc, "output-gear", 18, gear, false)
		drops.append({"part":"output-gear", "top_left":[gear.x, gear.y]})
		_belt(doc, "motor-belt", "motor", "input-gear", true)
		_belt(doc, "return-belt", "output-gear", "carrier", true)
	else:
		_belt(doc, "drive", "motor", "carrier", tier != 1)
	var conditions := [
		{"kind":"event","event":"deactivated","part":"fuel","other":"motor"},
		{"kind":"compare","part":"carrier","field":"settings","op":"ne","value":0},
		{"kind":"event","event":"contact","part":"bearing","other":"bin"},
		{"kind":"hold","updates":16,"condition":{"kind":"in_area","part":"bearing",
			"rect":[bin_left,bin_floor-27,bin_left+bin_width-8,bin_floor]}}
	]
	for description in ["The motor eats the cheese.", "The transmission drives the conveyor.",
			"The bearing lands on the bin floor.", "The bearing stays in the receiving bin."]:
		events.append({"description":description})
	if tier == 4:
		conditions.insert(1, {"kind":"compare","part":"output-gear","field":"appearance","op":"ne","value":0})
		events.insert(1, {"description":"The meshed gears turn the output shaft."})
	doc.goals = {"version":1, "delay_updates":8, "when":{"kind":"sequence","of":conditions}}
	return doc
