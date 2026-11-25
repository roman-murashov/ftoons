extends RefCounted
## Compare relative wall geometry and machine neighborhoods. Names, decoration
## materials, marble colors, translation and horizontal reflection carry no score.
const WALLS := [26, 27, 28, 29, 82, 83]
const SLOPES := [47, 48, 49, 50, 51, 84]
const BALLS := [7, 8, 9, 10, 11, 31, 32, 33, 34]
const INDEX := "res://scripts/generation/campaign_fingerprints.json"
const REJECT_AT := 0.78
const GEOMETRY_WEIGHT := 0.9
const CELL := 8.0
static var _campaign := {}

static func _role(type: int) -> String:
	if type in WALLS: return "wall"
	if type in SLOPES: return "slope"
	if type in BALLS: return "ball"
	return str(type)

static func fingerprint(doc: Dictionary) -> Dictionary:
	var terrain := []
	var machines := []
	var machine_tokens := []
	var outlines := {}
	var center_sum := Vector2.ZERO
	for row: Dictionary in doc.parts:
		var type := int(row.part_type)
		if type in [1, 14]: continue # The graph below describes invisible connector records.
		var role := _role(type)
		var extent := Vector2i(int(row.width_1), int(row.height_1))
		var center := Vector2(row.pos_x, row.pos_y) + Vector2(extent) / 2
		if not outlines.has(role): outlines[role] = []
		# Only coarse relative centers and wall sizes enter the comparison index.
		var point := [center.x, center.y, 0, 0]
		if role in ["wall", "slope"] or type == 45:
			var shape := "%s-%d-%d" % [role, roundi(extent.x / 32.0), roundi(extent.y / 32.0)]
			terrain.append({"name":shape, "pos":center})
			point[2] = roundi(extent.x / 16.0)
			point[3] = roundi(extent.y / 16.0)
		else:
			# Factory balls have differing extents. Anchor them by their intended drop point.
			machines.append({"name":role, "pos":Vector2(row.pos_x, row.pos_y) if role == "ball" else center})
		outlines[role].append(point)
		center_sum += center
		for field in ["outlet_plugged_1", "outlet_plugged_2", "tunnel_partner"]:
			var to := int(row[field])
			if to >= 0:
				machine_tokens.append(("%s>%s:%s" % [role, field.trim_suffix("_1").trim_suffix("_2"),
					_role(int(doc.parts[to].part_type))]).hash())
	for kind in ["ropes", "belts"]:
		for link: Dictionary in doc[kind]:
			var route: Array = link.route if kind == "ropes" else link.ends
			for i in range(1, route.size()):
				var ends := [_role(int(doc.parts[int(route[i-1])].part_type)), _role(int(doc.parts[int(route[i])].part_type))]
				ends.sort()
				machine_tokens.append(("%s:%s:%s" % [kind, ends[0], ends[1]]).hash())
	_neighborhoods(machines, machine_tokens)
	var walls := []
	_neighborhoods(terrain, walls)
	var centroid := center_sum / maxi(1, terrain.size() + machines.size())
	for group: Array in outlines.values():
		for p: Array in group:
			p[0] = roundi((p[0] - centroid.x) / CELL)
			p[1] = roundi((p[1] - centroid.y) / CELL)
	var signature := {"walls":walls, "machines":machine_tokens, "wall_count":terrain.size(),
			"machine_count":machines.size(), "outlines":outlines}
	# The session uses the authored construction style for scheduling only.
	# Campaign comparison and the spatial copy score always use geometry.
	if doc.get("generator", {}).has("set_design"): signature.set_design = doc.generator.set_design
	return signature

static func _neighborhoods(nodes: Array, tokens: Array) -> void:
	for i in nodes.size():
		var a: Dictionary = nodes[i]
		var nearest := []
		for j in nodes.size():
			if i == j: continue
			var b: Dictionary = nodes[j]
			var delta: Vector2 = b.pos - a.pos
			var token := ("%s:%s:%d:%d" % [a.name, b.name, roundi(absf(delta.x)/32.0), roundi(delta.y/32.0)]).hash()
			nearest.append([delta.length_squared(), token])
		nearest.sort_custom(func(x,y): return x[0]<y[0] or (x[0]==y[0] and x[1]<y[1]))
		tokens.append(String(a.name).hash())
		for j in mini(nearest.size(), 4): tokens.append(nearest[j][1])
	tokens.sort()

static func _overlap(a: Array, b: Array) -> float:
	if a.is_empty() or b.is_empty(): return 1.0 if a.is_empty() and b.is_empty() else 0.0
	var i := 0
	var j := 0
	var common := 0
	while i < a.size() and j < b.size():
		if a[i] < b[j]: i += 1
		elif b[j] < a[i]: j += 1
		else:
			i += 1
			j += 1
			common += 1
	return 2.0 * common / (a.size() + b.size())

# Use one translation and handedness for the entire room. Each point may
# match at most one point of the same role, within two cells of its position
# and one 16-pixel increment of its size. Bipartite matching handles repeated
# wall segments without letting a single segment stand in for its neighbors.
static func _take_match(i: int, neighbors: Array, owners: Array, visited: Array) -> bool:
	for j: int in neighbors[i]:
		if visited[j]: continue
		visited[j] = true
		if owners[j] < 0 or _take_match(owners[j], neighbors, owners, visited):
			owners[j] = i
			return true
	return false

static func _aligned_count(a: Dictionary, b: Dictionary, facing: int, dx: float, dy: float) -> int:
	var count := 0
	for role: String in a:
		if not b.has(role): continue
		var group: Array = b[role]
		var neighbors := []
		for p: Array in a[role]:
			var nearby := []
			for j in group.size():
				var q: Array = group[j]
				if absf(p[0] * facing + dx - q[0]) <= 2 and absf(p[1] + dy - q[1]) <= 2 \
						and absf(p[2] - q[2]) <= 1 and absf(p[3] - q[3]) <= 1:
					nearby.append(j)
			neighbors.append(nearby)
		var owners := []
		owners.resize(group.size())
		owners.fill(-1)
		var visited := []
		visited.resize(group.size())
		for i in neighbors.size():
			visited.fill(false)
			if _take_match(i, neighbors, owners, visited): count += 1
	return count

static func _near_copy_score(a: Dictionary, b: Dictionary) -> float:
	var left: Dictionary = a.outlines
	var right: Dictionary = b.outlines
	var total := int(a.wall_count + a.machine_count + b.wall_count + b.machine_count)
	if total == 0: return 0.0
	var common := 0
	var anchor_role := ""
	var pairs := 10 # Bound fallback alignment work for rooms full of repeated tiles.
	for role: String in left:
		if not right.has(role): continue
		var n: int = left[role].size()
		var m: int = right[role].size()
		common += mini(n, m)
		if n * m < pairs or (n * m == pairs and role < anchor_role):
			anchor_role = role
			pairs = n * m
	var weight := 2.0 * GEOMETRY_WEIGHT / total
	# Most campaign rooms differ in composition alone. Skip the more
	# expensive spatial comparison unless it can demonstrate a near-copy.
	if common * weight < REJECT_AT: return 0.0
	var best := 0
	for facing in [1, -1]:
		best = maxi(best, _aligned_count(left, right, facing, 0, 0))
		if best == common: break
		# Adding or removing an outlying part moves the centroid. Align on a
		# shared uncommon role as a second reference for these edited copies.
		if not anchor_role.is_empty():
			for p: Array in left[anchor_role]:
				for q: Array in right[anchor_role]:
					best = maxi(best, _aligned_count(left, right, facing, q[0] - p[0] * facing, q[1] - p[1]))
					if best == common: return best * weight
	return best * weight

static func similarity(a: Dictionary, b: Dictionary) -> float:
	var walls := _overlap(a.walls, b.walls)
	var machinery := _overlap(a.machines, b.machines)
	var score := 0.55 * walls + 0.45 * machinery
	# A near-verbatim large structure still reads as a copy with different props.
	if mini(a.wall_count, b.wall_count) >= 5: score = maxf(score, walls * 0.88)
	if mini(a.machine_count, b.machine_count) >= 5: score = maxf(score, machinery * 0.84)
	if score >= GEOMETRY_WEIGHT or not a.has("outlines") or not b.has("outlines"): return score
	return maxf(score, _near_copy_score(a, b))

static func compare(candidate: Dictionary, history: Array) -> Dictionary:
	if _campaign.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(INDEX))
		if parsed is Dictionary: _campaign = parsed
	var campaign_score := -1.0
	var closest := ""
	for name: String in _campaign:
		var score := similarity(candidate, _campaign[name])
		if score > campaign_score:
			closest = name
			campaign_score = score
	var session_score := 0.0
	for other: Dictionary in history:
		session_score = maxf(session_score, similarity(candidate, other))
	return {"accepted":_campaign.size() == 100 and maxf(campaign_score, session_score) < REJECT_AT,
		"campaign_rooms_checked":_campaign.size(), "closest_campaign":closest, "campaign_score":campaign_score,
		"session_rooms_checked":history.size(), "session_score":session_score, "reject_at":REJECT_AT}
