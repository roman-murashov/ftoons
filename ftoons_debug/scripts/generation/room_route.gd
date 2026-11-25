extends RefCounted
## Follow one authored payload through the simulation. Only report a goal after
## seeing a contact and a distinct consequence involving that same payload.
const TERRAIN := [26,27,28,29,45,47,48,49,50,51,82,83,84]
const ACTORS := [35,36,37,68,69]
const MAP_GOAL := "Reach or leave a place"
const MACHINE_GOAL := "Operate, damage, or read a gadget"
const ACTION_GOAL := "Reach an action or animation milestone"
const REMOVE_GOAL := "Remove a part"
const TITLES := {2:"Switch Work", 3:"Tipping Point", 13:"Cleanup Crew", 22:"Ratapult Relay",
	24:"High Bounce", 35:"Dragon Call", 36:"Cat's Errand", 37:"Mouse Trap", 38:"On the Clock",
	39:"Count It", 40:"Thump and Run", 41:"Ramp Run", 68:"Elephant Express", 69:"Hen Call",
	78:"Trapdoor Test", 80:"Feeding Time"}
static var names := {}

var index: int
var source: String
var label: String
var origin: Vector2i
var rows: Array
var first := {}
var contacts := []
var visited := {}
var result := {}
var activated := {}
var retired := {}

const REGIONS := ["upper left","top center","upper right","middle left","center","middle right",
	"lower left","bottom center","lower right"]

func _init(slot: int, parts: Array) -> void:
	index = slot
	rows = parts
	source = rows[index].id
	label = part_name(slot, true)
	origin = Vector2i(rows[index].pos_x, rows[index].pos_y)

func part_name(slot: int, is_delivery := false) -> String:
	if names.is_empty():
		var catalog: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/original/part_type_names.json"))
		for item in catalog.types:
			if item.name is String: names[int(item.id)] = item.name
	var row: Dictionary = rows[slot]
	var type := int(row.part_type)
	var name_text: String = {36:"Al",37:"Sid",68:"Eunice",69:"Hildegard"}.get(type, names.get(type, "gadget"))
	if is_delivery: return "the " + name_text
	var copies := []
	for i in rows.size():
		if int(rows[i].part_type) != type: continue
		copies.append(i)
	if copies.size() < 2: return name_text if type in [36,37,68,69] else "the " + name_text
	# Many factory levels have long tile runs. Narrow to a visible part of the
	# room first, then distinguish neighboring copies on their widest axis.
	var region_text := ""
	if copies.size() > 2:
		var region := _region(row)
		copies = copies.filter(func(i): return _region(rows[i]) == region)
		region_text = " in the " + REGIONS[region]
		if copies.size() == 1: return "the " + name_text + region_text
	var positions := Rect2i(_center(rows[copies[0]]),Vector2i.ZERO)
	for i in copies: positions = positions.expand(_center(rows[i]))
	var horizontal := positions.size.x >= positions.size.y
	copies.sort_custom(func(a,b):
		var pa := _center(rows[a])
		var pb := _center(rows[b])
		if not horizontal: return Vector2i(pa.y,pa.x) < Vector2i(pb.y,pb.x)
		return pa < pb)
	var n := copies.find(slot)
	if n == 0: return "the " + ("leftmost " if horizontal else "uppermost ") + name_text + region_text
	if n == copies.size()-1: return "the " + ("rightmost " if horizontal else "lowest ") + name_text + region_text
	if copies.size() == 3: return "the middle " + name_text + region_text
	var ordinal: String = {1:"second",2:"third",3:"fourth"}.get(n, str(n+1) + "th")
	return "the %s %s from the %s%s" % [ordinal, name_text, "left" if horizontal else "top", region_text]

func _center(row: Dictionary) -> Vector2i:
	return Vector2i(int(row.pos_x)+(int(row.width_1)>>1),int(row.pos_y)+(int(row.height_1)>>1))

func _region(row: Dictionary) -> int:
	var pos := _center(row)
	return clampi(floori(float(pos.x)/184),0,2) + 3*clampi(floori(float(pos.y)/134),0,2)

func observe(runner: SimulationRunner) -> void:
	var state := runner.state
	for event: Dictionary in state.trace:
		var slot := int(event.part_index)
		if event.kind == "spawn": retired[slot] = true
		if retired.has(index): return
		var other := -1
		match event.kind:
			"contact", "moving_contact":
				if slot == index: other = int(event.other)
				elif int(event.other) == index: other = slot
				if _named(other): _contact(other, state)
			"reaction_request":
				if int(event.producer) == index and _named(slot) and int(event.request) != 0 and event.reason != "sight":
					activated[slot] = {"tick":state.tick,"request":int(event.request),"reason":event.reason}
			"deactivate":
				other = int(event.get("producer", -1))
				if slot == index and _named(other) and not first.is_empty() and state.tick > int(first.tick):
					var verb := "Feed %s to %s" if int(rows[other].part_type) in ACTORS else "Have %s collect %s"
					var text := verb % [label, part_name(other)] if int(rows[other].part_type) in ACTORS else verb % [part_name(other), label]
					_offer(100, state.tick, {"kind":"event","event":"deactivated","part":source,"other":rows[other].id}, text, REMOVE_GOAL, other)
			"Eunice_launch":
				if int(event.target) == index and _named(slot) and not first.is_empty() and state.tick > int(first.tick):
					_offer(99, state.tick, {"kind":"event","event":"launched_by","part":source,"other":rows[slot].id},
						"Get %s to launch %s" % [part_name(slot), label], ACTION_GOAL, slot)
	if first.is_empty() or state.tick <= int(first.tick): return
	var recent: Dictionary = contacts.back()
	var slot := int(recent.slot)
	if activated.has(slot) and _named(slot) and state.tick - int(activated[slot].tick) < 15:
		var target := state.parts[slot]
		for field in ["state", "appearance"]:
			var now := int(target.goal_value(field))
			var initial := int(recent[field])
			if now == initial: continue
			var type := int(rows[slot].part_type)
			# Al and Sid change animation continuously. Accept their named interaction
			# only if the payload's request actually became the actor's active state.
			if type in [36,37] and (field != "state" or now != int(activated[slot].request)): continue
			var action: String = {2:"switch",3:"tip",22:"fire",24:"compress",35:"wake",40:"trip",68:"rouse",69:"startle",78:"open",80:"start"}.get(type, "activate")
			var text := "Use %s to %s %s" % [label, action, part_name(slot)]
			if type in [36,37]:
				if activated[slot].reason in ["Cheese contact","Fish contact"]: continue # Observe actual consumption instead.
				text = "Make %s react to a hit from %s" % [part_name(slot),label]
			_offer(80, state.tick, {"kind":"compare","part":rows[slot].id,"field":field,"op":"eq","value":now},
				text, ACTION_GOAL if type in ACTORS else MACHINE_GOAL, slot)
			break
	# A rebound must take the payload back up through a visible height, well
	# above its observed impact. Falling past an arbitrary line never qualifies.
	if not state.parts[index].active: return
	var line := int(first.y) - 32
	if line < 12 or RopePhysics.xy(state.parts[index]).y >= line: return
	var condition := {"kind":"crosses","part":source,"direction":"up","line":line,"span":[0,552]}
	if contacts.size() == 1:
		_offer(30, state.tick, condition, "Bounce %s two wall tiles above its impact on %s" % [label, first.label], MAP_GOAL, slot)

func _named(slot: int) -> bool:
	return slot >= 0 and slot < rows.size() and not retired.has(slot)

func _contact(other: int, state: SimulationState) -> void:
	if visited.has(other) or contacts.size() >= 4: return
	if not contacts.is_empty() and int(rows[other].part_type) in TERRAIN:
		var previous: Dictionary = rows[int(contacts.back().slot)]
		# A trip over a row of scenery is one leg. One entry and one landing
		# are enough to describe it, even if the floor has several materials.
		if contacts.size() >= 2 and int(previous.part_type) in TERRAIN and int(rows[int(contacts[-2].slot)].part_type) in TERRAIN: return
		if int(previous.part_type) == int(rows[other].part_type):
			var a := Rect2i(previous.pos_x,previous.pos_y,previous.width_1,previous.height_1)
			var b: Dictionary = rows[other]
			if _region(previous) == _region(b) or a.grow(3).intersects(Rect2i(b.pos_x,b.pos_y,b.width_1,b.height_1)): return
	var p := state.parts[other]
	if not Rect2i(0, 0, 552, 400).has_point(RopePhysics.xy(state.parts[index])): return
	var condition := {"kind":"event","event":"contact","part":source,"other":rows[other].id}
	var entry := {"condition":condition, "tick":state.tick, "slot":other, "label":part_name(other),
		"state":int(p.goal_value("state")), "appearance":int(p.goal_value("appearance")), "y":RopePhysics.xy(state.parts[index]).y}
	if first.is_empty(): first = entry
	elif state.tick > int(contacts.back().tick):
		var score := 60 if int(rows[other].part_type) in TERRAIN else 75
		_offer(score, state.tick, condition, "Send %s from %s to %s" % [label, contacts.back().label, part_name(other)], MAP_GOAL, other)
	else: return
	visited[other] = true
	contacts.append(entry)

func _offer(score: int, tick: int, condition: Dictionary, text: String, family: String, last: int) -> void:
	if contacts.is_empty() or int(contacts.back().tick) >= tick: return
	var rank := score + 8 * (contacts.size()-1)
	if rank <= int(result.get("score", 0)): return
	var events := []
	var conditions := []
	var stops := PackedStringArray()
	var parents := []
	for entry: Dictionary in contacts:
		var id := "%s-contact-%d" % [source,entry.slot]
		events.append({"id":id, "description":"%s hits %s" % [label.capitalize(), entry.label],
			"depends_on":parents, "observed_update":entry.tick})
		conditions.append(entry.condition)
		parents = [id]
		stops.append(entry.label)
	events.append({"id":source+"-outcome", "description":text, "depends_on":parents, "observed_update":tick})
	conditions.append(condition)
	var instructions := text
	if condition.kind == "event" and condition.event == "contact":
		stops.append(part_name(last))
		instructions = "Send %s from %s to %s" % [label, stops[0], " and then to ".join(stops.slice(1))]
	elif score >= 80:
		# The action already names its receiving gadget or actor.
		if int(contacts.back().slot) == last: stops.remove_at(stops.size()-1)
		if not stops.is_empty(): instructions += " by way of " + " and then ".join(stops)
	var key := "operate-%d" % int(rows[last].part_type)
	if condition.kind == "event":
		match condition.event:
			"deactivated": key = "collect-%d" % int(rows[last].part_type)
			"launched_by": key = "launch"
			"contact": key = "platform-route" if int(rows[last].part_type) in TERRAIN else "reach-%d" % int(rows[last].part_type)
	elif condition.kind == "crosses": key = "rebound"
	result = {"starter":source, "events":events, "score":rank, "description":instructions, "family":family,
		"challenge_key":"delivery/" + key,
		"title":TITLES.get(int(rows[last].part_type), label.trim_prefix("the ") + " Run"),
		"condition":{"kind":"sequence","of":conditions}}
