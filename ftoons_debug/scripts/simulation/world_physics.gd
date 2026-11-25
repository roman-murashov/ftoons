class_name WorldPhysics
extends RefCounted

## All-puzzle mechanics preview. Original tables/arithmetic are reused;
## shared scheduling follows 20F2; incomplete mechanism protocols are reported.
const Kernel = preload("res://scripts/simulation/bearing_physics.gd")
const Types = preload("res://scripts/simulation/dos_physics_types.gd")
const Reactions = preload("res://scripts/simulation/special_reactions.gd")
const PartTransform = preload("res://scripts/simulation/part_transform.gd")
var kernel := Kernel.new()
var reactions := Reactions.new()
var data: Dictionary = {}
var shape_cache: Dictionary = {}
var trace_geometry: bool = false
# Optional recorded external-driver inputs for native reference comparisons.
# Normal gameplay uses SimulationState.audio; no RNG values are overridden.
var reference_audio_query: Callable
var reference_audio_clock: Callable

func _init() -> void:
	var file := FileAccess.open("res://assets/original/world_physics.json", FileAccess.READ)
	if file != null:
		var parsed = JSON.parse_string(file.get_as_text())
		if parsed is Dictionary:
			data = parsed

func available() -> bool:
	return not data.is_empty() and not kernel.data.is_empty()

func reaction_status(type_id: int) -> String:
	var binding: Dictionary = data.callback_bindings.get(str(type_id),{}).get("0x120",{})
	if String(binding.get("category","")) == "direct_far_return_constant_1":
		return "original return-1 handler"
	if kernel.is_surface(type_id):
		return "original shared wall handler"
	return "native recovered contact reaction: " + String(binding.get("target","unknown"))

func initialize(puzzle: PuzzleDefinition,state: SimulationState) -> void:
	reactions.initialize(puzzle,state,self)

func initialize_geometry(p: SimulationState.SimPart) -> void:
	var meta: Dictionary=data.geometry.get(str(p.part_type),{})
	# Pulley: loader5142 writes serialized sprite sizes to +4D/+4F only.
	# 6212:6275 then selects25x25 and fills the initially zero +41/+43.
	# Rope direction sprites24x25/32x23 must not become logical dimensions.
	if p.part_type==17:
		p.width=25
		p.height=25
	# Bik Dragon: 298D:5142 loads serialized dimensions into +4D/+4F,
	# not logical +41/+43. 1000:6212 derives the latter from its frame table.
	# Resolve before mirroring: retaining CAKE4's saved width31 shifts the
	# flipped frame by -1 although the constructed DOS width is32.
	if p.part_type==35:
		var sizes: Array=meta.get("frame_sizes",[])
		if sizes.is_empty(): sizes=meta.get("sprite_frame_sizes",[])
		if p.appearance>=0 and p.appearance<sizes.size():
			p.width=int(sizes[p.appearance][0])
			p.height=int(sizes[p.appearance][1])
	var extent: Array=meta.get("factory_extent",[p.width,p.height])
	p.stored_extent=Vector2i(int(extent[0]),int(extent[1]))
	p.collision_weight=kernel.types.descriptor(p.part_type).collision_weight
	resize_geometry(p)
	if p.part_type==38: refresh_timer(p)
	frame_geometry(p)
	p.previous_frame_size=p.frame_size
	p.older_frame_size=p.frame_size

func resize_geometry(p: SimulationState.SimPart) -> void:
	# Dimension constructors consume saved/editor extents. Ordinary animated
	# parts retain their factory +59/+5B even when logical/frame sizes differ.
	if kernel.data.incline_types.has(p.part_type):
		# 7AFA:0078 retains +59/+5B and derives a separate sprite extent.
		if p.reaction_data.has("construction_extent"):
			# 7AFA:0078 selects frame (width >> 4)-1 after a resize.
			p.appearance=(p.width >> 4)-1
			p.previous_appearance=p.appearance
		var stored_height:=p.definition.height_2 if p.definition!=null and p.definition.height_2>0 else 16
		if p.definition!=null and p.definition.construction_context=="campaign" and p.definition.is_in_parts_bin():
			# Campaign5F19 calls4704:4735 before7AFA:0078. Preserve its
			# factory+5B through placement/width changes, not the old saved16.
			var factory_extent: Array=data.geometry.get(str(p.part_type),{}).get("factory_extent",[])
			if factory_extent.size()==2: stored_height=int(factory_extent[1])
		p.stored_extent=Vector2i(p.width,stored_height)
	elif kernel.is_surface(p.part_type) and p.reaction_data.has("wall_frame_extent"):
		# 7887:027B trims +4D/+4F, retaining constructor +59/+5B.
		# Support tests still read the latter; do not collapse the two sizes.
		pass
	elif kernel.is_surface(p.part_type) or p.part_type in [0,45]:
		p.stored_extent=Vector2i(p.width,p.height)
	if p.part_type==40:
		p.constructed_sections=(p.settings&0xf0)>>4
		if p.settings==0:
			p.constructed_sections=clampi(Kernel.divide(p.height-26,65),0,5)
			p.settings=p.constructed_sections<<4
		p.constructed_flip_x=p.flip_x
		p.stored_extent=Vector2i(102,26+65*p.constructed_sections)

static func refresh_timer(p: SimulationState.SimPart) -> void:
	if p.settings&255:
		p.appearance=12-2*(p.settings&255)+int((p.settings&0xf000)!=0)

func native_mirror_flags(p: SimulationState.SimPart) -> int:
	if p.part_type==40: return 1 # Thumpulator constructor mirrors its pieces.
	if p.part_type==63: return 2 if p.appearance==0 else 1
	return int(data.geometry.get(str(p.part_type),{}).get("mirror_flags",0))

func frame_geometry(p: SimulationState.SimPart) -> Rect2i:
	RopePhysics.refresh_anchors(p,reactions.tables)
	var appearance:=int(p.reaction_data.get("constructed_appearance",p.appearance)) if p.part_type==78 else p.appearance
	# 6212, followed by the Thumpulator constructor override. This is shared
	# by broad phase, field/sight queries, support classification and centers.
	if p.stored_extent.x<0:
		var extent: Array=data.geometry.get(str(p.part_type),{}).get("factory_extent",[p.width,p.height])
		p.stored_extent=Vector2i(int(extent[0]),int(extent[1]))
		resize_geometry(p)
	var meta: Dictionary=data.geometry.get(str(p.part_type),{})
	var native_flip_x:=p.flip_x!=p.editor_mirror_x
	var native_flip_y:=p.flip_y!=p.editor_mirror_y
	p.frame_offset=Vector2i.ZERO
	p.polygon_translation=Vector2i.ZERO
	p.frame_size=Vector2i.ZERO
	if p.part_type not in [1,14,76]:
		if p.flags&0x40 or p.part_type in [0,40]:
			p.frame_size=p.reaction_data.get("wall_frame_extent",p.stored_extent)
		elif p.part_type==17:
			p.frame_size=Vector2i(25,25)
		elif p.part_type==18:
			# 7939:0347 changes only the Gear's frame; it does not call6212.
			# Runtime sprite/contact extents retain the constructor's frame0 size
			# even though some drawn animation frames are one pixel shorter.
			p.frame_size=Vector2i(p.width,p.height)
		else:
			var sizes: Array=meta.get("frame_sizes",[])
			if sizes.is_empty(): sizes=meta.get("sprite_frame_sizes",[])
			p.frame_size=Vector2i(p.width,p.height)
			if appearance>=0 and appearance<sizes.size():
				p.frame_size=Vector2i(int(sizes[appearance][0]),int(sizes[appearance][1]))
			var offsets: Array=meta.get("frame_offsets",[])
			if appearance>=0 and appearance<offsets.size():
				var original:=Vector2i(int(offsets[appearance][0]),int(offsets[appearance][1]))
				p.frame_offset=original
				if native_flip_x:
					p.frame_offset.x=p.width-original.x-p.frame_size.x
					if p.part_type not in [36,37]: p.polygon_translation.x=p.frame_offset.x-original.x
				if native_flip_y:
					p.frame_offset.y=p.height-original.y-p.frame_size.y
					# Original 639E writes +49 again, not +4B.
					if p.part_type not in [36,37]: p.polygon_translation.x=p.frame_offset.x-original.y
	if p.width==0 or p.height==0:
		p.width=p.frame_size.x
		p.height=p.frame_size.y
	if p.part_type==40:
		p.stored_extent.x=142 if p.settings&0x1c00 else 102
		p.frame_size=p.stored_extent
		p.frame_offset.x=-40 if p.flip_x and p.settings&0x1c00 else 0
	if p.rotation!=0 or p.editor_mirror_x or p.editor_mirror_y:
		var transformed:=PartTransform.rect(Rect2i(p.frame_offset,p.frame_size),Vector2i(p.width,p.height),p.rotation,p.editor_mirror_x,p.editor_mirror_y)
		p.frame_offset=transformed.position
		p.frame_size=transformed.size
	return Rect2i(p.frame_offset,p.frame_size)

static func initial_velocity(type_id: int) -> Vector2i:
	# Rolling initializer 7821:0170: Dust Bunny, not gravity-driven drift.
	return Vector2i(1024,1024) if type_id == 5 else Vector2i.ZERO

func angles(points: Array) -> Array:
	var result: Array = []
	for i in points.size():
		var next: Array = points[(i+1) % points.size()]
		var dx := int(next[0]) - int(points[i][0])
		var dy := int(next[1]) - int(points[i][1])
		dx += signi(dx)
		dy += signi(dy)
		result.append([int(points[i][0]),int(points[i][1]),(-0x4000-kernel.direction(-dx,dy)) & 65535])
	return result

func collider(source: PartDefinition, sim: SimulationState.SimPart) -> Dictionary:
	# Standalone geometry callers can supply only a PartDefinition. Resolve
	# its logical dimensions before 6212's zero-size sprite fallback runs.
	# +59/+5B's explicit uninitialized marker distinguishes a standalone
	# fixture from a constructed wall whose valid current extent is zero.
	if source!=null and sim.stored_extent.x<0 and sim.part_type not in [1,14,76]:
		if sim.width<=0: sim.width=source.placement_width()
		if sim.height<=0: sim.height=source.placement_height()
	var frame:=frame_geometry(sim)
	var logical_width:=sim.width
	var logical_height:=sim.height
	var outline_flip_x: bool=sim.reaction_data.get("outline_flip_x",sim.flip_x)
	var key := str([sim.part_type,sim.appearance,logical_width,logical_height,sim.flip_x,sim.flip_y,outline_flip_x,sim.rotation,sim.editor_mirror_x,sim.editor_mirror_y,sim.collision_enabled,sim.reaction_data.get("outline_count",-1),sim.constructed_sections,sim.constructed_flip_x,frame,sim.polygon_translation])
	if shape_cache.has(key):
		return shape_cache[key]
	var meta: Dictionary = data.geometry.get(str(sim.part_type), {})
	var points: Array = []
	var quality := String(meta.get("source", "unrecovered"))
	var appearance := maxi(0,int(sim.reaction_data.get("constructed_appearance",sim.appearance)) if sim.part_type==78 else sim.appearance)
	var variant := -1
	if kernel.data.incline_types.has(sim.part_type):
		points = kernel.data.incline_profiles.get(str(logical_width), []).duplicate(true)
	elif kernel.data.wall_types.has(sim.part_type) or sim.part_type == 0:
		var end_x := logical_width - (0 if sim.part_type == 0 else 1)
		var end_y := logical_height - (0 if sim.part_type == 0 else 1)
		# 7AE2:0000 has no positivity/area guard. Zero-width walls retain
		# four active vertices spanning -1..0, with angles rebuilt by 63C9.
		if kernel.data.wall_types.has(sim.part_type) or (end_x > 0 and end_y > 5):
			points = [[0,5,0],[end_x,5,0xc000],[end_x,end_y,0x8000],[0,end_y,0x4000]]
	elif sim.part_type == 40:
		# 5E33:0000 assembles 6 head, 5*4 side and 6 tail vertices.
		# The saved height selects the authored length when live +AF settings
		# have not yet been reconstructed from the editor's initialization.
		var pieces: Dictionary = data.dynamic_constructors.thumpulator
		var count := sim.constructed_sections
		for i in 6:
			points.append([int(pieces.head_xy[i*2]),int(pieces.head_xy[i*2+1]),0])
		var y := 17
		for section in 5:
			for i in 4:
				points.append([int(pieces.segment_xy[i*2]) if section < count else int(pieces.segment_xy[0]),
					y+int(pieces.segment_xy[i*2+1]) if section < count else y,0])
			if section < count:
				y += 65
		for i in 6:
			points.append([int(pieces.tail_xy[i*2]),int(pieces.tail_xy[i*2+1])+y,0])
		if sim.constructed_flip_x:
			for point in points:
				point[0] = 102-int(point[0])
			points.reverse()
		quality = "original Thumpulator pieces; constructed before play"
	elif int(meta.get("point_count", 0)) > 0:
		var variants: Array = meta.get("variants", [])
		if not variants.is_empty():
			variant = clampi(appearance, 0, variants.size()-1)
			# 32F3:000B selects the second source in play mode (2000),
			# irrespective of appearance; the first is the idle/editor polygon.
			if sim.part_type == 36:
				variant = mini(1,variants.size()-1)
			elif sim.part_type == 2:
				# 7917:0082: plug bits 0/1 don't select collision geometry.
				variant = 0 if sim.appearance<4 else 1
			points = variants[variant].duplicate(true)
		else:
			quality = "preview rectangle: unrecovered dynamic constructor"
			points = [[0,0,0],[logical_width-1,0,0xc000],
				[logical_width-1,logical_height-1,0x8000],[0,logical_height-1,0x4000]]
	if not points.is_empty():
		var min_x := int(points[0][0])
		var max_x := min_x
		var min_y := int(points[0][1])
		var max_y := min_y
		for point in points:
			min_x = mini(min_x,int(point[0]))
			max_x = maxi(max_x,int(point[0]))
			min_y = mini(min_y,int(point[1]))
			max_y = maxi(max_y,int(point[1]))
		# Shared mirror generation 7089:018E reverses winding on one reflection.
		# Walls/conveyors rebuild from dimensions and ignore sprite flip flags.
		var mirror_flags := int(meta.get("mirror_flags",0))
		if sim.part_type == 63:
			mirror_flags = 2 if appearance == 0 else 1
		var mirror_x := (outline_flip_x!=sim.editor_mirror_x) and (mirror_flags & 1) != 0
		var mirror_y := (sim.flip_y!=sim.editor_mirror_y) and (mirror_flags & 2) != 0
		var reflection_x := min_x+max_x
		var reflection_y := min_y+max_y
		var axes: Array=meta.get("mirror_axes",[])
		if variant>=0 and variant<axes.size():
			reflection_x=int(axes[variant][0])
			reflection_y=int(axes[variant][1])
		if not kernel.data.wall_types.has(sim.part_type) and sim.part_type != 0:
			if mirror_x or mirror_y:
				for point in points:
					if mirror_x:
						point[0] = reflection_x-int(point[0])
					if mirror_y:
						point[1] = reflection_y-int(point[1])
				if mirror_x != mirror_y:
					points.reverse()
	# 1000:6212 adds instance +49/+4B AFTER choosing the generated mirror.
	# Actors have a separate logical anchor and explicitly skip this step.
	for point in points:
		point[0]=int(point[0])+sim.polygon_translation.x
		point[1]=int(point[1])+sim.polygon_translation.y
	if sim.rotation!=0 or sim.editor_mirror_x or sim.editor_mirror_y:
		for vertex in points:
			var transformed:=PartTransform.point(Vector2i(vertex[0],vertex[1]),Vector2i(logical_width,logical_height),sim.rotation,sim.editor_mirror_x,sim.editor_mirror_y)
			vertex[0]=transformed.x
			vertex[1]=transformed.y
		if sim.editor_mirror_x!=sim.editor_mirror_y:
			points.reverse()
			if sim.part_type==2:
				# Switch collisions expose only original edge0 as an open
				# segment. Reversing a closed list must not select its back edge.
				for shift in points.size()-2: points.push_back(points.pop_front())
	points=angles(points)
	if not sim.collision_enabled: points=[]
	var result := {"points":points,"point_count":1 if sim.part_type==2 and not points.is_empty() else points.size(),"quality":quality,"frame_center":frame.get_center()}
	if sim.collision_enabled and not points.is_empty() and sim.reaction_data.has("outline_count"):
		result.point_count=int(sim.reaction_data.outline_count)
	shape_cache[key] = result
	return result

static func bounds(points: Array, x: int, y: int) -> Rect2i:
	if points.is_empty():
		return Rect2i(x,y,0,0)
	var lo := Vector2i(int(points[0][0]),int(points[0][1]))
	var hi := lo
	for point in points:
		lo.x = mini(lo.x,int(point[0]))
		lo.y = mini(lo.y,int(point[1]))
		hi.x = maxi(hi.x,int(point[0]))
		hi.y = maxi(hi.y,int(point[1]))
	return Rect2i(Vector2i(x,y)+lo,hi-lo+Vector2i.ONE)

func body_for(sim: SimulationState.SimPart, points: Array, center: Vector2i = Vector2i(-1,-1)) -> Types.ContactBody:
	var body := Types.ContactBody.new()
	body.fx = sim.x_fixed >> 6
	body.fy = sim.y_fixed >> 6
	body.x = sim.x_fixed >> 15
	body.y = sim.y_fixed >> 15
	body.ox = body.x
	body.oy = body.y
	body.vx = Kernel.s16(sim.vx_fixed >> 6)
	body.vy = Kernel.s16(sim.vy_fixed >> 6)
	body.flags = sim.flags & ~15
	body.contact = sim.contact_part
	body.angle = sim.contact_angle
	body.edge = sim.contact_edge
	body.points = points
	body.width = sim.width
	body.height = sim.height
	body.has_frame_center = center != Vector2i(-1,-1)
	body.center_x_offset = center.x
	body.center_y_offset = center.y
	frame_geometry(sim)
	body.midpoint_x = sim.frame_offset.x + (sim.stored_extent.x >> 1)
	if sim.rotation!=0 or sim.editor_mirror_x or sim.editor_mirror_y:
		body.midpoint_x=sim.frame_offset.x+(sim.frame_size.x>>1)
	return body

func callback(mover: SimulationState.SimPart, target: SimulationState.SimPart, body: Types.ContactBody, own: bool = false) -> bool:
	# Reactions operate on stable runtime objects. Keep integer velocities and
	# contact position coherent with the solver, including return-0 callbacks.
	_sync_to_sim(mover,body)
	var callback_type := mover.part_type if own else target.part_type
	if kernel.is_surface(callback_type):
		return kernel.target_contact_callback(body,mover,callback_type)
	if callback_type not in [0,23]:
		var response:=reactions.contact(mover,target,body,own)
		_sync_velocity_from_sim(mover,body)
		return response
	match callback_type:
		22,35:
			target.trigger_state = 1
			target.triggered = true
		42:
			if body.edge in [2,3]:
				target.trigger_state = 1
				target.triggered = true
		23:
			var balloon := mover if mover.part_type == 23 else target
			var other := target if mover.part_type == 23 else mover
			var pop := other.part_type == 21
			# 7855:003A: generic Balloon contacts play cue 32 only when vertical
			# speed exceeds 0x200. Bullet, Hat Pin, and Pencil have their own
			# reaction branches and do not use this bump cue.
			if other.part_type not in [21,63,64] and absi(Kernel.s16(balloon.vy_fixed>>6))>0x200:
				reactions.sound_effect(balloon,32,"7855:003A")
			if other.part_type == 63:
				if other.appearance == 0:
					var center := (other.y_fixed >> 15) + (other.height >> 1)
					var balloon_center := (balloon.y_fixed >> 15) + (balloon.height >> 1)
					pop = (balloon_center < center and body.vy > 0) if not other.flip_y else (center < balloon_center and body.vy < 0)
				else:
					pop = (other.x_fixed < balloon.x_fixed) if not other.flip_x else (balloon.x_fixed < other.x_fixed)
			elif other.part_type == 64:
				pop = (balloon.x_fixed >> 15)+(balloon.width >> 1) < (other.x_fixed >> 15)
			if pop:
				balloon.trigger_state = 1
		0:
			# 799D:0080: conveying impulse is applied before the shared response.
			var setting := Kernel.s16(int(target.settings))
			if setting == 0 and body.edge == 0 and target.older_appearance != target.appearance:
				body.vx = 0
			if setting != 0 and body.edge in [0,2]:
				var sign_value := signi(setting) * (1 if body.edge == 0 else -1)
				body.vx = Kernel.s16(body.vx+sign_value*3072)
				if sign_value > 0:
					body.vx = mini(body.vx,3072)
				elif body.vx < 3072:
					# Original 799D:00C0 compares with POSITIVE 0xC00, even
					# on the negative branch. Preserve the observed asymmetry.
					body.vx = -3072
	if callback_type==23: _sync_velocity_from_sim(mover,body)
	else: _sync_to_sim(mover,body)
	return true

func update_reactions(state: SimulationState) -> void:
	# Compatibility entry used by diagnostic scripts after begin().
	if reactions.state==state: reactions.update()

func _sync_to_sim(sim: SimulationState.SimPart,body: Types.ContactBody) -> void:
	sim.x_fixed=body.fx<<6
	sim.y_fixed=body.fy<<6
	sim.vx_fixed=body.vx<<6
	sim.vy_fixed=body.vy<<6
	sim.flags=body.flags
	sim.contact_part=body.contact
	sim.contact_angle=body.angle
	sim.contact_edge=body.edge
	sim.contact_status_8f=body.b1
	sim.contact_status_90=body.b2

func _sync_velocity_from_sim(sim: SimulationState.SimPart,body: Types.ContactBody) -> void:
	body.vx=Kernel.s16(sim.vx_fixed>>6)
	body.vy=Kernel.s16(sim.vy_fixed>>6)
	body.flags=sim.flags
	body.fx=sim.x_fixed>>6
	body.fy=sim.y_fixed>>6
	body.x=body.fx>>9
	body.y=body.fy>>9

func dispatch(mover: SimulationState.SimPart, target: SimulationState.SimPart, body: Types.ContactBody) -> bool:
	if mover.flags08 & 0x2000:
		return false
	# 1000:2281: own callback return is ignored, flags/state can be changed.
	if mover.part_type in [23,36,37,55,60,62]:
		callback(mover,target,body,true)
	return callback(mover,target,body)

func snap(body: Types.ContactBody, acceleration: int) -> void:
	body.fx = body.x*512 if body.vx < 0 else (body.x+1)*512-1
	body.fy = body.y*512 if acceleration < 0 else (body.y+1)*512-1

func respond_pair(a: Types.ContactBody, b: Types.ContactBody, type_a: int, type_b: int, flags0a: int, acceleration_a: int, acceleration_b: int, limit_a: int, limit_b: int) -> void:
	# 1000:2D84: collision weights, not the force/density inputs; signed
	# division, rotation back, THEN arithmetic halving of both velocity vectors.
	var mass_a: int = kernel.types.descriptor(type_a).collision_weight
	var mass_b: int = kernel.types.descriptor(type_b).collision_weight
	var total := mass_a + mass_b
	if total == 0:
		return
	var ar := bounds(a.points,a.x,a.y)
	var br := bounds(b.points,b.x,b.y)
	var ac := Vector2i(a.x+(a.width >> 1),a.y+(a.height >> 1)) if a.width > 0 else ar.get_center()
	var bc := Vector2i(b.x+(b.width >> 1),b.y+(b.height >> 1)) if b.width > 0 else br.get_center()
	if a.has_frame_center:
		ac = Vector2i(a.x+a.center_x_offset,a.y+a.center_y_offset)
	if b.has_frame_center:
		bc = Vector2i(b.x+b.center_x_offset,b.y+b.center_y_offset)
	# direction() includes 1406's negation of X. 3C15 calls 430F directly;
	# cancel that wrapper negation when supplying the center-to-center delta.
	var angle := (kernel.direction(bc.x-ac.x,bc.y-ac.y)-0x4000) & 65535
	var av := kernel.rotate_velocity(a.vx,a.vy,angle)
	var bv := kernel.rotate_velocity(b.vx,b.vy,angle)
	var ax := Kernel.s16(Kernel.divide((mass_a-mass_b)*av.x+2*mass_b*bv.x,total))
	var bx := Kernel.s16(Kernel.divide(2*mass_a*av.x+(mass_b-mass_a)*bv.x,total))
	av = kernel.rotate_velocity(ax,av.y,-angle)
	bv = kernel.rotate_velocity(bx,bv.y,-angle)
	a.vx = av.x >> 1
	a.vy = av.y >> 1
	b.vx = bv.x >> 1
	b.vy = bv.y >> 1
	if (absi(a.vx) < 256 and absi(b.vx) < 256) or a.flags & 1 or flags0a & 0x10:
		if ac.x < bc.x:
			a.vx = mini(a.vx,-1024)
			if not flags0a & 0x10:
				b.vx = maxi(b.vx,1024)
		else:
			a.vx = maxi(a.vx,1024)
			if not flags0a & 0x10:
				b.vx = mini(b.vx,-1024)
	a.vx = clampi(a.vx,-limit_a,limit_a)
	a.vy = clampi(a.vy,-limit_a,limit_a)
	b.vx = clampi(b.vx,-limit_b,limit_b)
	b.vy = clampi(b.vy,-limit_b,limit_b)
	a.flags |= 8
	b.flags |= 8
	snap(a,acceleration_a)
	snap(b,acceleration_b)

func live(p: SimulationState.SimPart) -> bool:
	return p.placed and p.active and not p.flags08 & 0x2000

static func overlaps_inclusive(a: Rect2i,b: Rect2i) -> bool:
	return a.end.x>=b.position.x and b.end.x>=a.position.x and a.end.y>=b.position.y and b.end.y>=a.position.y

func current_body(p: SimulationState.SimPart) -> Types.ContactBody:
	var geometry := collider(p.definition,p)
	var body := body_for(p,geometry.points,geometry.frame_center)
	body.point_count=geometry.point_count
	body.flags = p.flags
	return body

func step(puzzle: PuzzleDefinition, state: SimulationState, extra_acceleration: Dictionary = {}) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	reactions.begin(puzzle,state,self,events)
	reactions.update_statics()
	# 20F2 reloads the mover head for each phase; each loop saves +00 before
	# its callback. Spawns/releases can therefore join a later phase this tick.
	for phase in [_accelerate_mover,_integrate_mover,_respond_mover,_trace_mover]:
		reactions.walk_chain(0x1000,func(p: SimulationState.SimPart):
			phase.call(p,puzzle,state,events,extra_acceleration)
		)
	RopePhysics.finish(state)
	for p in state.parts:
		if SpecialReactions.membership(p) in [0x1000,0x2000]:
			# 1000:887B walks list members even on the removal update.
			# 1000:88BC copies cached sizes; querying geometry here would
			# refresh frames that the original updater deliberately retained.
			p.older_frame_size=p.previous_frame_size
			p.previous_frame_size=p.frame_size
			p.older_position=p.previous_position
			p.previous_position=Vector2i(p.x_fixed>>15,p.y_fixed>>15)
	reactions.finish()
	return events

func _accelerate_mover(sim: SimulationState.SimPart,puzzle: PuzzleDefinition,state: SimulationState,events: Array[Dictionary],extra_acceleration: Dictionary={}) -> void:
	var index:=sim.index
	if not live(sim): return
	var environment := kernel.types.environment(sim.part_type,puzzle.pressure,puzzle.gravity)
	var extra: Vector2i = extra_acceleration.get(sim.part_type,Vector2i.ZERO)
	sim.vx_fixed = clampi(Kernel.s16((sim.vx_fixed>>6)+(extra.x>>6)),-environment.speed_limit_q9,environment.speed_limit_q9)<<6
	sim.vy_fixed = clampi(Kernel.s16((sim.vy_fixed>>6)+environment.acceleration_q9+(extra.y>>6)),-environment.speed_limit_q9,environment.speed_limit_q9)<<6
	# 2839 computes +3D before 20F2 resets +3B to the descriptor weight.
	sim.momentum=((absi(sim.vx_fixed>>6)+absi(sim.vy_fixed>>6))*sim.collision_weight) & 0xffffffff
	if sim.momentum&0x80000000: sim.momentum-=0x100000000
	sim.collision_weight=kernel.types.descriptor(sim.part_type).collision_weight
	sim.flags0a &= ~0x10

func _integrate_mover(sim: SimulationState.SimPart,puzzle: PuzzleDefinition,state: SimulationState,events: Array[Dictionary],extra_acceleration: Dictionary={}) -> void:
	var index:=sim.index
	if not live(sim): return
	reactions.scheduled_update(sim,"mover")
	# 1000:23CD calls the updater before 14B1/1406 read +23/+25.
	# Scissors entry and Teeter probes explicitly relocate that history;
	# Scissors release moves current Y alone and must sweep from the old Y.
	var old_position := sim.previous_position
	var body := current_body(sim)
	body.ox = old_position.x
	body.oy = old_position.y
	var environment := kernel.types.environment(sim.part_type,puzzle.pressure,puzzle.gravity)
	body.fx += body.vx
	body.fy += body.vy + ((-1024 if environment.acceleration_q9<=0 else 1024) if body.flags&1 else 0)
	body.x = body.fx>>9
	body.y = body.fy>>9
	body.flags &= ~15
	detect_contacts(sim,body,state)
	_sync_to_sim(sim,body)
	var attached:=RopePhysics.has_primary_connection(state,sim)
	var corrected:=RopePhysics.constrain(state,sim,self)
	if attached:
		# 1000:23CD probes again after7B83. A taut rope can put the mover
		# back inside a surface that the first probe just cleared. With slack,
		# temporarily forget the old target and restore it/status only when
		# the second probe finds no replacement (2426..2462).
		var saved_contact:=sim.contact_part
		var saved_b1:=sim.contact_status_8f
		var saved_b2:=sim.contact_status_90
		if corrected: sim.flags&=~15
		else: sim.contact_part=-1
		body=current_body(sim)
		body.ox=old_position.x
		body.oy=old_position.y
		detect_contacts(sim,body,state)
		if not corrected and body.contact<0:
			body.contact=saved_contact
			body.b1=saved_b1
			body.b2=saved_b2
		_sync_to_sim(sim,body)
	if body.x < -1000 or body.x > 2000 or body.y < -1000 or body.y > 2000:
		sim.flags08 |= 0x2000
		sim.active = false


func detect_contacts(sim: SimulationState.SimPart,body: Types.ContactBody,state: SimulationState) -> void:
	# Shared 1000:14B1 traversal, also used by mechanism displacement probes.
	# Native null outline returns before clearing retained contact/status bytes.
	if not sim.collision_enabled:
		body.b1=sim.contact_status_8f
		body.b2=sim.contact_status_90
		return
	var index:=sim.index
	var previous := body.contact
	var old_angle := body.angle
	body.b1=0
	body.b2=0
	var order: Array = []
	if previous>=0 and previous<state.parts.size() and live(state.parts[previous]): order.append(previous)
	for chain in [0x2000,0x1000]:
		for other in state.query_chains.get(chain,[]):
			if other!=index and other!=previous: order.append(other)
	var hit := false
	for other in order:
		var target_sim := state.parts[int(other)]
		if not live(target_sim) or not target_sim.collision_enabled or body.points.is_empty(): continue
		# 14B1 uses inclusive current sprite rectangles (45/47/4D/4F),
		# then sweeps vertices. A swept bounding box admits extra candidates.
		var mover_rect := reactions.shape_rect(sim)
		mover_rect.position += Vector2i(body.x,body.y)-reactions.xy(sim)
		var target_rect := reactions.shape_rect(target_sim)
		if not overlaps_inclusive(mover_rect,target_rect): continue
		# Keep native candidate order and frame refreshes, but materialize the
		# full collision body only for overlapping bounds (LOON1 performance).
		var target := current_body(target_sim)
		if target.points.is_empty(): continue
		var candidate := {"index":other,"x":target.x,"y":target.y,"points":target.points,"point_count":target.point_count}
		var found := kernel.detect(body,candidate,false,previous,old_angle)
		# 14B1 rechecks bounds after the forward walker corrected position.
		mover_rect.position=Vector2i(body.x,body.y)+sim.frame_offset
		if overlaps_inclusive(mover_rect,target_rect):
			found = kernel.detect(body,candidate,true,previous,old_angle) or found
		if found:
			hit = true
			# 17FE/1C51 classify by the target's fixed bit or the special
			# pair flag, not by membership alone. Only the last contact wins.
			# Static-list membership does not imply a fixed surface: a Rug
			# can receive the paired impulse before joining the mover list.
			var fixed_contact := (target_sim.flags&0x4000)!=0 or ((sim.flags08|target_sim.flags08)&0x8000)!=0
			body.flags = (body.flags&~6)|(2 if fixed_contact else 4)
	if hit: body.flags |= int(Kernel.continuation(body.angle,previous,old_angle))
	else: body.contact = -1

func teeter_reposition(sim: SimulationState.SimPart,platform: SimulationState.SimPart,state: SimulationState) -> void:
	# 5C75:0346-03EB: +25 is the sweep origin, NOT a requested destination.
	# Probe toward the new plank from 16px away, then probe the opposite way
	# with the plank excluded. Commit logical Y back to the Q9 accumulator
	# before the normal acceleration/integration phase applies launch velocity.
	var body:=current_body(sim)
	body.flags=sim.flags
	body.ox=sim.previous_position.x
	var upward:=body.vy<0
	body.oy=body.y+(-16 if upward else 16)
	detect_contacts(sim,body,state)
	body.oy=body.y+(16 if upward else -16)
	var saved_flags:=platform.flags08
	platform.flags08|=0x2000
	detect_contacts(sim,body,state)
	platform.flags08=saved_flags
	body.fy=body.y*512 if upward else (body.y+1)*512-1
	_sync_to_sim(sim,body)
	# 5C75:0379/03C2 commits +25 to relocated Y before history shifts.
	sim.previous_position.y=body.y

func _respond_mover(sim: SimulationState.SimPart,puzzle: PuzzleDefinition,state: SimulationState,events: Array[Dictionary],extra_acceleration: Dictionary={}) -> void:
	var index:=sim.index
	if not live(sim) or sim.flags&8 or not sim.flags&6: return
	var body := current_body(sim)
	body.b1=sim.contact_status_8f
	body.b2=sim.contact_status_90
	var contacted := body.contact
	if contacted<0 or contacted>=state.parts.size(): return
	var target := state.parts[contacted]
	var environment := kernel.types.environment(sim.part_type,puzzle.pressure,puzzle.gravity)
	var response := dispatch(sim,target,body)
	if body.flags&2:
		if response:
			var sliding_override := 256 if target.part_type==0 and target.trigger_state!=0 else -1
			kernel.respond(body,environment.acceleration_q9,environment.speed_limit_q9,sim.part_type,target.part_type,sliding_override)
		events.append({"kind":"contact","part_index":index,"other":contacted,"angle":body.angle,"edge":body.edge,"reaction":reaction_status(target.part_type)})
	elif body.flags&4:
		if response:
			# 1000:20F2 retains a previously detected pair even if its
			# target was removed during this update (LOON1 Bullet expiry).
			var other_body := current_body(target)
			# 1000:2D84 changes both velocities/positions, but preserves +8F/+90.
			# A fresh ContactBody defaults these to zero; retain the partner's
			# detection result before the full _sync_to_sim write-back.
			other_body.b1=target.contact_status_8f
			other_body.b2=target.contact_status_90
			var other_environment := kernel.types.environment(target.part_type,puzzle.pressure,puzzle.gravity)
			respond_pair(body,other_body,sim.part_type,target.part_type,sim.flags0a,environment.acceleration_q9,other_environment.acceleration_q9,environment.speed_limit_q9,other_environment.speed_limit_q9)
			_sync_to_sim(target,other_body)
		events.append({"kind":"moving_contact","part_index":index,"other":contacted,"angle":body.angle,"reaction":reaction_status(target.part_type)})
	_sync_to_sim(sim,body)

func _trace_mover(sim: SimulationState.SimPart,puzzle: PuzzleDefinition,state: SimulationState,events: Array[Dictionary],extra_acceleration: Dictionary={}) -> void:
	var index:=sim.index
	if not live(sim): return
	events.append({"kind":"integrate","part_index":index,"x_fixed":sim.x_fixed,"y_fixed":sim.y_fixed,"vx_fixed":sim.vx_fixed,"vy_fixed":sim.vy_fixed,
		"acceleration_q9":kernel.types.environment(sim.part_type,puzzle.pressure,puzzle.gravity).acceleration_q9})
	reactions.geometry_event(sim,"resolved")
