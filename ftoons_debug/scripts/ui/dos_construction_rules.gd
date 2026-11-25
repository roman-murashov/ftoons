extends RefCounted
## Construction queries only; never dispatch simulation collision reactions.
const K = preload("res://scripts/simulation/bearing_physics.gd")

static func drag_position(pointer: Vector2i, anchor: Vector2i, pixel: bool) -> Vector2i:
	var screen := pointer + Vector2i(91,8) - anchor
	if not pixel: screen = Vector2i(screen.x & ~15, screen.y & ~15)
	return screen - Vector2i(91,8)

static func frame(runner: SimulationRunner, p: SimulationState.SimPart) -> Rect2i:
	var bounds := runner.world_physics.frame_geometry(p)
	return Rect2i(RopePhysics.xy(p) + bounds.position, bounds.size)

static func edges(runner: SimulationRunner, p: SimulationState.SimPart) -> Array:
	var shape := runner.world_physics.collider(p.definition,p)
	var points: Array = shape.points
	var count := int(shape.point_count)
	var result: Array = []
	var origin := RopePhysics.xy(p)
	for i in mini(count,points.size()):
		var j := (i+1)%points.size() if count==1 else (i+1)%count
		result.append([origin.x+int(points[i][0]),origin.y+int(points[i][1]),origin.x+int(points[j][0]),origin.y+int(points[j][1])])
	return result

static func contains_point(outline: Array, point: Vector2i) -> bool:
	# Closed-outline containment; open Switch edges cannot enclose a center.
	if outline.size()<3: return false
	var inside := false
	for e in outline:
		if (e[1]>point.y)!=(e[3]>point.y):
			if float(point.x)<float(e[2]-e[0])*float(point.y-e[1])/float(e[3]-e[1])+float(e[0]): inside=not inside
	return inside

static func blocked(runner: SimulationRunner, index: int) -> bool:
	var p := runner.state.parts[index]
	if p.part_type in [1,14,76]: return false
	var rect := frame(runner,p)
	var own := edges(runner,p)
	for other in runner.state.parts:
		if other.index==index or not other.active or not other.placed or other.part_type in [1,14,76] or other.flags08&0x2000: continue
		var other_rect := frame(runner,other)
		if not rect.intersects(other_rect): continue
		var target := edges(runner,other)
		for a in own:
			for b in target:
				# 3D75 translates both edges to the first edge origin before3990.
				var hit := K.intersection([0,0,a[2]-a[0],a[3]-a[1]],[b[0]-a[0],b[1]-a[1],b[2]-a[0],b[3]-a[1]])
				if hit.ok and (hit.x!=a[2]-a[0] or hit.y!=a[3]-a[1]): return true
		if contains_point(target,rect.get_center()) or contains_point(own,other_rect.get_center()): return true
	return false
