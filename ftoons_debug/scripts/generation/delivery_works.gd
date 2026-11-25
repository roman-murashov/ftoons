extends RefCounted
## Plan a receiving bay first, then connect it to a release, crossing or volley.
## Flight envelopes use the native bearing diameter, gravity and rebound speed.
const Board := preload("res://scripts/generation/room_board.gd")
const ROUTES := {
	"freight-brake":["brake"], "missing-viaduct":["bridge"], "circus-catch":["toss"],
	"springboard-mail":["spring"], "viaduct-brake":["bridge","brake"], "circus-brake":["toss","brake"],
	"double-vault":["spring","spring"], "circus-volley":["toss","spring"], "viaduct-vault":["bridge","spring"],
	"double-vault-brake":["spring","spring","brake"], "circus-volley-brake":["toss","spring","brake"],
	"viaduct-vault-brake":["bridge","spring","brake"]
}
const TITLES := {
	"freight-brake":"Brake for the Siding", "missing-viaduct":"The Missing Span", "circus-catch":"Eunice Takes Aim",
	"springboard-mail":"Springboard Post", "viaduct-brake":"Bridge to the Ball Bin", "circus-brake":"Catch That Toss",
	"double-vault":"The Two-Spring Vault", "circus-volley":"Eunice at the High Jump", "viaduct-vault":"The Viaduct Vault",
	"double-vault-brake":"Three Cushion Delivery", "circus-volley-brake":"The Grandstand Catch",
	"viaduct-vault-brake":"Last Stop on the Viaduct"
}
const SETS := [
	{"room":"Bell Foundry","rails":26,"piers":28,"roof":48,"bay":27},
	{"room":"Treetop Railway","rails":27,"piers":29,"roof":50,"bay":28},
	{"room":"Sugar Pavilion","rails":83,"piers":27,"roof":47,"bay":26},
	{"room":"Fossil Depot","rails":82,"piers":28,"roof":84,"bay":29},
]

static func candidates(tier: int) -> Array:
	match tier:
		1: return ["freight-brake","missing-viaduct","circus-catch"]
		2: return ["springboard-mail","viaduct-brake","circus-brake"]
		3: return ["double-vault","circus-volley","viaduct-vault"]
		4: return ["double-vault-brake","circus-volley-brake","viaduct-vault-brake"]
	return []

static func _contact(id: String) -> Dictionary:
	return {"kind":"event","part":"bearing","event":"contact","other":id}

static func _snap(value: float) -> int:
	return roundi(value / 16.0) * 16

static func _piece(doc: Dictionary, id: String, type: int, x: int, y: int,
		width := 0, height := 0, loose := false) -> Dictionary:
	var row := Board.piece(doc,id,type,Vector2i(x,y),not loose,Vector2i(width,height))
	if loose: doc.generator.solution_placements.append({"part":id,"top_left":[x,y]})
	return row

static func _ramp(doc: Dictionary, id: String, type: int, at: Vector2i, width: int, flip := false) -> void:
	var ramp := _piece(doc,id,type,at.x,at.y,width,32)
	ramp.appearance = (width >> 4)-1
	ramp.height_2 = 16
	if flip: ramp.flags_2 = int(ramp.flags_2) | 16

static func _support(doc: Dictionary, id: String, theme: Dictionary, x: int, top: int, w: int,
		foot: int) -> void:
	_piece(doc,id+"-beam",theme.rails,x,top,w,16)
	var high := foot - top - 16
	if high < 16: return
	_piece(doc,id+"-pier",theme.piers,x,top+16,16,high)
	if w >= 64: _piece(doc,id+"-pier2",theme.piers,x+w-16,top+16,16,high)

static func build(id: String, tier: int, rng: RandomNumberGenerator) -> Dictionary:
	if not ROUTES.has(id) or id not in candidates(tier): return {}
	var route: Array = ROUTES[id]
	var toss := route.has("toss")
	var bridge := route.has("bridge")
	var springs := route.count("spring")
	var brake := route.has("brake")
	var theme: Dictionary = SETS[rng.randi_range(0,SETS.size()-1)]
	# Local coordinates relative to the release station. Pick the receiver height
	# and usable width, then work back from its landing mouth to each launcher.
	var span := rng.randi_range(4,6)*16
	var mouth := rng.randi_range(3,4)*16 if brake and springs else rng.randi_range(4,6)*16
	var lift := rng.randi_range(0,2)*16
	var bay_y: int
	var travel: int
	var pad_y: int
	var pad_x: int
	if toss:
		pad_y = 32
		pad_x = 144
		bay_y = (-80 if springs else -32) + lift
		travel = (224 if springs else 144) + _snap(lift*0.22)
	else:
		pad_y = 128
		pad_x = 112 + (span-32 if bridge else 0)
		if springs:
			bay_y = (48 if springs == 2 else 32) + lift
			travel = (272 if springs == 2 else 224) + (span-32 if bridge else 0) + _snap(lift*0.18)
		else:
			bay_y = (112 if bridge else 144) + lift
			travel = (span+112 if bridge else 144) + _snap(lift*0.32)
	# Select a tile-aligned destination and fit the upstream construction to it.
	var bay_left := rng.randi_range(16,24)*16+5
	bay_left = maxi(bay_left,travel+37)
	var station_x := bay_left - travel + 16
	var station_y := (rng.randi_range(14,16) if toss else rng.randi_range(6,8))*16+8
	var floor_y := station_y + bay_y
	var dock_right := bay_left + mouth
	var doc := Board.blank()
	doc.title = "%s at %s" % [TITLES[id],theme.room]
	var set_design := "siding"
	if toss: set_design = "grandstand"
	elif bridge: set_design = "viaduct"
	elif springs: set_design = "spring-course"
	doc.generator = {"room_name":theme.room,"mechanism":TITLES[id],"challenge_key":"freight/"+"-".join(route),
		"set_design":"freight/" + set_design,
		"goal_family":"Reach or leave a place", "replay_limit":300,"solution_placements":[], "branches":[]}
	var conditions := []
	var descriptions := []
	var player_steps := []
	# A contrasting floor and the upturned lip identify the destination even
	# when the end stop is in the parts bin.
	_piece(doc,"bay-floor",theme.bay,bay_left,floor_y,mouth,16)
	_piece(doc,"backstop",theme.bay,dock_right,floor_y-64,16,80,brake)
	if not springs and not toss:
		_piece(doc,"near-lip",theme.bay,bay_left-16,floor_y-16,16,32)
	if not springs: _piece(doc,"bay-foot",theme.piers,bay_left,floor_y+16,16,376-floor_y-16)
	_piece(doc,"far-foot",theme.piers,dock_right,floor_y+16,16,376-floor_y-16)
	_piece(doc,"bay-foundation",theme.piers,bay_left-16,376,mouth+48,16)
	if toss:
		_piece(doc,"bearing",31,station_x+rng.randi_range(24,31),station_y-rng.randi_range(70,114))
		_piece(doc,"eunice",68,station_x,station_y,0,0,true)
		_support(doc,"stage",theme,station_x-16,station_y+64,112,376)
		# The partition makes the necessary arc visible.
		_piece(doc,"partition",theme.rails,station_x+96,station_y-48,16,376-station_y+48)
		# Raked seating climbs away from the ring, clear of Eunice's launch.
		var steps := mini(4, floori(float(station_x-21)/32.0))
		for i in steps:
			var seat_x := station_x-48-32*i
			var seat_y := station_y+48-16*i
			_piece(doc,"seat-%d" % i,theme.bay,seat_x,seat_y,32,16)
			if i == steps-1: _piece(doc,"grandstand-post",theme.piers,seat_x,seat_y+16,16,376-seat_y-16)
		conditions.append({"kind":"event","part":"bearing","event":"launched_by","other":"eunice"})
		descriptions.append("Eunice tosses the bearing over the partition.")
		player_steps.append("position Eunice to toss the bearing over the partition")
	else:
		_piece(doc,"bearing",31,station_x+rng.randi_range(3,5),station_y-rng.randi_range(53,58))
		_ramp(doc,"release",theme.roof,Vector2i(station_x,station_y),64)
		_support(doc,"release-stage",theme,station_x-48,station_y+32,112,376)
		_piece(doc,"loading-ladder",45,station_x-48,station_y+48,32,376-station_y-48)
		conditions.append(_contact("release"))
		descriptions.append("The bearing rolls off the sloping release track.")
		if bridge:
			# Corbels support either end of the unfinished viaduct.
			_piece(doc,"abutment",theme.piers,station_x+64,station_y+64,32,16)
			_piece(doc,"abutment-foot",theme.piers,station_x+64,station_y+80,16,296-station_y)
			_piece(doc,"bridge",theme.rails,station_x+64,station_y+32,span,16,true)
			conditions.append(_contact("bridge"))
			descriptions.append("The bridge carries the bearing across the gap.")
			player_steps.append("span the gap beyond the release track")
		else:
			# The covered shed frames the release point with open track ahead.
			var roof_width := 32 if springs else 48
			var eave_x := station_x-32
			var eave_y := station_y-96
			_ramp(doc,"shed-left",theme.roof,Vector2i(eave_x,eave_y),roof_width,true)
			_ramp(doc,"shed-right",theme.roof,Vector2i(eave_x+roof_width,eave_y),roof_width)
			_piece(doc,"shed-post",theme.piers,eave_x,eave_y+32,16,96)
	if springs:
		_piece(doc,"spring",24,station_x+pad_x,station_y+pad_y,0,0,true)
		_support(doc,"vault-stage",theme,station_x+pad_x,station_y+pad_y+32,64,376)
		if springs == 1 and not toss and not bridge:
			var hurdle_x := station_x+pad_x+64
			_piece(doc,"hurdle",theme.rails,hurdle_x,station_y+80,16,296-station_y)
		conditions.append(_contact("spring"))
		descriptions.append("The bearing rebounds from the Air Mattress.")
		player_steps.append("bounce it up to the landing" if toss or bridge else "position the Air Mattress for a high bounce")
		if springs == 2:
			_piece(doc,"spring-two",24,station_x+208,station_y+64,0,0,true)
			_support(doc,"upper-stage",theme,station_x+224,station_y+96,32,376)
			conditions.append(_contact("spring-two"))
			descriptions.append("The second Air Mattress catches the bearing and sends it onward.")
			player_steps.append("catch the rebound on the second Air Mattress")
	if brake: player_steps.append("fit a stop to keep the bearing on the landing")
	conditions.append(_contact("bay-floor"))
	descriptions.append("The bearing lands on the receiving bay.")
	var target_area := [bay_left-8,floor_y-84,dock_right+1,floor_y+2]
	conditions.append({"kind":"hold","updates":72,"condition":{"kind":"in_area","part":"bearing", "rect":target_area}})
	descriptions.append("The bearing stays inside the receiving bay.")
	var action: String = ", then ".join(player_steps)
	doc.goal = "Deliver the bearing to the receiving bay. %s." % (action.left(1).to_upper()+action.substr(1))
	doc.goals = {"version":1,"delay_updates":6,"when":{"kind":"sequence","of":conditions}}
	doc.generator.branches.append({"events":descriptions.map(func(line):return {"description":line})})
	if not toss and not springs and rng.randi_range(0,1):
		_reflect(doc,target_area)
	return doc

static func _reflect(doc: Dictionary, target_area: Array) -> void:
	# The editor grid starts at x=5. Mirror about its axis so the player's
	# fixed-size bridge and stop can be placed on the same grid as the proof.
	for row: Dictionary in doc.parts:
		var width := maxi(int(row.width_1),int(row.width_2))
		var x := 554-int(row.pos_x)-width
		if int(row.flags_3)&8 == 0: x = 5 + _snap(x-5)
		row.pos_x = x
		if row.part_type in [47,48,49,50,68,84]:
			row.flags_2 = int(row.flags_2)^16
		for drop: Dictionary in doc.generator.solution_placements:
			if drop.part == row.id: drop.top_left[0] = x
	var left := int(target_area[0])
	target_area[0] = 540-int(target_area[2])
	target_area[2] = 540-left
