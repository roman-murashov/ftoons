extends RefCounted

## Editor transforms use the displayed top-left anchor, flip in local axes,
## then rotate. Keep drawing, collision vertices and broad-phase bounds equal.
static func display_size(size: Vector2i, turns: int) -> Vector2i:
	return Vector2i(size.y,size.x) if posmod(turns,2)==1 else size

static func point(value: Vector2i, size: Vector2i, turns: int, flip_x: bool=false, flip_y: bool=false) -> Vector2i:
	var p:=Vector2i(size.x-value.x if flip_x else value.x,size.y-value.y if flip_y else value.y)
	match posmod(turns,4):
		1: return Vector2i(size.y-p.y,p.x)
		2: return Vector2i(size.x-p.x,size.y-p.y)
		3: return Vector2i(p.y,size.x-p.x)
	return p

static func rect(value: Rect2i, size: Vector2i, turns: int, flip_x: bool=false, flip_y: bool=false) -> Rect2i:
	var a:=point(value.position,size,turns,flip_x,flip_y)
	var b:=point(value.end,size,turns,flip_x,flip_y)
	return Rect2i(Vector2i(mini(a.x,b.x),mini(a.y,b.y)),Vector2i(absi(b.x-a.x),absi(b.y-a.y)))

static func affine(size: Vector2i, turns: int, flip_x: bool=false, flip_y: bool=false) -> Transform2D:
	var origin:=Vector2(point(Vector2i.ZERO,size,turns,flip_x,flip_y))
	return Transform2D(Vector2(point(Vector2i.RIGHT,size,turns,flip_x,flip_y))-origin,
		Vector2(point(Vector2i.DOWN,size,turns,flip_x,flip_y))-origin,origin)
