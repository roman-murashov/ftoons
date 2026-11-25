extends RefCounted
## Compose a control booth, a transfer bay and occupied receiving rooms.
## Every connection between floors has a witnessed effect on the goal.
const Board := preload("res://scripts/generation/room_board.gd")
const Scene := preload("res://scripts/generation/action_rooms.gd")
const THEMES := [
	{"title":"the Switchhouse", "wall":27, "pier":28},
	{"title":"the Foundry", "wall":26, "pier":29},
	{"title":"the Depot", "wall":82, "pier":27},
	{"title":"the Sugar Mill", "wall":83, "pier":26}
]
const RECIPES := {
	"balcony-service":{"name":"Balcony Service", "operator":"sid", "span":"", "other":""},
	"missing-catwalk":{"name":"The Missing Catwalk", "operator":"al", "span":"upper", "other":""},
	"loading-gallery":{"name":"The Loading Gallery", "operator":"sid", "span":"lower", "other":""},
	"two-service-hatches":{"name":"Two Service Hatches", "operator":"al", "span":"lower", "other":"peanut"},
	"shutter-matinee":{"name":"Shutter Matinee", "operator":"sid", "span":"upper", "other":"shutter"}
}

static func candidates(tier: int) -> Array:
	match tier:
		2: return ["balcony-service"]
		3: return ["missing-catwalk", "loading-gallery"]
		4: return ["two-service-hatches", "shutter-matinee"]
	return []

static func build(id: String, tier: int, rng: RandomNumberGenerator) -> Dictionary:
	if id not in candidates(tier): return {}
	var recipe: Dictionary = RECIPES[id]
	var theme: Dictionary = THEMES[rng.randi_range(0,THEMES.size()-1)]
	var doc := Board.blank()
	var operator_name := "Al" if recipe.operator == "al" else "Sid"
	var diner := "sid" if recipe.operator == "al" else "al"
	var diner_name := "Sid" if diner == "sid" else "Al"
	doc.title = "%s at %s" % [recipe.name, theme.title]
	doc.goal = "Use %s and the hoist upstairs to serve %s below." % [operator_name,diner_name]
	if recipe.other == "peanut":
		doc.goal = "Open both hatches with Al's hoist. Serve Sid and Eunice in their separate dining rooms."
	elif recipe.other == "shutter":
		doc.goal = "Put Sid in charge of the hoist. Feed Al downstairs and break the shutter in the middle booth."
	doc.generator = {"room_name":theme.title, "mechanism":recipe.name, "challenge_key":"stacked/"+id,
		"set_design":"stacked/"+id, "goal_family":"Reach an action or animation milestone",
		"action_scene":true, "solution_placements":[], "branches":[], "replay_limit":290}

	var upper_y := 120+16*rng.randi_range(0,1)
	var booth_x := 5+16*rng.randi_range(0,2)
	var cut_x := 208+booth_x-5
	var switch_at := Vector2i(277+16*rng.randi_range(-1,0),216+16*rng.randi_range(-1,0))
	var hall_y := 376 if diner=="al" else maxi(switch_at.y+160,360+16*rng.randi_range(0,1))
	var route := Scene._route()
	_control_booth(doc, route, recipe, theme, booth_x, upper_y, cut_x, tier)
	_transfer_bay(doc, route, theme, switch_at, upper_y, cut_x)
	var routes := [route]
	if not recipe.other.is_empty():
		var wing := Scene._fork(route)
		if recipe.other=="peanut":
			_peanut_room(doc,wing,theme,switch_at,maxi(hall_y-32,switch_at.y+128))
		else:
			_shutter_booth(doc,wing,theme,switch_at)
		routes.append(wing)
	_dining_room(doc,route,recipe,theme,switch_at,hall_y,diner,tier)
	# Use native fixed-chain flags so the editable and binary versions see the
	# same wall and gadget obstructions during an actor's sight check.
	for row: Dictionary in doc.parts:
		if int(row.flags_1) & 0x6000: row.flags_1 |= 0x2000
	var conditions := []
	for branch: Dictionary in routes:
		doc.generator.branches.append({"events":branch.events})
		conditions.append({"kind":"sequence","of":branch.nodes})
	var sid := "operator" if recipe.operator=="sid" else "diner"
	conditions.append({"kind":"not","condition":{"kind":"ever","condition":
		Scene._reaction(sid,"anvil","hard-object impact")}})
	doc.goals = {"version":1,"delay_updates":9,"when":{"kind":"all","of":conditions}}
	return doc

static func _control_booth(doc: Dictionary, route: Dictionary, recipe: Dictionary, theme: Dictionary,
		left: int, floor_y: int, cut_x: int, tier: int) -> void:
	var right := left+(240 if tier==2 else 272)
	var ceiling := 8 if recipe.span=="upper" else 24
	Scene._wall(doc,"booth-ceiling",theme.wall,left,ceiling,right-left)
	Scene._wall(doc,"booth-post",theme.pier,left,ceiling+16,16,floor_y-ceiling-16)
	if tier!=2:
		Scene._wall(doc,"booth-end",theme.pier,right-16,ceiling+16,16,floor_y-ceiling-16)
	if recipe.span=="upper":
		var span_x := left+96
		Scene._wall(doc,"booth-landing",theme.wall,left,floor_y,96)
		Scene._wall(doc,"operator-span",theme.wall,span_x,floor_y,64,16,true)
		Scene._wall(doc,"cutting-deck",theme.wall,span_x+64,floor_y,right-span_x-64)
	else:
		Scene._wall(doc,"booth-floor",theme.wall,left,floor_y,right-left)
	var al: bool = recipe.operator=="al"
	Scene._piece(doc,"operator",36 if al else 37,Vector2i(left+43,floor_y-(37 if al else 28)))
	var shears := Scene._piece(doc,"shears",16,Vector2i(cut_x,floor_y-49),tier==2)
	shears.flags_2 |= 16
	var name := "Al" if al else "Sid"
	Scene._step(route,Scene._reaction("operator","shears","sight"), "%s spots the shears in the upper booth." % name)
	if recipe.span=="upper":
		Scene._step(route,Scene._event("contact","operator","operator-span"), "%s crosses the repaired catwalk." % name)
	Scene._step(route,Scene._reaction("operator","shears","Scissors contact"), "%s reaches the cutting station." % name)
	Scene._step(route,Scene._reaction("shears","operator",name+" closes Scissors"), "%s closes the shears." % name)
	Scene._step(route,Scene._event("rope_cut","shears","hoist"), "The hoist rope breaks at the upper station.")

static func _transfer_bay(doc: Dictionary, route: Dictionary, theme: Dictionary,
		at: Vector2i, upper_y: int, cut_x: int) -> void:
	var load_x := at.x+47
	Scene._piece(doc,"anvil",61,Vector2i(load_x,at.y-66))
	Scene._piece(doc,"head-sheave",17,Vector2i(load_x+20,56))
	Scene._piece(doc,"cut-sheave",17,Vector2i(cut_x+21,48))
	Scene._piece(doc,"tie",15,Vector2i(cut_x+22,upper_y+26))
	Scene._rope(doc,"hoist",["anvil","head-sheave","cut-sheave","tie"],[0,0])
	Scene._piece(doc,"teeter",3,at)
	# The anvil leaves the lever toward the right. This recessed shelf
	# traps it above the dining corridor and leaves the food shaft clear.
	Scene._wall(doc,"catch-shelf",theme.wall,at.x+80,at.y+64,80)
	Scene._wall(doc,"catch-stop",theme.pier,at.x+144,at.y,16,64)
	Scene._wall(doc,"catch-brace",theme.pier,at.x+80,at.y+80,16,48)
	Scene._step(route,Scene._reaction("teeter","anvil","Teeter-Totter impact"), "The anvil drops into the middle bay and tips the lever.")

static func _dining_room(doc: Dictionary, route: Dictionary, recipe: Dictionary, theme: Dictionary,
		transfer: Vector2i, floor_y: int, diner: String, tier: int) -> void:
	var sid := diner=="sid"
	var name := "Sid" if sid else "Al"
	var dish := "cheese" if sid else "fish"
	var hatch_y := transfer.y+23
	var left := 277
	var right := 549
	var span_x := 373
	var span_width := 64
	var diner_x := 327
	if recipe.span=="lower":
		Scene._wall(doc,"waiting-deck",theme.wall,left,floor_y,span_x-left)
		Scene._wall(doc,"serving-deck",theme.wall,span_x+span_width,floor_y,right-span_x-span_width)
		Scene._wall(doc,"dining-span",theme.wall,span_x,floor_y,span_width,16,true)
	else:
		Scene._wall(doc,"dining-floor",theme.wall,left,floor_y,right-left)
	Scene._wall(doc,"dining-wall",theme.pier,533,hatch_y+41,16,floor_y-hatch_y-41)
	if sid:
		Scene._wall(doc,"dining-eave",theme.wall,505,hatch_y+25,44)
	Scene._wall(doc,"dining-entry",theme.pier,left,hatch_y+57,16,floor_y-hatch_y-57)
	Scene._wall(doc,"entry-eave",theme.wall,left,hatch_y+41,32)
	Scene._piece(doc,"diner",37 if sid else 36,Vector2i(diner_x,floor_y-(28 if sid else 37)))
	Scene._piece(doc,"supper",57 if sid else 56,Vector2i(463,hatch_y-41))
	Scene._piece(doc,"serving-hatch",78,Vector2i(442,hatch_y))
	Scene._piece(doc,"serving-sheave",17,Vector2i(403,transfer.y+70),tier>=3)
	Scene._rope(doc,"serving-line",["teeter","serving-sheave","serving-hatch"],[0,0],tier>=3)
	_open_hatch(route,"serving-hatch","supper","dining-room")
	Scene._step(route,Scene._reaction("diner","supper","sight"), "%s spots the %s on the serving side." % [name,dish])
	if recipe.span=="lower":
		Scene._step(route,Scene._event("contact","diner","dining-span"), "%s crosses the dining-room bridge." % name)
	Scene._step(route,Scene._event("deactivated","supper","diner"), "%s eats the %s downstairs." % [name,dish])

static func _open_hatch(route: Dictionary, hatch: String, load: String, room: String) -> void:
	Scene._step(route,Scene._reaction(hatch,"teeter","rope event"), "The lever pulls the rope to the %s hatch." % room)
	Scene._step(route,{"kind":"compare","part":hatch,"field":"appearance","op":"gt","value":0}, "The %s hatch opens." % room)
	Scene._step(route,{"kind":"compare","part":load,"field":"y","op":"gt","other":hatch,"other_field":"y"},
		"The delivery falls to the %s below." % room)

static func _peanut_room(doc: Dictionary, route: Dictionary, theme: Dictionary,
		transfer: Vector2i, floor_y: int) -> void:
	var hatch_y := transfer.y+12
	Scene._wall(doc,"elephant-platform",theme.wall,5,floor_y,256)
	Scene._wall(doc,"elephant-pier",theme.pier,5,hatch_y+48,16,floor_y-hatch_y-48)
	Scene._wall(doc,"elephant-roof",theme.wall,5,hatch_y+32,80)
	Scene._wall(doc,"elephant-side",theme.pier,245,hatch_y+48,16,floor_y-hatch_y-48)
	Scene._wall(doc,"elephant-eave",theme.wall,181,hatch_y+32,80)
	Scene._piece(doc,"eunice",68,Vector2i(145,floor_y-56))
	Scene._piece(doc,"peanut",58,Vector2i(141,hatch_y-39))
	Scene._piece(doc,"peanut-hatch",78,Vector2i(106,hatch_y))
	Scene._piece(doc,"branch-sheave",17,transfer+Vector2i(68,-43))
	Scene._piece(doc,"peanut-sheave",17,Vector2i(159,transfer.y+64),true)
	Scene._rope(doc,"peanut-line",["teeter","branch-sheave","peanut-sheave","peanut-hatch"],[1,0],true)
	_open_hatch(route,"peanut-hatch","peanut","elephant bay")
	Scene._step(route,Scene._event("deactivated","peanut","eunice"), "Eunice catches and eats the peanut.")

static func _shutter_booth(doc: Dictionary, route: Dictionary, theme: Dictionary, transfer: Vector2i) -> void:
	var shelf_y := transfer.y-16
	Scene._wall(doc,"projection-shelf",theme.wall,37,shelf_y,144)
	Scene._wall(doc,"shutter",theme.pier,37,shelf_y-48,16,48)
	Scene._wall(doc,"projection-footer",theme.pier,37,shelf_y+16,16,64)
	Scene._wall(doc,"projection-step",theme.wall,37,shelf_y+80,144)
	Scene._pistol(doc,"booth-pistol",Vector2i(242,shelf_y-32),true)
	Scene._piece(doc,"charge",19,Vector2i(71,shelf_y-45))
	Scene._piece(doc,"branch-sheave",17,transfer+Vector2i(77,-68))
	Scene._piece(doc,"shutter-sheave",17,Vector2i(298,shelf_y-15),true)
	Scene._rope(doc,"booth-line",["teeter","branch-sheave","shutter-sheave","booth-pistol"],[1,0],true)
	Scene._shot(route,"booth-pistol","charge","middle booth")
	Scene._step(route,{"kind":"inactive","part":"charge"}, "The Ball Bomb bursts against the shutter.")
	Scene._step(route,{"kind":"inactive","part":"shutter"}, "The blast opens the shutter.")
