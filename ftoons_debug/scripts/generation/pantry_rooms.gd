extends RefCounted
## Build a multi-storey set around Sid's line of sight. A snack on one floor
## draws him across a ladder or into a tunnel on the way to his supper.
const Board := preload("res://scripts/generation/room_board.gd")

const ROUTES := {
	"loft-ladder": ["ladder"], "cellar-tunnel": ["tunnel"],
	"market-stairs": ["ladder", "ladder"], "bakery-delivery": ["ladder", "tunnel", "ladder"],
	"station-supper": ["tunnel", "ladder"]
}
const SETS := [
	{"name":"Timber Market", "roof":50, "beam":27, "post":29},
	{"name":"Stone Arcade", "roof":49, "beam":28, "post":26},
	{"name":"Candy Kitchen", "roof":47, "beam":83, "post":27},
]
const NAMES := {
	"loft-ladder":"Lunch in the Loft", "cellar-tunnel":"The Cellar Shortcut",
	"market-stairs":"The Upstairs Pantry", "bakery-delivery":"The Baker's Back Door",
	"station-supper":"The Station Buffet"
}
const INSTRUCTIONS := {
	"loft-ladder":"Use the spare cheese to lure Sid to the ladder. Feed him the cheese in the loft.",
	"cellar-tunnel":"Use the spare cheese to lead Sid through the cellar tunnel to his upstairs supper.",
	"market-stairs":"Lure Sid up both market ladders and feed him the cheese on the top floor.",
	"station-supper":"Lead Sid through the station tunnel, then up the ladder to the cheese.",
	"bakery-delivery":"Lure Sid up the first ladder, through the tunnel, and up the last ladder to his supper."
}

static func candidates(tier: int) -> Array:
	match tier:
		1: return ["loft-ladder"]
		2: return ["cellar-tunnel"]
		3: return ["market-stairs", "station-supper"]
		4: return ["bakery-delivery"]
	return []

static func build(id: String, _difficulty: int, rng: RandomNumberGenerator) -> Dictionary:
	var route: Array = ROUTES[id]
	var theme: Dictionary = SETS[rng.randi_range(0, SETS.size()-1)]
	var first_right := rng.randi_range(0, 1) == 1
	var bottom := 328 + rng.randi_range(0, 2) * 16
	var spacing := rng.randi_range(6, 7) * 16
	if route.size() == 3:
		bottom = 360
		spacing = 80
	var left := 5 + 16 * rng.randi_range(0, 2)
	var right := 549 - 16 * rng.randi_range(0, 2)
	var doc := Board.blank()
	doc.title = "%s at %s" % [NAMES[id], theme.name]
	var drops := []
	var events := []
	var conditions := []
	var start_x := left + 35 if first_right else right - 68
	for floor_index in route.size() + 1:
		var y := bottom - floor_index * spacing
		var course_left := left + 16 * rng.randi_range(0, 1)
		var course_right := right - 16 * rng.randi_range(0, 1)
		Board.piece(doc, "floor-%d" % floor_index, theme.beam, Vector2i(course_left, y), true, Vector2i(course_right-course_left, 16))
		for side in 2:
			var foot := 392 if floor_index == 0 else y + spacing
			var x := course_left if side == 0 else course_right - 16
			Board.piece(doc, "pier-%d-%d" % [floor_index, side], theme.post, Vector2i(x, y+16), true, Vector2i(16, foot-y-16))
		if floor_index == route.size(): break
		var lure_x := right - rng.randi_range(75, 106) if start_x < 275 else left + rng.randi_range(48, 78)
		var intercept := lerpf(start_x, lure_x, rng.randf_range(0.34, 0.63))
		var target_x := 5 + 16 * roundi((intercept - 5) / 16.0)
		var lure := "lure-%d" % floor_index
		var access := "entrance-%d" % floor_index
		Board.piece(doc, lure, 57, Vector2i(lure_x, y-26), false)
		drops.append({"part":lure, "top_left":[lure_x, y-26]})
		var gate: Dictionary
		var description: String
		if route[floor_index] == "ladder":
			Board.piece(doc, access, 45, Vector2i(target_x, y-spacing-32), true, Vector2i(32, spacing+32))
			gate = {"kind":"all","of":[{"kind":"targets","part":"sid","other":access},
					{"kind":"compare","part":"sid","field":"state","op":"eq","value":11}]}
			description = "Sid starts up the ladder."
			start_x = target_x
		else:
			var exit_x := right - 112 if start_x < 275 else left + 64
			var a: int = doc.parts.size()
			var entrance := Board.piece(doc, access, 46, Vector2i(target_x,y-48), true, Vector2i(56,47))
			var outlet := Board.piece(doc, "exit-%d" % floor_index, 46, Vector2i(exit_x,y-spacing-48), true, Vector2i(56,47))
			entrance.tunnel_partner = a+1
			outlet.tunnel_partner = a
			gate = {"kind":"event","part":"sid","event":"tunnel_from","other":access}
			description = "Sid travels through the tunnel to the next floor."
			start_x = exit_x
		conditions.append({"kind":"targets","part":"sid","other":lure})
		events.append("Sid spots the cheese on his floor.")
		conditions.append(gate)
		events.append(description)
	var top := bottom - route.size()*spacing
	var supper_x := right - 95 if start_x < 275 else left + 55
	Board.piece(doc, "supper", 57, Vector2i(supper_x, top-24))
	Board.piece(doc, "sid", 37, Vector2i(left+35 if first_right else right-68, bottom-28))
	# Build the roof on a narrow end pavilion. Leave open sky over the route.
	var bay := left if rng.randi_range(0, 1) == 0 else right - 96
	for i in 2:
		var roof := Board.piece(doc, "gable-%d" % i, theme.roof, Vector2i(bay + 48*i, top-96),
				true, Vector2i(48,32))
		roof.appearance = 2
		roof.height_2 = 16
		if i == 0: roof.flags_2 = int(roof.flags_2) | 0x10
	Board.piece(doc, "lintel", theme.beam, Vector2i(bay,top-64), true, Vector2i(96,16))
	Board.piece(doc, "roof-post", theme.post, Vector2i(bay if bay==left else bay+80,top-48), true, Vector2i(16,48))
	conditions.append({"kind":"event","part":"supper","event":"deactivated","other":"sid"})
	events.append("Sid eats the cheese on the top floor.")
	doc.goals = {"version":1,"delay_updates":8,"when":{"kind":"sequence","of":conditions}}
	doc.goal = INSTRUCTIONS[id]
	doc.generator = {"room_name":theme.name, "mechanism":"Food lures and floor-to-floor traversal",
		"set_design":"supper/multistorey",
		"challenge_key":"supper/traversal",
		"goal_family":"Reach an action or animation milestone", "solution_placements":drops,
		"replay_limit":640, "branches":[{"events":[]}]}
	for description: String in events:
		doc.generator.branches[0].events.append({"description":description})
	return doc
