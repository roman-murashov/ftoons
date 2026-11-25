extends RefCounted
## Compose walkable sets backwards from a meal destination or a balloon's
## final pin. Each missing span, landing or pin is a native inventory piece.
const Board := preload("res://scripts/generation/room_board.gd")
const ROUTES := {
	"fish-footbridge": ["bridge"],
	"balloon-skylight": ["pin"],
	"catch-of-the-day": ["shelf"],
	"bakery-chute": ["bridge", "shelf"],
	"mouse-underpass": ["bridge", "tunnel"],
	"balloon-release": ["release"],
	"pie-hatch": ["hatch"],
	"lift-delivery": ["hatch", "bridge"],
	"airmail-supper": ["hatch", "shelf", "bridge"],
	"signal-bridge": ["bridge", "pin"],
	"market-deliveries": ["bridge", "second-shelf"],
	"freight-exchange": ["bridge", "tunnel", "shelf"],
	"festival-stalls": ["bridge", "shelf", "release"]
}
const THEMES := [
	{"set":"Tidewater Quay","deck":27,"pier":28,"roof":48},
	{"set":"Rooftop Market","deck":29,"pier":27,"roof":50},
	{"set":"Sugar Arcade","deck":83,"pier":27,"roof":47},
	{"set":"Steam Depot","deck":26,"pier":28,"roof":49}
]
const TITLES := {
	"fish-footbridge":"Crossing for Lunch", "balloon-skylight":"Up Through the Skylight",
	"catch-of-the-day":"Catch of the Day", "bakery-chute":"The Broken Walkway",
	"mouse-underpass":"Underpass Express", "balloon-release":"The Balloon Booth",
	"signal-bridge":"Opening Day", "market-deliveries":"Two Lunch Counters",
	"freight-exchange":"Freight Exchange","festival-stalls":"At the Fair",
	"pie-hatch":"Lunch from the Loft","lift-delivery":"A Little Lift","airmail-supper":"Air Mail Supper"
}

static func _existing(tier: int) -> Array:
	match tier:
		1: return ["fish-footbridge","balloon-skylight","catch-of-the-day"]
		2: return ["bakery-chute","mouse-underpass","balloon-release","pie-hatch"]
		3: return ["signal-bridge","market-deliveries","lift-delivery"]
		4: return ["freight-exchange","festival-stalls","airmail-supper"]
	return []

# A meal requires a way to serve the food and a way for the diner to
# reach it. A skylight requires a release point and a pin. Fill the
# prerequisites independently, allowing the two destinations to share a set.
const SERVING := {"table":[], "counter":["shelf"], "loft":["hatch"], "loft-counter":["hatch","shelf"]}
const ACCESS := {"walk":[], "span":["bridge"], "entry":["guest"]}
const SKYLIGHT := {"none":[], "fit-pin":["pin"], "launch":["release"], "rig":["pin","release"]}
static var _plans_by_tier := {}

static func _decisions(mods: Array) -> String:
	var pieces := mods.duplicate()
	pieces.erase("tunnel")
	pieces.sort()
	return "+".join(pieces)

static func _plans(tier: int) -> Dictionary:
	if _plans_by_tier.has(tier): return _plans_by_tier[tier]
	var plans := {}
	var occupied := {}
	for route: Array in ROUTES.values(): occupied[_decisions(route)] = true
	for id: String in _existing(tier):
		plans[id] = ROUTES[id]
	for serving: String in SERVING:
		for access: String in ACCESS:
			var meal: Array = SERVING[serving] + ACCESS[access]
			for skylight: String in SKYLIGHT:
				var signal_parts: Array = SKYLIGHT[skylight]
				var shared := not meal.is_empty() and not signal_parts.is_empty()
				# Keep the guest's marked approach full width. The serving
				# loft already has its own balloon operating the trap door.
				if shared and ("guest" in meal or "hatch" in meal): continue
				var parts := meal + signal_parts
				if parts.is_empty(): continue
				var weight := parts.size() + int(shared) + int("hatch" in parts)
				if weight != tier: continue
				var key := _decisions(parts)
				if occupied.has(key): continue
				occupied[key] = true
				plans["stage-%s-%s-%s" % [serving,access,skylight]] = parts
	_plans_by_tier[tier] = plans
	return plans

static func candidates(tier: int) -> Array:
	return _plans(tier).keys()

static func _title(mods: Array) -> String:
	var meal := ""
	if "guest" in mods:
		meal = "Dinner at the Departure Gate"
		if "shelf" in mods: meal = "A Table for the Late Arrival"
		if "hatch" in mods: meal = "Meet the Loft Delivery" if not "shelf" in mods else "Set a Table for the Loft Delivery"
	elif "hatch" in mods: meal = "Catch the Loft Delivery"
	elif "shelf" in mods and "bridge" in mods: meal = "The Broken Lunch Counter"
	elif "shelf" in mods: meal = "The Lunch Counter"
	elif "bridge" in mods: meal = "The Lunch Bridge"
	var signal_name := ""
	if "pin" in mods and "release" in mods: signal_name = "Rigging the Skylight"
	elif "pin" in mods: signal_name = "Signal Pin"
	elif "release" in mods: signal_name = "Signal Launch"
	if signal_name.is_empty(): return meal
	if meal.is_empty(): return signal_name
	return signal_name + " over " + meal.replace("The ", "the ")

static func _terrain(doc: Dictionary, type: int, rect: Rect2i, fixed := true, id := "") -> Dictionary:
	var key := id if not id.is_empty() else "structure-%d" % doc.parts.size()
	return Board.piece(doc,key,type,rect.position,fixed,rect.size)

static func _awning(doc: Dictionary, rng: RandomNumberGenerator, theme: Dictionary, x: int, floor_y: int, over_left: bool) -> void:
	var y := floor_y - 96
	var style := rng.randi_range(0,2)
	if style == 0: # Pitched canopy above the passenger side.
		for half in 2:
			var roof := _terrain(doc, theme.roof, Rect2i(x + half * 48, y, 48, 32))
			roof.appearance = 2
			roof.height_2 = 16
			if half == 0: roof.flags_2 = int(roof.flags_2) | 0x10
	elif style == 1: # Stepped parapet on a flat ticket office.
		var back := x if over_left else x+32
		_terrain(doc,theme.pier,Rect2i(back,y+16,64,16))
		_terrain(doc,theme.deck,Rect2i(x if over_left else x+64,y,32,16))
	else: # An accessible loading balcony with a ladder above deck level.
		_terrain(doc,theme.deck,Rect2i(x,y-16,64,16))
		_terrain(doc,45,Rect2i(x+16,y,32,32))
	_terrain(doc,theme.deck,Rect2i(x,y+32,96,16))
	_terrain(doc,theme.pier,Rect2i(x if over_left else x+80,y+48,16,48))

static func _sight(actor: String, item: String) -> Dictionary:
	return {"kind":"targets","part":actor,"other":item}

static func _event(action: String, actor: String, item: String) -> Dictionary:
	return {"kind":"event","event":action,"part":actor,"other":item}

static func _add_step(route: Dictionary, node: Dictionary, text: String) -> void:
	route.nodes.append(node)
	route.events.append({"description":text})

static func _store_branch(doc: Dictionary, route: Dictionary, sequences: Array) -> void:
	sequences.append({"kind":"sequence","of":route.nodes})
	doc.generator.branches.append({"events":route.events})

static func _meal(doc: Dictionary, rng: RandomNumberGenerator, theme: Dictionary, bounds: Rect2i,
		inventory_bridge: bool, inventory_shelf: bool, tunnel: bool, sid: bool, hatch := false,
		guest := false, service_balcony := false) -> Dictionary:
	var left := bounds.position.x
	var right := bounds.end.x
	var floor_y := bounds.position.y
	# The serving platform must end within eating distance of the actor's
	# walk. Build outwards from the destination across any intervening span.
	var food := "cheese" if sid else "fish"
	var actor := "Sid" if sid else "Al"
	var facing_right := rng.randi_range(0,1) == 1
	var bridge_width := 16 * rng.randi_range(4,6) if inventory_bridge else 0
	var shelf_width := 96 if sid else 112
	var gap := 16 * rng.randi_range(5,8)
	var close_bank := mini(gap,bounds.size.x-shelf_width-bridge_width) if inventory_bridge else bounds.size.x-shelf_width
	var actor_x := left+20 if facing_right else right-64
	var food_x := right-shelf_width+10 if facing_right else left+24
	# A left-edge loft needs room for the dish to tip off the hinge and
	# settle on the platform while the diner is approaching from the right.
	if hatch and not facing_right: food_x += 24
	var bridge_x := left + close_bank if facing_right else right - close_bank - bridge_width
	var shelf_x := right - shelf_width if facing_right else left
	var post_height := bounds.size.y - 16
	var route := {"events":[],"nodes":[]}
	var target_id := actor+"-meal"
	var bridge_id := actor+"-span"
	var shelf_id := actor+"-landing"
	var upper_delivery := inventory_shelf and tunnel
	var kitchen_y := floor_y - 25
	if inventory_shelf and not tunnel: kitchen_y -= 16 * rng.randi_range(3,5)
	if hatch:
		var hatch_y := floor_y - 16*rng.randi_range(7,10)
		kitchen_y = hatch_y-28
		var hatch_x := food_x-21
		Board.piece(doc,"hatch",78,Vector2i(hatch_x,hatch_y))
		var apron_width := 16*rng.randi_range(4,7)
		var apron_x := hatch_x-apron_width
		# Attach the upper loading walkway to the hinge side. Keep the
		# underside clear so the balloon can lift the hatch from below.
		if apron_x>=left:
			_terrain(doc,theme.deck,Rect2i(apron_x,hatch_y,apron_width,16))
			_terrain(doc,theme.pier,Rect2i(apron_x,hatch_y-48,16,48))
			_terrain(doc,theme.deck,Rect2i(apron_x,hatch_y-64,apron_width+64,16))
		else:
			_terrain(doc,theme.deck,Rect2i(hatch_x+64,hatch_y,apron_width,16))
			_terrain(doc,theme.pier,Rect2i(hatch_x+48+apron_width,hatch_y-48,16,48))
			_terrain(doc,theme.deck,Rect2i(hatch_x,hatch_y-64,apron_width+64,16))
		Board.piece(doc,"air-post",23,Vector2i(hatch_x+rng.randi_range(-10,28),floor_y-62),false)
		_add_step(route,_event("contact","air-post","hatch"),"The rising balloon bumps the trap door.")
		_add_step(route,{"kind":"compare","part":"hatch","field":"appearance","op":"gt","value":0},
				"The trap door opens under the cheese.")
	if inventory_bridge:
		_terrain(doc,theme.deck,Rect2i(bridge_x,floor_y,bridge_width,16),false,bridge_id)
	var segments := []
	if facing_right:
		segments.append(Vector2i(left,bridge_x-left))
		segments.append(Vector2i(bridge_x+bridge_width,shelf_x-bridge_x-bridge_width))
	else:
		segments.append(Vector2i(shelf_x+shelf_width,bridge_x-shelf_x-shelf_width))
		segments.append(Vector2i(bridge_x+bridge_width,right-bridge_x-bridge_width))
	for segment: Vector2i in segments:
		if segment.y > 0: _terrain(doc,theme.deck,Rect2i(segment.x,floor_y,segment.y,16))
	_terrain(doc,theme.deck,Rect2i(shelf_x,floor_y,shelf_width,16),not inventory_shelf or tunnel,shelf_id)
	for x in [left, right-16]:
		_terrain(doc,theme.pier,Rect2i(x,floor_y+16,16,post_height))
	# The canopy shelters the actor's end. The delivery bay is open above.
	_awning(doc,rng,theme,left if facing_right else right-96,floor_y,facing_right)
	if service_balcony:
		# Frame the counter from its far edge; the delivery still has a
		# clear drop and the diner can see the plate from the entry.
		var length := 16*rng.randi_range(7,11)
		var height := 16*rng.randi_range(9,12)
		var balcony_x := right-length if facing_right else left
		var support := right-16 if facing_right else left
		_terrain(doc,theme.pier,Rect2i(support,floor_y-height+16,16,height-16))
		_terrain(doc,theme.deck,Rect2i(balcony_x,floor_y-height,length,16))
		_terrain(doc,theme.pier,Rect2i(support,floor_y-height-32,16,32))
		_terrain(doc,theme.deck,Rect2i(balcony_x,floor_y-height-48,length,16))
	var dish_type := 57 if sid else 56
	Board.piece(doc,actor,37 if sid else 36,Vector2i(actor_x,floor_y-(28 if sid else 37)),not guest)
	Board.piece(doc,target_id,dish_type,Vector2i(food_x,kitchen_y))
	# At the far side, the tunnel takes Sid to a second serving counter.
	if tunnel:
		var entrance_x := bridge_x+bridge_width+8 if facing_right else bridge_x-64
		var upper_y := floor_y - 128
		var outlet_x := left+48 if facing_right else right-112
		var a: int = doc.parts.size()
		var entrance := Board.piece(doc,"entrance",46,Vector2i(entrance_x,floor_y-48),true,Vector2i(56,47))
		var outlet := Board.piece(doc,"outlet",46,Vector2i(outlet_x,upper_y-48),true,Vector2i(56,47))
		entrance.tunnel_partner = a+1
		outlet.tunnel_partner = a
		var run_width := 16*rng.randi_range(14,18)
		var run_x := left if facing_right else right-run_width
		var upstairs_food_y := upper_y-26
		if upper_delivery:
			var counter_x := run_x+run_width-80 if facing_right else run_x
			_terrain(doc,theme.deck,Rect2i(counter_x,upper_y,80,16),false,"upper-counter")
			_terrain(doc,theme.deck,Rect2i(run_x if facing_right else run_x+80,upper_y,run_width-80,16))
			upstairs_food_y -= 16*rng.randi_range(2,4)
		else:
			_terrain(doc,theme.deck,Rect2i(run_x,upper_y,run_width,16))
		Board.piece(doc,"upstairs-meal",57,Vector2i(run_x+run_width-65 if facing_right else run_x+20,upstairs_food_y))
	if inventory_shelf and not tunnel:
		_add_step(route,_event("contact",target_id,shelf_id),"The falling %s lands on the serving shelf." % food)
	_add_step(route,_sight(actor,target_id),"%s sees the %s across the walkway." % [actor,food])
	if guest:
		var gate_line := left+96 if facing_right else right-112
		_add_step(route,{"kind":"crosses","part":actor,"direction":"right" if facing_right else "left",
			"line":gate_line,"span":[floor_y-64,floor_y]},"%s walks through the entry awning toward the meal." % actor)
	if inventory_bridge:
		_add_step(route,_event("contact",actor,bridge_id),"%s crosses the repaired span." % actor)
	if tunnel:
		_add_step(route,_event("tunnel_from",actor,"entrance"),"Sid follows the tunnel to the upper counter.")
		target_id = "upstairs-meal"
	var eaten := _event("deactivated",target_id,actor)
	if tunnel:
		# The meal must actually be served upstairs. Food dropped to the
		# lower floor can still be eaten there if the counter is missing.
		eaten = {"kind":"all","of":[eaten, {"kind":"in_area","part":actor,"rect":[left,0,right,floor_y-96]}]}
	_add_step(route,eaten,"%s eats the %s." % [actor,food])
	var instructions := []
	if guest: instructions.append("Start %s under the %s entry awning." % [actor,"left" if facing_right else "right"])
	if hatch: instructions.append("Send the balloon up to open the loaded trap door.")
	if upper_delivery: instructions.append("Catch the falling cheese at the upstairs counter.")
	elif inventory_shelf: instructions.append("Catch the falling %s at %s's floor." % [food,actor])
	if inventory_bridge: instructions.append("Bridge the gap for %s." % actor)
	instructions.append("Send Sid through the tunnel to the upstairs cheese." if tunnel else "Feed the %s to %s." % [food,actor])
	doc.goal = (doc.goal + " " + " ".join(instructions)).strip_edges()
	return route

static func _balloon(doc: Dictionary, rng: RandomNumberGenerator, theme: Dictionary, bay: Rect2i,
		place_balloon: bool, place_pin: bool) -> Dictionary:
	# Work down from the pin: leave a balloon-wide notch in the beams
	# around a clear vertical path, then set the release point in the booth.
	var width := bay.size.x
	var skyline := bay.position.y + 16
	var floor_y := bay.end.y - 16
	var lip := 16 * rng.randi_range(2, maxi(2,(width >> 4)-7))
	var opening := bay.position.x + lip
	var throat := 64
	var balloon_x := opening+rng.randi_range(8,16)
	_terrain(doc,theme.deck,Rect2i(bay.position.x,floor_y,width,16))
	for side in 2:
		var x := bay.position.x if side == 0 else bay.end.x-16
		_terrain(doc,theme.pier,Rect2i(x,skyline,16,floor_y-skyline))
	var roof_y := skyline+64
	_terrain(doc,theme.deck,Rect2i(bay.position.x,roof_y,lip,16))
	var remaining := bay.end.x-opening-throat
	if remaining >= 128:
		# A second vent ends below a blind roof. The pin marks the vent
		# through which the balloon can reach the requested destination.
		_terrain(doc,theme.deck,Rect2i(opening+throat,roof_y,32,16))
		_terrain(doc,theme.deck,Rect2i(opening+throat+80,roof_y,remaining-80,16))
		_terrain(doc,theme.deck,Rect2i(opening+throat+32,skyline+16,48,16))
	else:
		_terrain(doc,theme.deck,Rect2i(opening+throat,roof_y,remaining,16))
	_terrain(doc,theme.deck,Rect2i(opening-16,skyline-16,96,16))
	_terrain(doc,theme.pier,Rect2i(opening-16,skyline,16,64))
	Board.piece(doc,"signal-balloon",23,Vector2i(balloon_x,floor_y-64),not place_balloon)
	var pin := Board.piece(doc,"pin",63,Vector2i(balloon_x+15,skyline+4),not place_pin)
	pin.flags_2 = int(pin.flags_2) | 0x20
	var route := {"nodes":[],"events":[]}
	_add_step(route,{"kind":"crosses","part":"signal-balloon","direction":"up","line":roof_y,
		"span":[opening,opening+throat]},"The balloon rises through the skylight.")
	_add_step(route,_event("contact","signal-balloon","pin"),"The balloon touches the hat pin above the opening.")
	_add_step(route,{"kind":"inactive","part":"signal-balloon"},"The balloon pops.")
	var instruction := "Release the balloon through the skylight to reach the hat pin." if place_balloon else "Fit the hat pin above the skylight to pop the rising balloon."
	if place_pin and place_balloon:
		instruction = "Fit the hat pin above the open skylight and choose where to release the balloon so it rises into the pin."
	doc.goal = (doc.goal + " " + instruction).strip_edges()
	return route

static func build(id: String, tier: int, rng: RandomNumberGenerator) -> Dictionary:
	var mods: Array = ROUTES.get(id, _plans(tier).get(id, []))
	if mods.is_empty(): return {}
	var doc := Board.blank()
	var theme: Dictionary = THEMES[rng.randi_range(0,THEMES.size()-1)]
	var name: String = TITLES.get(id, _title(mods))
	doc.title = "%s at %s" % [name,theme.set]
	doc.goal = ""
	# Tunnels are part of the authored route. A tunnel after a single missing
	# bridge still asks for the same player decision as the short footbridge.
	var meal := "bridge" in mods or "shelf" in mods or "hatch" in mods or "guest" in mods
	doc.generator = {"room_name":theme.set,"mechanism":name,"challenge_key":"stage/"+_decisions(mods),
		"replay_limit":700 if "tunnel" in mods else 320,"branches":[],"solution_placements":[],
		"goal_family":"Reach an action or animation milestone" if meal else "Remove a part"}
	var sequences := []
	var balloon := "pin" in mods or "release" in mods
	var left := 5+16*rng.randi_range(0,2)
	var right := 533-16*rng.randi_range(0,2)
	var shared := meal and balloon
	var stage_design := "counter"
	if shared: stage_design = "two-booths"
	elif balloon: stage_design = "skylight"
	elif "hatch" in mods: stage_design = "trap-door"
	elif "tunnel" in mods or "second-shelf" in mods: stage_design = "two-storeys"
	doc.generator.set_design = "stage/" + stage_design
	var balloon_left := rng.randi_range(0,1) == 1
	if meal:
		var meal_left := left+160 if shared and balloon_left else left
		var meal_right := right-160 if shared and not balloon_left else right
		var floor_y := 296+16*rng.randi_range(0,3)
		var size := Vector2i(meal_right-meal_left,392-floor_y)
		var open_counter := not shared and "second-shelf" not in mods and "hatch" not in mods and "tunnel" not in mods
		var route := _meal(doc,rng,theme,Rect2i(Vector2i(meal_left,floor_y),size),
				"bridge" in mods,"shelf" in mods,"tunnel" in mods,"tunnel" in mods or "hatch" in mods,
				"hatch" in mods,"guest" in mods,open_counter)
		_store_branch(doc,route,sequences)
		if "second-shelf" in mods:
			var upper_y := floor_y-160
			var size2 := Vector2i(right-left-96,48)
			_store_branch(doc,_meal(doc,rng,theme,Rect2i(Vector2i(left+48,upper_y),size2),false,true,false,true),sequences)
	if balloon:
		var balloon_width := 144 if shared else 16*rng.randi_range(14,22)
		var x := left if balloon_left else right-balloon_width
		var y := 72+16*rng.randi_range(0,3)
		_store_branch(doc,_balloon(doc,rng,theme,Rect2i(x,y,balloon_width,376-y),"release" in mods,"pin" in mods),sequences)
		if not shared:
			# The service gallery adjoins the outside of the balloon booth.
			var gallery_width := mini(16*rng.randi_range(7,10),right-left-balloon_width)
			var gallery_x := x+balloon_width if balloon_left else x-gallery_width
			var post_x := gallery_x+gallery_width-16 if balloon_left else gallery_x
			var gallery_y := y+16*rng.randi_range(3,6)
			_terrain(doc,theme.deck,Rect2i(gallery_x,360,gallery_width,16))
			_terrain(doc,theme.pier,Rect2i(post_x,gallery_y+16,16,344-gallery_y))
			_terrain(doc,theme.deck,Rect2i(gallery_x,gallery_y,gallery_width,16))
			_terrain(doc,theme.deck,Rect2i(gallery_x,gallery_y+64,gallery_width,16))
	doc.goals = {"version":1,"delay_updates":8,"when":sequences[0] if sequences.size()==1 else {"kind":"all","of":sequences}}
	for row: Dictionary in doc.parts:
		if not int(row.flags_3) & 0x40:
			doc.generator.solution_placements.append({"part":row.id,"top_left":[row.pos_x,row.pos_y]})
	return doc
