extends RefCounted
## Stage the actors and the finish first, then fit the rig that connects them.
const Board := preload("res://scripts/generation/room_board.gd")
const SETS := [
	{"place":"the Freight Yard", "wall":27, "pier":28, "roof":49},
	{"place":"the Clockworks", "wall":26, "pier":83, "roof":50},
	{"place":"the Backlot", "wall":29, "pier":27, "roof":48},
	{"place":"the Old Depot", "wall":82, "pier":28, "roof":84}
]
const TITLES := {
	"cut-and-run":"Cut and Run", "trunk-shot":"The Trunk Shot",
	"rig-the-getaway":"Rig the Getaway", "demolition-rehearsal":"Demolition Rehearsal",
	"counterweight":"The Counterweight", "dress-rehearsal":"Dress Rehearsal",
	"double-feature":"Double Feature", "closing-night":"Closing Night"
}

static func candidates(tier: int) -> Array:
	match tier:
		1: return ["cut-and-run", "trunk-shot"]
		2: return ["rig-the-getaway", "demolition-rehearsal"]
		3: return ["counterweight", "dress-rehearsal"]
		4: return ["closing-night", "double-feature"]
	return []

static func _route() -> Dictionary:
	return {"nodes":[], "events":[]}

static func _step(route: Dictionary, condition: Dictionary, description: String) -> void:
	route.nodes.append(condition)
	route.events.append({"description":description})

static func _fork(route: Dictionary) -> Dictionary:
	for i in route.events.size(): route.events[i].shared_step = "opening-%d" % i
	return route.duplicate(true)

static func _event(kind: String, part: String, other := "") -> Dictionary:
	var node := {"kind":"event", "event":kind, "part":part}
	if not other.is_empty(): node.other = other
	return node

static func _reaction(part: String, producer: String, reason: String) -> Dictionary:
	var node := _event("reaction", part, producer)
	node.reason = reason
	return node

static func _state(part: String, value: int) -> Dictionary:
	return {"kind":"compare", "part":part, "field":"state", "op":"eq", "value":value}

static func _area(part: String, rect: Rect2i) -> Dictionary:
	return {"kind":"in_area", "part":part, "rect":[rect.position.x, rect.position.y, rect.end.x, rect.end.y]}

static func _piece(doc: Dictionary, id: String, type: int, at: Vector2i, loose := false, size := Vector2i.ZERO) -> Dictionary:
	if loose: doc.generator.solution_placements.append({"part":id, "top_left":[at.x, at.y]})
	return Board.piece(doc, id, type, at, not loose, size)

static func _wall(doc: Dictionary, id: String, type: int, x: int, y: int, wide: int, high := 16, loose := false) -> void:
	_piece(doc, id, type, Vector2i(x,y), loose, Vector2i(wide,high))

static func _roof(doc: Dictionary, theme: Dictionary, x: int, y: int) -> void:
	for i in 2:
		var half := _piece(doc, "roof-%d" % i, theme.roof, Vector2i(x+48*i,y), false, Vector2i(48,32))
		half.appearance = 2
		half.height_2 = 16
		if i == 0: half.flags_2 = int(half.flags_2) | 16

static func _rope(doc: Dictionary, id: String, names: Array, slots: Array, loose := false) -> void:
	var route := []
	for name in names:
		route.append(doc.parts.find_custom(func(row): return row.id == name))
	var owner: int = doc.parts.size()
	Board.piece(doc, id, 14, Vector2i.ZERO, not loose)
	doc.ropes.append({"owner":owner, "route":route, "slots":slots})
	if loose:
		doc.generator.solution_placements.append({"part":id, "rope_route":names, "rope_slots":slots})

static func _pistol(doc: Dictionary, id: String, at: Vector2i, left: bool) -> void:
	var pistol := _piece(doc, id, 20, at)
	pistol.wire_terminal = 1
	if left: pistol.flags_2 = int(pistol.flags_2) | 16

static func build(id: String, tier: int, rng: RandomNumberGenerator) -> Dictionary:
	if id not in candidates(tier): return {}
	var theme: Dictionary = SETS[rng.randi_range(0, SETS.size()-1)]
	var doc := Board.blank()
	doc.title = "%s at %s" % [TITLES[id], theme.place]
	doc.generator = {"room_name":theme.place, "mechanism":TITLES[id],
		"challenge_key":"action/"+id, "replay_limit":240, "branches":[], "solution_placements":[],
		"goal_family":"Reach an action or animation milestone", "action_scene":true}
	var routes: Array
	if id in ["trunk-shot", "demolition-rehearsal", "double-feature"]:
		routes = _eunice(doc, id, theme, rng)
	else:
		routes = _chase(doc, id, theme, rng)
	for row: Dictionary in doc.parts:
		# Native LEV encodes static-chain membership alongside the fixed flag.
		# Use the same sight blockers when replaying the editable JSON.
		if int(row.flags_1) & 0x6000: row.flags_1 |= 0x2000
	var sequences := []
	for route: Dictionary in routes:
		doc.generator.branches.append({"events":route.events})
		sequences.append({"kind":"sequence","of":route.nodes})
	if doc.generator.get("protect_sid", false):
		var hazards := [_reaction("sid","anvil","hard-object impact"), _event("deactivated","sid","al")]
		if id in ["counterweight","dress-rehearsal","closing-night"]:
			hazards.append(_event("shot_contact","sid","runway-pistol"))
		sequences.append({"kind":"not","condition":{"kind":"ever","condition":{"kind":"any","of":hazards}}})
	doc.goals = {"version":1, "delay_updates":12,
		"when":sequences[0] if sequences.size()==1 else {"kind":"all","of":sequences}}
	return doc

static func _chase(doc: Dictionary, id: String, theme: Dictionary, rng: RandomNumberGenerator) -> Array:
	var firing := id in ["counterweight", "dress-rehearsal", "closing-night"]
	var double_shot := id == "closing-night"
	var route_load := id == "rig-the-getaway" or double_shot
	var repair_exit := id == "dress-rehearsal" or double_shot
	var gap := id == "dress-rehearsal"
	var floor_y := 328 + 16*rng.randi_range(-1,0)
	var shift := 16*rng.randi_range(-1,0)
	var cat_x := 115+shift
	var cutters_x := 365+shift
	var ladder_x := 421+shift
	var refuge_y := floor_y-112
	var ledge_width := 549-ladder_x
	doc.generator.set_design = "action/gantry" if firing else "action/escape-balcony"
	if gap: doc.generator.set_design = "action/broken-runway"
	doc.generator.protect_sid = true
	doc.goal = "Get Sid past Al and up to the cheese. Take Al out of the chase with the hanging anvil."
	if firing: doc.goal = "Get Sid up to the cheese. Make the hanging anvil trigger the Pistol that stops Al."
	if double_shot: doc.goal = "Get Sid to the balcony. Use the anvil rig to stop Al and knock out the loft's shutter."
	# The ladder leads to an upper floor Al cannot reach during the chase.
	if gap:
		var gap_x := 261+shift
		var gap_width := 80
		_wall(doc, "launch-deck", theme.wall, 5,floor_y,gap_x-5)
		_wall(doc, "runway-span", theme.wall, gap_x,floor_y,gap_width,16,true)
		_wall(doc, "escape-deck", theme.wall, gap_x+gap_width,floor_y,549-gap_x-gap_width)
		_wall(doc, "lower-walk", theme.pier,gap_x-32,376,gap_width+64)
		_wall(doc, "lower-brace-1", theme.pier,gap_x-32,floor_y+16,16,376-floor_y-16)
		_wall(doc, "lower-brace-2", theme.pier,gap_x+gap_width+16,floor_y+16,16,376-floor_y-16)
	else:
		_wall(doc, "runway", theme.wall, 5,floor_y,544)
	_wall(doc, "refuge", theme.wall, ladder_x, refuge_y, ledge_width)
	_wall(doc, "refuge-post", theme.pier, 533, refuge_y-48,16,48)
	_wall(doc, "refuge-eave", theme.wall, ladder_x+32, refuge_y-64, ledge_width-32)
	_piece(doc, "ladder", 45, Vector2i(ladder_x, floor_y-144), repair_exit, Vector2i(32,144))
	_piece(doc, "lure", 57, Vector2i(ladder_x+29,floor_y-22))
	_piece(doc, "supper", 57, Vector2i(ladder_x+70,refuge_y-31))
	_piece(doc, "al", 36, Vector2i(cat_x,floor_y-37))
	_piece(doc, "sid", 37, Vector2i(cat_x+93,floor_y-28))
	# Sid reaches the open handles. After they close he can see the
	# ground-level lure through the clearance underneath.
	var scissors := _piece(doc, "shears", 16, Vector2i(cutters_x, floor_y-49), not route_load)
	scissors.flags_2 = int(scissors.flags_2) | 16
	var teeter_x := cat_x+132 + rng.randi_range(-2,2)
	var load_x := teeter_x+30 if firing else cat_x+54+rng.randi_range(-4,4)
	var load_y := floor_y - (240 if firing else 160)
	var gantry_y := 32 if firing else 72
	var corner_y := floor_y - (134 if firing else 96)
	# Starting left of the hoist makes the weight swing into position. It
	# falls harmlessly off the tipping arm if the player skips the rope.
	var hang_offset := -64 if double_shot else 0
	_piece(doc, "anvil", 61, Vector2i(load_x+hang_offset, load_y))
	_piece(doc, "hoist-wheel", 17, Vector2i(load_x+19,gantry_y))
	_piece(doc, "head-wheel", 17, Vector2i(cutters_x+26,gantry_y))
	_piece(doc, "return-wheel", 17, Vector2i(cutters_x+26,corner_y), route_load)
	_piece(doc, "tie-off", 15, Vector2i(cutters_x+24,floor_y+32))
	_rope(doc, "hoist", ["anvil","hoist-wheel","head-wheel","return-wheel","tie-off"], [0,0], route_load)
	_wall(doc, "overhead-beam", theme.wall, 5, gantry_y-24, cutters_x+48)
	_wall(doc, "left-support", theme.pier, 5, gantry_y-8, 16, floor_y-gantry_y+8)
	_wall(doc, "bay-foot", theme.pier, 533, floor_y+16,16,392-floor_y-16)
	_wall(doc, "entry-foot", theme.pier, 5, floor_y+16,16,392-floor_y-16)
	var route := _route()
	_step(route, _reaction("sid","al","sight"), "Sid spots Al down the runway.")
	_step(route, {"kind":"all", "of":[_state("al",14), {"kind":"targets","part":"al","other":"sid"}]},
		"Al pounces toward Sid.")
	_step(route, _state("sid",2), "Sid bolts for the cutting station.")
	if gap:
		_step(route, _event("contact","sid","runway-span"), "Sid races across the repaired span.")
	_step(route, _reaction("sid","shears","Scissors contact"), "Sid reaches the scissors ahead of Al.")
	_step(route, _reaction("shears","sid","Sid closes Scissors"), "Sid squeezes the handles.")
	_step(route, _event("rope_cut","shears","hoist"), "The scissors cut the load-bearing rope.")
	var escape := _fork(route)
	var branches := [route, escape]
	if firing:
		var teeter_y := floor_y-144
		_piece(doc, "teeter", 3, Vector2i(teeter_x,teeter_y))
		_pistol(doc, "runway-pistol", Vector2i(39+shift,floor_y-33), false)
		_piece(doc, "signal-wheel", 17, Vector2i(teeter_x-40,teeter_y+40))
		_piece(doc, "trigger-wheel", 17, Vector2i(23,floor_y-66), true)
		_rope(doc, "trigger-line", ["teeter","signal-wheel","trigger-wheel","runway-pistol"], [0,0], true)
		# Catch the rebounding anvil before it can enter the exit lane.
		_wall(doc, "anvil-catch", theme.wall, cutters_x-56, floor_y-96,112)
		_wall(doc, "anvil-stop", theme.pier, cutters_x+40, floor_y-144,16,48)
		_wall(doc, "anvil-catch-brace", theme.pier, cutters_x-24, floor_y-80,16,32)
		_step(route, _reaction("teeter","anvil","Teeter-Totter impact"), "The falling anvil slams into the Teeter-Totter.")
		if double_shot:
			var blast := _fork(route)
			_blast_loft(doc, blast, theme, teeter_x, teeter_y, shift, false)
			branches.append(blast)
		_shot(route, "runway-pistol", "al", "runway")
		_step(route, {"kind":"any","of":[_state("al",16), _state("al",43)]}, "The shot sends Al reeling.")
	else:
		_roof(doc, theme, 37, floor_y-145)
		_wall(doc, "porch-eave", theme.wall, 37, floor_y-113,96)
		_wall(doc, "porch-post", theme.pier, 37, floor_y-97,16,97)
		_step(route, _reaction("al","anvil","hard-object impact"), "The anvil catches Al below the hoist.")
		_step(route, _state("al",4), "Al is knocked out of the chase.")
	# The eating event is credited only while Sid is in the elevated safe area.
	_step(escape, {"kind":"all", "of":[_state("sid",11), {"kind":"targets","part":"sid","other":"ladder"}]},
		"Sid starts up the escape ladder.")
	var eats_in_refuge := {"kind":"all", "of":[_event("deactivated","supper","sid"),
		_area("sid",Rect2i(ladder_x-24,refuge_y-63,ledge_width+24,63))]}
	_step(escape, eats_in_refuge, "Sid reaches the balcony safely and eats the cheese.")
	return branches

static func _shot(route: Dictionary, pistol: String, target: String, station: String) -> void:
	_step(route, _reaction(pistol,"teeter","rope pulls Pistol trigger"),
		"The Teeter-Totter pulls the %s trigger through its rope." % station)
	_step(route, _event("shot",pistol), "The %s Pistol fires." % station)
	_step(route, _event("shot_contact",target,pistol),
		"The %s shot hits %s." % [station, "Al" if target=="al" else "the Ball Bomb"])

static func _blast_loft(doc: Dictionary, route: Dictionary, theme: Dictionary,
		teeter_x: int, teeter_y: int, shift: int, fire_right: bool) -> void:
	var loft_x := 349+shift if fire_right else 123+shift
	var loft_y := teeter_y-49 if fire_right else teeter_y-68
	var shelf_x := loft_x+108 if fire_right else loft_x-86
	_pistol(doc, "loft-pistol", Vector2i(loft_x,loft_y), not fire_right)
	_piece(doc, "upper-wheel", 17, Vector2i(teeter_x+44,teeter_y-55))
	var wheel_x := loft_x-40 if fire_right else loft_x+72
	_piece(doc, "loft-wheel", 17, Vector2i(wheel_x,loft_y+2), true)
	_rope(doc, "loft-line", ["teeter","upper-wheel","loft-wheel","loft-pistol"], [1,0], true)
	_piece(doc, "charge", 19, Vector2i(shelf_x+25,loft_y-47))
	_wall(doc, "charge-shelf", theme.wall, shelf_x, loft_y+20,80)
	_wall(doc, "shutter", theme.pier, shelf_x+64 if fire_right else shelf_x, loft_y-44,16,48)
	_shot(route, "loft-pistol", "charge", "loft")
	_step(route, {"kind":"inactive","part":"charge"}, "The Ball Bomb bursts in the loft.")
	_step(route, {"kind":"inactive","part":"shutter"}, "The blast clears the shutter.")

static func _eunice(doc: Dictionary, id: String, theme: Dictionary, rng: RandomNumberGenerator) -> Array:
	var blast := id != "trunk-shot"
	var both := id == "double-feature"
	var shift := 16*rng.randi_range(-1,0)
	var floor_y := 328+16*rng.randi_range(-1,0)
	var elephant_x := 82+shift
	var teeter_x := elephant_x+rng.randi_range(72,73)
	var teeter_y := floor_y-111
	var al_x := 451+shift
	doc.generator.set_design = "action/elephant-gallery"
	doc.goal = "Help Eunice send the bearing over the partition and fire the Pistol at Al."
	if both: doc.goal = "Use Eunice's toss to fire both Pistols. Knock out Al and clear the loft shutter."
	var route := _route()
	_wall(doc, "street", theme.wall, 5, floor_y,544)
	_wall(doc, "elephant-platform", theme.wall, elephant_x-8,floor_y-29,80)
	_wall(doc, "elephant-pier", theme.pier, elephant_x-8,floor_y-13,16,13)
	_wall(doc, "ring-partition", theme.pier, elephant_x+83,floor_y-184,16,48)
	_wall(doc, "stand", theme.pier, 5, floor_y+16,16,392-floor_y-16)
	_wall(doc, "stand-end", theme.pier, 533, floor_y+16,16,392-floor_y-16)
	if id == "demolition-rehearsal":
		# Al stands in the projection booth a floor beneath the loft charge.
		var booth_y := teeter_y+14
		_wall(doc, "booth-floor", theme.wall, 421, booth_y,128)
		_wall(doc, "booth-foot", theme.pier, 533, booth_y+16,16,floor_y-booth_y-16)
		_piece(doc, "al", 36, Vector2i(459+shift,booth_y-37)).flags_2 |= 16
		doc.goal = "Use Eunice's toss to blow open the loft shutter and startle Al in the booth below."
	else:
		_roof(doc, theme, 437, floor_y-118)
		_wall(doc, "box-eave", theme.wall, 437, floor_y-86,96)
		_wall(doc, "box-support", theme.pier, 533, floor_y-86,16,86)
		_piece(doc, "al", 36, Vector2i(al_x,floor_y-37)).flags_2 |= 16
	_piece(doc, "eunice", 68, Vector2i(elephant_x,floor_y-93))
	_piece(doc, "bearing", 31, Vector2i(elephant_x+28,floor_y-162))
	_piece(doc, "teeter", 3, Vector2i(teeter_x,teeter_y))
	if not blast or both: _pistol(doc, "runway-pistol", Vector2i(313+shift,floor_y-32), false)
	_step(route, _event("launched_by","bearing","eunice"), "Eunice catches and throws the bearing.")
	_step(route, {"kind":"crosses","part":"bearing","direction":"right","line":elephant_x+105,
		"span":[floor_y-280,floor_y-158]}, "The bearing clears the partition.")
	_step(route, _reaction("teeter","bearing","Teeter-Totter impact"), "The bearing lands on the far side of the Teeter-Totter.")
	var branches := [route]
	if blast:
		var loft := _fork(route) if both else route
		_blast_loft(doc, loft, theme, teeter_x, teeter_y, shift, true)
		if id == "demolition-rehearsal":
			_step(loft, _state("al",2), "The shock startles Al in the booth.")
		if both: branches.append(loft)
	if not blast or both:
		_piece(doc, "auditorium-wheel", 17, Vector2i(269+shift, floor_y-74), true)
		_rope(doc, "auditorium-line", ["teeter","auditorium-wheel","runway-pistol"], [0,0], true)
		_shot(route, "runway-pistol", "al", "runway")
		_step(route, {"kind":"any","of":[_state("al",16),_state("al",43)]}, "Al tumbles out of his box.")
	return branches
