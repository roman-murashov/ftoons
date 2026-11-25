class_name PuzzleCanvas
extends Control

signal part_selected(index: int)
signal board_clicked(position: Vector2i)
signal board_hovered(position: Vector2i)
var grab_active: bool = false
var editing_enabled: bool = true
var show_selection: bool = true
var native_screen := false
var last_pointer := Vector2i.ZERO
var rope_editor: RopeEditor
var belt_editor: RefCounted
signal belt_endpoint_selected(owner: int, side: int)
signal rope_endpoint_selected(owner: int, side: int)
signal graphics_status_changed(message: String)

const FIXED_SHIFT := 15
const RopeEditor = preload("res://scripts/simulation/rope_editor.gd")
# Preserve the 648-pixel-wide board measured in the original 960x600 layout.
# A larger application window adds room without automatically enlarging sprites.
const BOARD_ZOOM := 648.0 / 552.0
const DynamixFormats = preload("res://scripts/graphics/dynamix_formats.gd")
const PartOverlayLayout = preload("res://scripts/graphics/part_overlay_layout.gd")
const PartRenderLayout = preload("res://scripts/graphics/part_render_layout.gd")
const PartTransform = preload("res://scripts/simulation/part_transform.gd")
const SpriteGraphicsPack = preload("res://scripts/graphics/sprite_graphics_pack.gd")

var catalog: ResourceCatalog
var puzzle: PuzzleDefinition
var runtime_state: SimulationState
var selected_index: int = -1
var graphics_enabled: bool = true
var palette: Array = []
var sprite_textures: Dictionary = {}
var sprite_frame_textures: Dictionary = {}
var sprite_errors: Dictionary = {}
var bmp_results: Dictionary = {}
var overlay_layout := PartOverlayLayout.new()
var render_layout := PartRenderLayout.new()
var reaction_tables := ReactionTables.new()
var sprite_graphics: SpriteGraphicsPack
var message_text: MessageMachineText

func _init(resource_catalog: ResourceCatalog, graphics: SpriteGraphicsPack = null) -> void:
	catalog = resource_catalog
	sprite_graphics = graphics if graphics != null else SpriteGraphicsPack.new(catalog)
	palette = sprite_graphics.palette
	sprite_graphics.changed.connect(queue_redraw)
	message_text=MessageMachineText.new(catalog,palette)

func set_puzzle(value: PuzzleDefinition) -> void:
	puzzle = value
	runtime_state = null
	selected_index = -1
	_load_puzzle_sprites()
	queue_redraw()
	graphics_status_changed.emit(get_graphics_status())

func set_runtime(value: SimulationState) -> void:
	runtime_state = value
	if runtime_state != null and graphics_enabled:
		for sim in runtime_state.parts:
			if sim.active and sim.placed:
				_runtime_frames(sim.definition,sim)
	queue_redraw()

func _part_count() -> int:
	return runtime_state.parts.size() if runtime_state != null else puzzle.parts.size()

func _source(index: int) -> PartDefinition:
	if runtime_state != null and runtime_state.parts[index].definition != null:
		return runtime_state.parts[index].definition
	return puzzle.parts[index]

func _runtime_frames(source: PartDefinition, sim: SimulationState.SimPart) -> Array:
	if source == null or palette.is_empty(): return []
	var resource_name: String = ""
	if source.part_type in [36,37]:
		resource_name = reaction_tables.sheet(source.part_type,sim.state if sim != null else 0)
	if resource_name.is_empty():
		resource_name = "PART%d.BMP" % source.part_type
	return sprite_graphics.frames(resource_name)

func set_graphics_enabled(enabled: bool) -> void:
	graphics_enabled = enabled
	queue_redraw()
	graphics_status_changed.emit(get_graphics_status())

func get_graphics_status() -> String:
	if not graphics_enabled:
		return "Original graphics hidden; logical part outlines are shown."
	if palette.is_empty():
		return "Graphics unavailable: GAME.PAL could not be decoded."
	if puzzle == null:
		return "No puzzle selected."
	var total := 0
	var loaded := 0
	for index in puzzle.parts.size():
		var key := _sprite_key_for(puzzle.parts[index])
		if sprite_textures.has(key):
			loaded += 1
		total += 1
	return "Original part graphics: %d/%d records; native sprites, component layouts, wall caps and connectors enabled." % [loaded, total]

func _board_scale() -> float:
	if native_screen: return 1.0
	return minf(BOARD_ZOOM, minf(size.x / 552.0, size.y / 400.0))

func _draw() -> void:
	draw_rect(Rect2(0, 0, size.x, size.y), Color.WHITE if native_screen else Color("10151c"), true)
	if puzzle == null:
		return
	var scale := _board_scale()
	var origin := Vector2(3,8) if native_screen else Vector2((size.x - 552.0 * scale) * 0.5, (size.y - 400.0 * scale) * 0.5)
	draw_rect(Rect2(origin, Vector2(552.0, 400.0) * scale), Color.WHITE, true)
	var bodies: Array[Dictionary] = []
	for index in _part_count():
		var source: PartDefinition = _source(index)
		var sim: SimulationState.SimPart = runtime_state.parts[index] if runtime_state != null and index < runtime_state.parts.size() else null
		if source.part_type in [1,14,76]: continue
		if sim != null and not sim.active:
			continue
		if source.is_in_parts_bin() and (sim == null or not sim.placed):
			continue
		var logical_rect := _runtime_rect(source, sim) if sim != null else source.rect()
		var frames: Array = _runtime_frames(source,sim)
		if graphics_enabled and not frames.is_empty():
			for command in render_layout.body_commands(source, Vector2(_part_size(source,sim)), sim.appearance if sim != null else -1,sim.settings if sim != null else source.wire_terminal):
				bodies.append({"index": index, "rect": logical_rect, "source": source, "sim": sim, "frames": frames, "command": command})
		else:
			var color := Color("cf9b4b") if source.is_moving() else Color("8f6868")
			draw_rect(Rect2(origin + logical_rect.position * scale, logical_rect.size * scale), color, false, 1.0)
	# DOS registers each object's layers by prepending to a list; layers are
	# painted 5..0, with the connectors after the bodies in their layer.
	for layer in range(5, -1, -1):
		for index in range(_part_count() - 1, -1, -1):
			for body in bodies:
				if body.index == index and int(body.command.layer) == layer:
					_draw_body_command(body, origin, scale)
		if graphics_enabled and layer == 5:
			_draw_wall_joints(origin, scale)
	_draw_ropes(origin,scale)
	_draw_belts(origin,scale)
	# Diagnostics stay above the scene but do not cover the art by default.
	for index in _part_count():
		var source: PartDefinition = _source(index)
		var sim: SimulationState.SimPart = runtime_state.parts[index] if runtime_state != null and index < runtime_state.parts.size() else null
		if source.part_type in [1,14,76]: continue
		if sim != null and not sim.active:
			continue
		if source.is_in_parts_bin() and (sim == null or not sim.placed):
			continue
		var logical_rect := _runtime_rect(source, sim) if sim != null else source.rect()
		var rect := Rect2(origin + logical_rect.position * scale, logical_rect.size * scale)
		if show_selection and index == selected_index:
			draw_rect(rect, Color("fff18a"), false, 2.0)
		if not graphics_enabled and scale >= 0.75:
			draw_string(ThemeDB.fallback_font, rect.position + Vector2(2, 12), "%d:%d" % [index, source.part_type], HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color("e9edf0"))

func _draw_body_command(body: Dictionary, origin: Vector2, board_scale: float) -> void:
	var frame_index := int(body.command.frame)
	var frames: Array = body.frames
	var rect: Rect2 = body.rect
	var texture: Texture2D
	var position_in_part: Vector2 = body.command.position
	if body.command.get("kind","")=="message_letter":
		var glyph:=message_text.resolve(int(body.command.character),Vector2i(rect.position))
		if glyph.is_empty(): return
		texture=glyph.texture
		position_in_part=glyph.position
	else:
		if frame_index < 0 or frame_index >= frames.size(): return
		texture=frames[frame_index]
	var sim: SimulationState.SimPart = body.sim
	var source: PartDefinition = body.source
	var turns := sim.rotation if sim != null else 0
	var flip_x := sim.flip_x if sim != null else source.initial_flip_x()
	var flip_y := sim.flip_y if sim != null else source.initial_flip_y()
	# The original tiler calls the sprite routine with mask zero. Native
	# tile sizes may be smaller than 16px (e.g. the bone roof's middles).
	if body.command.tiled or body.command.get("unmirrored", false):
		flip_x = sim.editor_mirror_x if sim != null else false
		flip_y = sim.editor_mirror_y if sim != null else false
	var board_transform:=Transform2D(Vector2(board_scale,0),Vector2(0,board_scale),origin+rect.position*board_scale)
	draw_set_transform_matrix(board_transform*PartTransform.affine(_part_size(source,sim),turns,flip_x,flip_y))
	draw_texture_rect(texture, Rect2(position_in_part, texture.get_size()), false, Color.WHITE)
	draw_set_transform(Vector2.ZERO)

func _draw_wall_joints(origin: Vector2, board_scale: float) -> void:
	if puzzle == null:
		return
	# 198D:3307 accepts only the six registered wall families as neighbors.
	var elements: Array[Rect2] = []
	for index in _part_count():
		var source: PartDefinition = _source(index)
		if not overlay_layout.supports(source.part_type):
			continue
		var sim: SimulationState.SimPart = runtime_state.parts[index] if runtime_state != null and index < runtime_state.parts.size() else null
		if source.part_type in [1,14,76]: continue
		if sim != null and not sim.active: continue
		if source.is_in_parts_bin() and (sim == null or not sim.placed):
			continue
		elements.append(_runtime_rect(source, sim) if sim != null else source.rect())
	for index in range(_part_count() - 1, -1, -1):
		var source: PartDefinition = _source(index)
		if not overlay_layout.supports(source.part_type):
			continue
		var sim: SimulationState.SimPart = runtime_state.parts[index] if runtime_state != null and index < runtime_state.parts.size() else null
		if source.part_type in [1,14,76]: continue
		if sim != null and not sim.active: continue
		if source.is_in_parts_bin() and (sim == null or not sim.placed):
			continue
		var rect := _runtime_rect(source, sim) if sim != null else source.rect()
		var codes := _bone_neighbor_codes(rect, elements)
		var frames: Array = sprite_frame_textures.get(source.part_type, [])
		for command in overlay_layout.draw_commands(source.part_type, rect, codes):
			var frame_index := int(command.frame)
			if frame_index >= 0 and frame_index < frames.size():
				_draw_bone_overlay(frames[frame_index], origin, board_scale, command.position)

func _bone_neighbor_codes(rect: Rect2, elements: Array[Rect2]) -> Vector2i:
	var first := 0
	var second := 0
	if is_equal_approx(rect.size.x, 16.0):
		# Vertical member: inspect one 16-pixel strip above and below it.
		for candidate in elements:
			if not is_equal_approx(candidate.size.y, 16.0):
				continue
			var overlaps_x := candidate.position.x < rect.end.x and candidate.end.x > rect.position.x
			if first == 0 and is_equal_approx(candidate.end.y, rect.position.y) and overlaps_x:
				if is_equal_approx(candidate.position.x, rect.position.x):
					first = 7
				elif is_equal_approx(candidate.end.x, rect.end.x):
					first = 9
				else:
					first = 8
			if second == 0 and is_equal_approx(candidate.position.y, rect.end.y) and overlaps_x:
				if is_equal_approx(candidate.position.x, rect.position.x):
					second = 10
				elif is_equal_approx(candidate.end.x, rect.end.x):
					second = 12
				else:
					second = 11
	elif is_equal_approx(rect.size.y, 16.0):
		# Horizontal member: inspect one 16-pixel strip on either side.
		for candidate in elements:
			if not is_equal_approx(candidate.size.x, 16.0):
				continue
			var overlaps_y := candidate.position.y < rect.end.y and candidate.end.y > rect.position.y
			if first == 0 and is_equal_approx(candidate.end.x, rect.position.x) and overlaps_y:
				if is_equal_approx(candidate.position.y, rect.position.y):
					first = 1
				elif is_equal_approx(candidate.end.y, rect.end.y):
					first = 5
				else:
					first = 3
			if second == 0 and is_equal_approx(candidate.position.x, rect.end.x) and overlaps_y:
				if is_equal_approx(candidate.position.y, rect.position.y):
					second = 2
				elif is_equal_approx(candidate.end.y, rect.end.y):
					second = 6
				else:
					second = 4
	return Vector2i(first, second)

func _draw_bone_overlay(texture: Texture2D, origin: Vector2, board_scale: float, logical_top_left: Vector2) -> void:
	if texture == null:
		return
	var texture_size := texture.get_size()
	var top_left := origin + logical_top_left * board_scale
	draw_texture_rect(texture, Rect2(top_left, texture_size * board_scale), false, Color.WHITE)

func _load_puzzle_sprites() -> void:
	sprite_textures.clear()
	sprite_frame_textures.clear()
	sprite_errors.clear()
	bmp_results.clear()
	if puzzle == null or palette.is_empty():
		return
	for source in puzzle.parts:
		var key := _sprite_key_for(source)
		if sprite_textures.has(key) or sprite_errors.has(key):
			continue
		var decoded := _bmp_result(source.part_type)
		if not decoded.get("ok", false):
			sprite_errors[key] = String(decoded.get("error", "BMP decode failed"))
			continue
		var frames: Array = decoded.get("frames", [])
		var frame_index := _frame_index(source.appearance, frames.size())
		if frames.is_empty() or frame_index < 0 or frame_index >= frames.size():
			sprite_errors[key] = "no decoded frame"
			continue
		var textures := sprite_graphics.frames(_part_sheet(source.part_type), decoded)
		sprite_frame_textures[source.part_type] = textures
		sprite_textures[key] = textures[frame_index]

func _sprite_key_for(source: PartDefinition) -> String:
	return "%d:%d" % [source.part_type, _frame_index(source.appearance, _frame_count(source.part_type))]

func _frame_count(part_type: int) -> int:
	var decoded := _bmp_result(part_type)
	return decoded.get("frames", []).size() if decoded.get("ok", false) else 0

func _part_sheet(part_type: int) -> String:
	# Actor state zero selects the root sheet in 22F3:714F, rather than PART36/37.
	return {36: "CATROOT.BMP", 37: "SIDROOT.BMP"}.get(part_type, "PART%d.BMP" % part_type)

func _bmp_result(part_type: int) -> Dictionary:
	var resource_name := _part_sheet(part_type)
	if bmp_results.has(resource_name):
		return bmp_results[resource_name]
	var bytes := catalog.read_asset(resource_name)
	if bytes.is_empty():
		var missing := {"ok": false, "error": "missing %s" % resource_name}
		bmp_results[resource_name] = missing
		return missing
	var decoded: Dictionary = DynamixFormats.decode_bmp(bytes)
	bmp_results[resource_name] = decoded
	return decoded

func _frame_index(appearance: int, frame_count: int) -> int:
	if frame_count <= 0:
		return 0
	if appearance >= 0 and appearance < frame_count:
		return appearance
	var high_nibble := (appearance >> 12) & 0x0f
	if high_nibble < frame_count:
		return high_nibble
	return 0

static func _part_size(source: PartDefinition, sim: SimulationState.SimPart) -> Vector2i:
	return Vector2i(sim.width if sim!=null and sim.width>0 else source.placement_width(),sim.height if sim!=null and sim.height>0 else source.placement_height())

func _runtime_rect(source: PartDefinition, sim: SimulationState.SimPart) -> Rect2:
	return Rect2(Vector2(sim.x_fixed >> FIXED_SHIFT,sim.y_fixed >> FIXED_SHIFT),Vector2(PartTransform.display_size(_part_size(source,sim),sim.rotation)))

func _construction_hit_rect(source: PartDefinition, sim: SimulationState.SimPart) -> Rect2:
	if native_screen and sim!=null:
		# Native tool/pick bounds are +45/+47 and +4D/+4F, not the logical
		# +41/+43 rectangle. Flips can move the frame relative to its anchor.
		return Rect2(Vector2(sim.x_fixed >> FIXED_SHIFT,sim.y_fixed >> FIXED_SHIFT)+Vector2(sim.frame_offset),Vector2(sim.frame_size))
	return _runtime_rect(source,sim) if sim!=null else source.rect()

func _gui_input(event: InputEvent) -> void:
	if not editing_enabled or puzzle == null or (runtime_state != null and runtime_state.running):
		return
	if not event is InputEventMouseButton and not event is InputEventMouseMotion:
		return
	var mouse: Vector2 = event.position
	var scale := _board_scale()
	if scale <= 0.0:
		return
	var origin := Vector2(3,8) if native_screen else Vector2((size.x - 552.0 * scale) * 0.5, (size.y - 400.0 * scale) * 0.5)
	var logical: Vector2 = (mouse - origin) / scale
	var position := Vector2i(floori(logical.x), floori(logical.y))
	last_pointer=position
	if event is InputEventMouseMotion:
		if grab_active: board_hovered.emit(position)
		return
	if not event.pressed: return
	if event.button_index == MOUSE_BUTTON_LEFT:
		if not Rect2(Vector2.ZERO,Vector2(552,400)).has_point(logical): return
		if grab_active:
			board_clicked.emit(position)
			accept_event()
			return
		if runtime_state!=null:
			for belt in runtime_state.belts:
				for side in 2:
					var p:=runtime_state.parts[belt.ends[side]]
					var anchor:=preload("res://scripts/simulation/belt_connections.gd").anchor(p)
					var distance: int=p.definition.belt_line_distance
					if Rect2i(anchor,Vector2i(maxi(distance,8),maxi(distance,8))).has_point(position):
						belt_endpoint_selected.emit(belt.owner,side)
						accept_event()
						return
			for rope in runtime_state.ropes:
				for side in 2:
					var id: int=rope.route[0] if side==0 else rope.route.back()
					if runtime_state.parts[id].part_type in [17,76]: continue
					var knot:=RopePhysics.point(runtime_state,id,int(rope.slots[side]))
					if Rect2i(knot-Vector2i(9,9),Vector2i(18,18)).has_point(position):
						rope_endpoint_selected.emit(int(rope.owner),side)
						accept_event()
						return
		for index in range(puzzle.parts.size() - 1, -1, -1):
			var source: PartDefinition = puzzle.parts[index]
			var sim: SimulationState.SimPart = runtime_state.parts[index] if runtime_state != null and index < runtime_state.parts.size() else null
			if source.part_type in [1,14,76]: continue
			if sim != null and not sim.active:
				continue
			if source.is_in_parts_bin() and (sim == null or not sim.placed):
				continue
			var rect := _construction_hit_rect(source,sim)
			if rect.has_point(logical):
				selected_index = index
				part_selected.emit(index)
				queue_redraw()
				accept_event()
				return
		board_clicked.emit(position)
		accept_event()

func _draw_belts(origin: Vector2, board_scale: float) -> void:
	if runtime_state == null: return
	for belt in runtime_state.belts:
		if not preload("res://scripts/simulation/belt_editor.gd").within(runtime_state.parts[belt.ends[0]],runtime_state.parts[belt.ends[1]]): continue
		for segment in preload("res://scripts/simulation/belt_connections.gd").segments(runtime_state,belt):
			draw_line(origin+Vector2(segment.a)*board_scale,origin+Vector2(segment.b)*board_scale,Color.BLACK,board_scale,false)

	if belt_editor!=null and belt_editor.active() and belt_editor.start>=0:
		var a:=preload("res://scripts/simulation/belt_connections.gd").anchor(runtime_state.parts[belt_editor.start])
		var color: Color=palette[10 if belt_editor.candidate.get("ok",false) else 12] if not palette.is_empty() else Color.MAGENTA
		draw_line(origin+Vector2(a)*board_scale,origin+Vector2(belt_editor.cursor)*board_scale,color,board_scale,false)

func _draw_ropes(origin: Vector2, board_scale: float) -> void:
	if runtime_state==null: return
	for rope in runtime_state.ropes:
		for segment in RopePhysics.segments(runtime_state,rope):
			var a:=Vector2(segment.a)
			var b:=Vector2(segment.b)
			var points:=PackedVector2Array()
			if segment.slack<5:
				points.append(a)
				points.append(b)
			else:
				var control: Vector2=(a+b)*0.5+Vector2(0,segment.slack)
				for i in 17:
					var t:=float(i)/16.0
					points.append((1-t)*(1-t)*a+2*(1-t)*t*control+t*t*b)
			for stroke in [-1,1,0]:
				var offset:=Vector2(stroke,0) if absf(b.y-a.y)>absf(b.x-a.x) else Vector2(0,stroke)
				var projected:=PackedVector2Array()
				for v in points: projected.append(origin+(v+offset)*board_scale)
				var color: Color=palette[2 if stroke==-1 else (7 if stroke==1 else 14)] if not palette.is_empty() else Color.YELLOW
				draw_polyline(projected,color,board_scale,false)
		if not graphics_enabled: continue
		var owner: SimulationState.SimPart=runtime_state.parts[int(rope.owner)]
		var frames:=_runtime_frames(owner.definition,owner)
		if frames.is_empty(): continue
		for side in 2:
			var end: int=rope.route[0] if side==0 else rope.route.back()
			if runtime_state.parts[end].part_type in [17,76]: continue
			var pos:=RopePhysics.point(runtime_state,end,int(rope.slots[side]))-Vector2i(9,9)
			draw_texture_rect(frames[0],Rect2(origin+Vector2(pos)*board_scale,frames[0].get_size()*board_scale),false)

	_draw_editing_rope(origin,board_scale)

func _draw_editing_rope(origin: Vector2, board_scale: float) -> void:
	if rope_editor==null or not rope_editor.active() or rope_editor.route.is_empty(): return
	var route: Array=rope_editor.route
	for i in route.size()-1:
		var a:=RopePhysics.point(runtime_state,int(route[i]),int(rope_editor.slots[0]) if i==0 else 1)
		var b:=RopePhysics.point(runtime_state,int(route[i+1]),0)
		_draw_editing_segment(a,b,origin,board_scale,14)
	var last:=RopePhysics.point(runtime_state,int(route.back()),int(rope_editor.slots[0]) if route.size()==1 else 1)
	_draw_editing_segment(last,rope_editor.cursor,origin,board_scale,10 if rope_editor.candidate.get("ok",false) else 12)
	var owner:=runtime_state.parts[rope_editor.owner]
	var frames:=_runtime_frames(owner.definition,owner)
	if graphics_enabled and not frames.is_empty():
		var anchor:=RopePhysics.point(runtime_state,int(route[0]),int(rope_editor.slots[0]))-Vector2i(9,9)
		draw_texture_rect(frames[0],Rect2(origin+Vector2(anchor)*board_scale,frames[0].get_size()*board_scale),false)

func _draw_editing_segment(a: Vector2i,b: Vector2i,origin: Vector2,board_scale: float,color_index: int) -> void:
	for stroke in [-1,1,0]:
		var offset:=Vector2(stroke,0) if absi(b.y-a.y)>absi(b.x-a.x) else Vector2(0,stroke)
		var color: Color=palette[2 if stroke==-1 else (7 if stroke==1 else color_index)] if not palette.is_empty() else Color.YELLOW
		draw_line(origin+(Vector2(a)+offset)*board_scale,origin+(Vector2(b)+offset)*board_scale,color,board_scale)
