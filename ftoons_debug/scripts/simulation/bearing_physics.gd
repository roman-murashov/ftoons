class_name BearingPhysics
extends RefCounted

## Shared DOS translation: one rolling object against static walls/inclines.
## Historical class/file name retained for the PUZ_802 reference harness.
## Tables: shared_physics.json. Arithmetic: 1000:2934/2BAC/3779/380B.
## Internal positions/velocities use DOS units (512 per pixel).
const DosPhysicsTypes = preload("res://scripts/simulation/dos_physics_types.gd")
var types := DosPhysicsTypes.new()
var data: Dictionary = {}
var cosine_table: Array = []
var atan_table: Array = []

func _init() -> void:
	data = types.data
	cosine_table = data.get("cosine_q14", [])
	atan_table = data.get("atan_octant", [])

func is_rolling(type_id: int) -> bool:
	return data.get("rolling_types", []).has(type_id)

func is_surface(type_id: int) -> bool:
	return data.get("surface_types", []).has(type_id)

func supports(puzzle: PuzzleDefinition) -> bool:
	if data.is_empty() or puzzle.construction_context != "home_toons":
		return false
	var movers := 0
	for part in puzzle.parts:
		if part.initial_flip_x() or part.initial_flip_y():
			return false
		if is_rolling(part.part_type):
			movers += 1
		elif data.incline_types.has(part.part_type):
			if part.placement_height() != 32 or not data.incline_profiles.has(str(part.placement_width())):
				return false
		elif data.wall_types.has(part.part_type):
			if part.placement_height() <= 5 or part.placement_width() <= 1:
				return false
		else:
			return false
	# No moving/moving detection is implied by recovering its response routine.
	return movers == 1

static func s16(value: int) -> int:
	return ((value + 32768) & 65535) - 32768

static func divide(a: int, b: int) -> int:
	# GDScript int/int truncates toward zero, as the original signed division.
	@warning_ignore("integer_division")
	return a / b

static func region(angle: int) -> int:
	angle &= 65535
	if angle == 0x2000:
		return 0
	if angle == 0xa000:
		return 2
	return ((angle + 0x2000) & 65535) >> 14

func cosine(angle: int) -> int:
	var index := (angle & 65535) >> 4
	if index & 2048:
		index = 4096 - index
	return int(cosine_table[index])

func sine(angle: int) -> int:
	return cosine(angle + 0xc000)

func direction(dx: int, dy: int) -> int:
	var x := absi(dx)
	var y := absi(dy)
	var angle: int
	if x < y:
		angle = 1024 - int(atan_table[divide(x << 9, y)])
	elif x > y:
		angle = int(atan_table[divide(y << 9, x)])
	else:
		angle = 1024 if x == 0 else 512
	if dx > 0:
		angle = 2048 - angle
	if dy < 0:
		angle = 4096 - angle
	return ((angle - 1024) * 16) & 65535

func rotate_velocity(x: int, y: int, angle: int) -> Vector2i:
	var c := cosine(angle)
	var s := sine(angle)
	return Vector2i(s16((x * c - y * s) >> 14), s16((x * s + y * c) >> 14))

static func intersection(p: Array, q: Array) -> Dictionary:
	var a := s16(int(p[1]) - int(p[3]))
	var b := s16(int(p[0]) - int(p[2]))
	var c := s16(int(p[2]) * a - int(p[3]) * b)
	var d := s16(int(q[3]) - int(q[1]))
	var e := s16(int(q[2]) - int(q[0]))
	var f := s16(int(q[0]) * d - int(q[1]) * e)
	var den := s16(d * b - a * e)
	var x := 0
	var y := 0
	if den != 0:
		x = s16(divide(f * b - c * e, den))
		y = s16(divide(a * f - d * c, den))
	elif s16(int(p[0]) * d + int(p[1]) * e) == 0:
		x = int(p[2])
		y = int(p[3])
	var ok := true
	for line in [p, q]:
		ok = ok and mini(int(line[0]), int(line[2])) <= x and x <= maxi(int(line[0]), int(line[2])) and mini(int(line[1]), int(line[3])) <= y and y <= maxi(int(line[1]), int(line[3]))
	return {"ok": ok, "x": x, "y": y}

static func continuation(angle: int, previous: int, old_angle: int) -> bool:
	if previous < 0 or region(angle) != region(old_angle):
		return false
	for offset in [0x2000, -0x6000]:
		var u := s16(angle + int(offset))
		var v := s16(old_angle + int(offset))
		if u >= 0 and u <= 0x4000 and v >= 0 and v <= 0x4000:
			return angle == old_angle or u == 0x2000 or v == 0x2000 or (u < 0x2000 and v < 0x2000) or (u > 0x2000 and v > 0x2000)
	return false

func shape(source: PartDefinition, sim: SimulationState.SimPart) -> Array:
	if sim.flip_x or sim.flip_y or sim.rotation != 0:
		# Generated mirrored profiles still need an independent runtime check.
		return []
	if data.incline_types.has(source.part_type):
		return data.incline_profiles[str(source.placement_width())]
	if data.wall_types.has(source.part_type):
		# 7AE2:0000: top collision edge begins five pixels below sprite origin.
		var w := source.placement_width() - 1
		var h := source.placement_height() - 1
		return [[0, 5, 0], [w, 5, 0xc000], [w, h, 0x8000], [0, h, 0x4000]]
	return data.rolling_shapes.get(str(source.part_type), [])

func detect(body: DosPhysicsTypes.ContactBody, target: Dictionary, inverse: bool, previous: int, old_angle: int) -> bool:
	var found := false
	var outer: Array = body.points if inverse else target.points
	var inner: Array = target.points if inverse else body.points
	var body_count := body.points.size() if body.point_count<0 else body.point_count
	var target_count := int(target.get("point_count",target.points.size()))
	var outer_count := body_count if inverse else target_count
	var inner_count := target_count if inverse else body_count
	# 14B1 refreshes 0C22 between detector calls, not after every vertex hit.
	var sweep_direction := direction(body.x-body.ox,body.y-body.oy)
	var cached_midpoint := int(body.x)+int(body.midpoint_x)
	if outer.is_empty() or inner.is_empty(): return false
	var first_vertex := Vector2i(int(body.x if inverse else target.x)+int(outer[0][0]),int(body.y if inverse else target.y)+int(outer[0][1]))
	var next_vertex := first_vertex
	# 17FE/1C51 initialize the first edge/vertex before their count check.
	# A retained polygon with +87=0 still visits that open first segment.
	for i in maxi(1,outer_count):
		var first: Array = outer[i]
		var second: Array = outer[(i + 1) % outer.size()]
		# The DOS edge walker carries the previous endpoint through position
		# corrections; rebuilding both endpoints moves an already-tested edge.
		var ax := next_vertex.x
		var ay := next_vertex.y
		# Count 1 is an open segment: DOS initializes the second endpoint
		# before entering the loop, and never reaches its closing-edge branch.
		next_vertex = first_vertex if i==outer_count-1 and outer_count>1 else Vector2i(int(body.x if inverse else target.x)+int(second[0]),int(body.y if inverse else target.y)+int(second[1]))
		var bx := next_vertex.x
		var by := next_vertex.y
		var angle := (int(first[2]) - 0x8000) & 65535 if inverse else int(first[2])
		var dx := int(body.x) - int(body.ox)
		var dy := int(body.y) - int(body.oy)
		if s16(sweep_direction - angle + 0x4000) <= 0:
			continue
		for j in maxi(1,inner_count):
			var k := 0 if j==inner_count-1 and inner_count>1 else j+1
			var last: Array = inner[j]
			var point: Array = inner[k]
			var diff1 := s16(int(last[2]) - int(first[2]) - 0x8000)
			var diff2 := s16(int(point[2]) - int(first[2]) - 0x8000)
			if not ((diff1 >= 0 or diff1 == -32768) and diff2 <= 0):
				continue
			dx = int(body.x) - int(body.ox)
			dy = int(body.y) - int(body.oy)
			if dx == 0 and dy == 0:
				continue
			var sx: int
			var sy: int
			var ex: int
			var ey: int
			if inverse:
				ex = int(target.x) + int(point[0]) - ax
				ey = int(target.y) + int(point[1]) - ay
				sx = ex + dx
				sy = ey + dy
			else:
				sx = int(body.ox) + int(point[0]) - ax
				sy = int(body.oy) + int(point[1]) - ay
				ex = sx + dx
				ey = sy + dy
			var q: Array = [0, 0, bx - ax, by - ay]
			q[2] += signi(int(q[2]))
			q[3] += signi(int(q[3]))
			var hit := intersection([sx, sy, ex, ey], q)
			if not hit.ok or (int(hit.x) == int(q[2]) and int(hit.y) == int(q[3])):
				continue
			var quadrant := region(angle if inverse else int(first[2]))
			var rx := int([0, -1, 0, 1][quadrant])
			var ry := int([-1, 0, 1, 0][quadrant])
			q = [-rx, -ry, int(q[2]) - rx, int(q[3]) - ry] if inverse else [rx, ry, int(q[2]) + rx, int(q[3]) + ry]
			if continuation(angle, previous, old_angle):
				var vx := int(q[2]) - int(q[0])
				var vy := int(q[3]) - int(q[1])
				if vx == 0:
					body.x = body.ox
					body.y = body.oy
				else:
					var yy := divide(vy * ex - (vy * int(q[0]) - vx * int(q[1])), vx)
					body.y += -(yy - ey) if inverse else yy - ey
			else:
				var hit2 := intersection([sx, sy, ex, ey], q)
				# 1C51:1E60..1E71 writes the shifted intersection into the same
				# stack result as the initial probe. The support-side comparison
				# at 1FC7/1FE5 reads this updated X, including a failed probe.
				# Keeping the original hit selects the wrong bounce near corners.
				hit = hit2
				if not hit2.ok:
					body.x = body.ox
					body.y = body.oy
				elif inverse:
					body.x -= int(hit2.x) - ex
					body.y -= int(hit2.y) - ey
				else:
					body.x += int(hit2.x) - ex
					body.y += int(hit2.y) - ey
			body.fx = int(body.x) * 512
			body.fy = int(body.y) * 512
			body.contact = int(target.index)
			body.angle = angle
			# 1C51 stores local_a-1: the edge BEFORE the tested target vertex.
			body.edge = j if inverse else i
			# 1000:12BC uses collision extent, not sprite/placement width.
			# 1C51:1F2A saves the preceding0C14 before12BC refreshes it.
			# 17FE classifies AFTER that refresh. Keep this asymmetry and
			# advance the cache for the next hit, not just the next walker.
			var center := (cached_midpoint if inverse else int(body.x)+int(body.midpoint_x)) - ax
			cached_midpoint=int(body.x)+int(body.midpoint_x)
			if inverse:
				if (bx < ax and int(hit.x) < center) or (bx >= ax and int(hit.x) >= center):
					body.b1 = 1
				else:
					body.b2 = 1
			elif mini(int(q[0]), int(q[2])) <= center and center <= maxi(int(q[0]), int(q[2])):
				body.b1 = 1
				body.b2 = 1
			elif (int(q[0]) < int(q[2]) and center < int(q[0])) or (int(q[0]) >= int(q[2]) and center >= int(q[2])):
				body.b2 = 1
			else:
				body.b1 = 1
			found = true
	return found

func respond(body: DosPhysicsTypes.ContactBody, acceleration: int, speed_limit: int, mover_type: int, surface_type: int, sliding_override: int = -1) -> void:
	var angle := s16(int(body.angle))
	if angle == 0 or angle == -32768:
		if int(body.b1) == 0:
			angle = s16(angle + 4096)
		elif int(body.b2) == 0:
			angle = s16(angle - 4096)
	var mover := types.descriptor(mover_type)
	var surface := types.descriptor(surface_type)
	if int(body.flags) & 1:
		var c := cosine(-angle)
		var s := sine(-angle)
		var load := (c * absi(acceleration)) >> 14
		var along := 0
		if (int(body.vx) > 0 and angle > 0) or (int(body.vx) < 0 and angle < 0):
			along = (s * int(body.vx)) >> 14
		var sliding_loss := maxi(mover.sliding_loss,surface.sliding_loss) if sliding_override < 0 else sliding_override
		var friction := absi((c * (((absi(load) + absi(along)) * sliding_loss) >> 8)) >> 14) + (32 if body.flags & 0x20 else 2)
		var drift := (absi(c) * ((s * absi(acceleration)) >> 14)) >> 14
		var v := s16(body.vx + drift)
		body.vx = mini(0, s16(v + friction)) if v < 0 else maxi(0, s16(v - friction))
		var factor := -int(body.vx) if (angle + 0x4000) & 0x8000 else int(body.vx)
		body.vy = s16((factor * s) >> 14)
	else:
		var local := rotate_velocity(int(body.vx), int(body.vy), angle)
		if mover.sliding_loss == 0:
			# Beachball (10): original explicitly bypasses multiplier and loss.
			local.y = s16(-local.y)
		else:
			local.y = s16(-s16((local.y * mini(mover.rebound_q8, surface.rebound_q8)) >> 8))
			local.y = mini(0, s16(local.y + 64)) if local.y < 0 else maxi(0, s16(local.y - 64))
		var result := rotate_velocity(local.x, local.y, -angle)
		body.vx = result.x
		body.vy = result.y
		body.fx = int(body.x) * 512 if result.x < 0 else (int(body.x) + 1) * 512 - 1
	body.vx = clampi(int(body.vx), -speed_limit, speed_limit)
	body.vy = clampi(int(body.vy), -speed_limit, speed_limit)
	body.fy = int(body.y) * 512 if acceleration < 0 else (int(body.y) + 1) * 512 - 1

func step(puzzle: PuzzleDefinition, state: SimulationState) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	var targets: Array[Dictionary] = []
	for source in puzzle.parts:
		if is_surface(source.part_type):
			var sim := state.parts[puzzle.parts.find(source)]
			var points := shape(source, sim)
			if not points.is_empty() and sim.active and sim.placed:
				targets.append({"index": sim.index, "type": sim.part_type, "x": sim.x_fixed >> 15, "y": sim.y_fixed >> 15, "points": points})
	for sim in state.parts:
		if not is_rolling(sim.part_type) or not sim.active or not sim.placed:
			continue
		if sim.rotation != 0 or sim.flip_x or sim.flip_y:
			events.append({"kind": "unsupported_transform", "part_index": sim.index})
			continue
		var environment: DosPhysicsTypes.ForceState = types.environment(sim.part_type, puzzle.pressure, puzzle.gravity)
		var acceleration: int = environment.acceleration_q9
		var speed_limit: int = environment.speed_limit_q9
		var body := DosPhysicsTypes.ContactBody.new()
		body.fx = sim.x_fixed >> 6
		body.fy = sim.y_fixed >> 6
		body.x = sim.x_fixed >> 15
		body.y = sim.y_fixed >> 15
		body.ox = body.x
		body.oy = body.y
		body.vx = s16(sim.vx_fixed >> 6)
		body.vy = s16(sim.vy_fixed >> 6)
		body.flags = sim.flags & ~15
		body.contact = sim.contact_part
		body.angle = sim.contact_angle
		body.edge = sim.contact_edge
		body.points = data.rolling_shapes[str(sim.part_type)]
		var min_x := int(body.points[0][0])
		var max_x := min_x
		for point in body.points:
			min_x = mini(min_x, int(point[0]))
			max_x = maxi(max_x, int(point[0]))
		body.midpoint_x = min_x + ((max_x - min_x) >> 1)
		var previous := sim.contact_part
		var old_angle := sim.contact_angle
		body.vy = clampi(s16(int(body.vy) + acceleration), -speed_limit, speed_limit)
		body.vx = clampi(body.vx, -speed_limit, speed_limit)
		body.fx += int(body.vx)
		body.fy += int(body.vy) + ((-1024 if acceleration <= 0 else 1024) if sim.flags & 1 else 0)
		body.x = int(body.fx) >> 9
		body.y = int(body.fy) >> 9
		var order: Array[Dictionary] = []
		for target in targets:
			if int(target.index) == previous:
				order.append(target)
		for target in targets:
			if int(target.index) != previous:
				order.append(target)
		var hit := false
		for target in order:
			hit = detect(body, target, false, previous, old_angle) or hit
			hit = detect(body, target, true, previous, old_angle) or hit
		if hit:
			body.flags |= 2 | int(continuation(int(body.angle), previous, old_angle))
			# Resident 1000:229E: the TARGET callback receives the mover,
			# and its return value gates the generic response. None of this
			# slice's ten rolling types takes the earlier special mover route.
			if not (sim.flags & 8) and not (sim.flags08 & 0x2000):
				var target_type: int = state.parts[body.contact].part_type
				if target_contact_callback(body, sim, target_type):
					respond(body, acceleration, speed_limit, sim.part_type, target_type)
			events.append({"kind": "contact", "part_index": sim.index, "other": int(body.contact), "angle": int(body.angle), "edge": int(body.edge), "vx_dos": int(body.vx), "vy_dos": int(body.vy)})
		else:
			body.contact = -1
		sim.flags = (sim.flags & ~15) | int(body.flags)
		sim.x_fixed = int(body.fx) << 6
		sim.y_fixed = int(body.fy) << 6
		sim.vx_fixed = int(body.vx) << 6
		sim.vy_fixed = int(body.vy) << 6
		sim.contact_part = int(body.contact)
		sim.contact_angle = int(body.angle)
		sim.contact_edge = int(body.edge)
		sim.contact_status_8f = int(body.b1)
		sim.contact_status_90 = int(body.b2)
		if int(body.x) < -1000 or int(body.x) > 2000 or int(body.y) < -1000 or int(body.y) > 2000:
			sim.active = false
	return events

func target_contact_callback(body: DosPhysicsTypes.ContactBody, mover: SimulationState.SimPart, target_type: int) -> bool:
	# All six incline callbacks return 1. All six wall materials share the
	# recovered 7AE2:011C callback, which can activate the moving ball's state.
	if data.wall_types.has(target_type) and mover.part_type in [8, 9]:
		var reaction := 0
		if body.edge in [0, 2] and (body.vy < -4096 or body.vy > 4096):
			reaction = 1
		elif body.vx < -4096 or body.vx > 4096:
			reaction = 2
		if reaction != 0:
			mover.trigger_state = reaction
			mover.reaction_state = reaction
	return is_surface(target_type)
