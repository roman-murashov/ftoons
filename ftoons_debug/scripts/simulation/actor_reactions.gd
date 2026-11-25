class_name ActorReactions
extends RefCounted

## Native translations of 32F3:00B2/3E1D/0869/44A3 and physical states.
## Perception is called only at the original state-handler sites/cadences.
const K = preload("res://scripts/simulation/bearing_physics.gd")
const Sight = preload("res://scripts/simulation/actor_sight.gd")
const Traversal = preload("res://scripts/simulation/actor_traversal.gd")
var sight := Sight.new()
var traversal := Traversal.new()
var tables: ReactionTables

func _init(data: ReactionTables) -> void:
	tables = data

func accepts(a: SimulationState.SimPart) -> bool:
	for guard in tables.metadata.actor_guards:
		if int(guard.type) != a.part_type:
			continue
		for blocked in guard.blocked_states:
			if a.state == int(blocked):
				return false
		if a.state == int(guard.conditional_state):
			return a.appearance == int(guard.allow_frame)
	return true

func contact(e, a: SimulationState.SimPart, o: SimulationState.SimPart, body) -> void:
	var sid := a.part_type == 37
	var angle: int = body.angle
	var dx: int = K.s16(e.vx(a)-e.vx(o))
	var dy: int = K.s16(e.vy(a)-e.vy(o))
	var incoming: int = e.vy(a)
	var ac: Vector2i = e.xy(a)+Vector2i(a.width>>1,a.height>>1)
	var oc: Vector2i = e.xy(o)+Vector2i(o.width>>1,o.height>>1)
	if not sid:
		oc = e.xy(o)+e.frame_size(o)/2
	if a.trigger_state == -1 and not a.flags & 1:
		if angle == 0 and dy > 0xa00:
			e.request(a,0x15 if sid else 0x1b,"vertical impact",o)
		elif angle == 0x8000 and dy < (-0x800 if sid else -0x600):
			e.request(a,0x16 if sid else 0x1c,"upward impact",o)
		elif angle == 0x4000 and dx > 0x400:
			e.request(a,(0x17 if a.flip_x else 0x18) if sid else (0x1d if a.flip_x else 0x1e),"side impact",o)
		elif angle == 0xc000 and dx < -0x400:
			e.request(a,(0x18 if a.flip_x else 0x17) if sid else (0x1e if a.flip_x else 0x1d),"side impact",o)
	# Current-state exceptions precede the other-type switch.
	var current: int = tables.branch("32F3:3F2D" if sid else "32F3:01C2",a.state)
	if current in [0x3f96,0x21d]:
		if a.appearance == (0xd8 if sid else 0x117):
			a.trigger_state = -1
			var harmful := (o.part_type==18 and o.appearance!=o.previous_appearance) or o.part_type==16
			if o.part_type==63:
				harmful = (ac.y<oc.y if not o.flip_y else ac.y>oc.y) if o.appearance==0 else (ac.x>oc.x if not o.flip_x else ac.x<oc.x)
			elif o.part_type==64:
				harmful = ac.x<oc.x if not o.flip_x else ac.x>oc.x
			if harmful:
				e.request(a,0x35 if sid else 0x39,"protected-state contact",o)
		return
	elif current in [0x4053,0x2da]:
		e.request(a,0x36 if sid else 0x3a,"protected-state follow-through",o)
		return
	elif current in [0x3f31,0x1c6] and angle in [0x4000,0xc000]:
		var state_id := (0x17 if sid else 0x1d) if ((angle==0xc000) != a.flip_x) else (0x18 if sid else 0x1e)
		e.request(a,state_id,"running side impact",o)
	elif current in [0x3f6d,0x202] and angle in [0x4000,0xc000]:
		e.request(a,0,"running blocked",o)
		e.set_vx(a,0)
	elif current == 0x2f9:
		if a.trigger_state in [-1,0x1b]:
			e.request(a,0 if incoming<0xa00 else 0x1b if incoming<0x2000 else 4,"Al landing",o)
			e.set_vy(a,0)
	elif current in [0x3f88,0x383] and a.trigger_state==-1:
		e.request(a,0,"contact resumes idle",o)
	elif current in [0x405b,0x32d]:
		# Original current-state exception table (Al32F3:07F5): the five
		# non-candy inclines preserve sliding. Candy Cane contacts clear it.
		var exclude: bool = o.part_type in [48,49,50,51,84]
		if not exclude and a.trigger_state==-1:
			e.request(a,0,"contact clears temporary state",o)
	elif current == 0x2f1:
		e.request(a,0x2b,"Al state contact",o)
		return
	elif current == 0x2e2:
		if a.appearance==0x1a4:
			e.request(a,5,"Al frame contact",o)
		return
	elif current == 0x35b:
		if angle in [0x4000,0xc000]:
			e.set_vx(a,0)
		elif a.appearance>0x68 and a.trigger_state==-1:
			e.request(a,0,"Al landing follow-through",o)
	e.set_vy(a,0)
	var branch: int = tables.branch("32F3:40AA" if sid else "32F3:03A5",o.part_type)
	var allowed := accepts(a)
	if sid:
		match branch:
			0x40ae: _actor_pair(e,o,a)
			0x40ba: e.request(a,8,"type 4 impact",o)
			0x40c2: e.request(a,0xd,"type 21 impact",o)
			0x40ca:
				if allowed:
					e.request(a,0xe,"Dust Bunny contact",o,true)
			0x4176:
				if absi(dy)>0xa00: e.request(a,0x10,"ball impact",o)
			0x418b:
				if absi(dy)>0xa00: e.request(a,0x11,"hard-object impact",o)
			0x41a0:
				if absi(e.vy(o)>>9)==0 and allowed: e.request(a,0x1e,"Bubble Gum contact",o,true)
			0x41c8: _scissors_actor(e,a,o,ac,oc,true,allowed)
			0x4261:
				if allowed and o.trigger_state!=0 and e.vy(o)>0 and ac.y>oc.y and absi(ac.x-oc.x)<25:
					e.request(a,0x14,"Piano impact",o,true)
			0x42a2:
				if allowed: e.request(a,0x12,"Cheese contact",o,true)
			0x42b9:
				if allowed:
					# 32F3:42C4..42FC notifies Sid's OLD Al target before
					# replacing +B1 with the Pencil. Keep this as a pending
					# request so the actor's scheduled update consumes it.
					var old_target=e.part(a.target_part)
					if old_target!=null and old_target.part_type==36:
						if old_target.state==6: e.request(old_target,0x1a,"Sid reached Pencil",a)
						elif old_target.state==0x12: e.request(old_target,5,"Sid reached Pencil",a)
					e.request(a,0x2e,"Pencil contact",o,true)
			0x4308:
				e.set_vy(a,incoming)
				e.request(a,0x19,"Air Mattress contact",o)
			0x4316: _incline(e,a,o,body,incoming,allowed,true)
			0x438a:
				if allowed: e.request(a,0x32 if o.appearance==4 else 0x34,"Banana contact",o,true)
			0x43ad:
				if allowed and dy < -0xa00: e.request(a,0x37,"Egg impact",o,true)
			0x40e1: _hat_pin(e,a,o,ac,oc,true,incoming)
	else:
		match branch:
			0x3aa: _actor_pair(e,a,o)
			0x3b6:
				if absi(dy)>0xe00: e.request(a,4,"hard-object impact",o)
			0x3cb:
				if absi(dy)>0xe00: e.request(a,0x1b,"ball impact",o)
			0x3e0:
				if absi(dy)>0xa00: e.request(a,5,"Beachball impact",o)
			0x3f5:
				if absi(dy)>0xa00: e.request(a,8,"ball impact",o)
			0x40a:
				if allowed:
					e.deactivate(o,"Al consumed Dust Bunny",a)
					e.request(a,7,"Dust Bunny contact",o)
			0x424: e.request(a,7,"type 4 contact",o)
			0x42c:
				e.set_vx(a,0)
				e.request(a,0x2b if a.flip_x==o.flip_x else 0x10,"type 21 contact",o)
			0x45c: _scissors_actor(e,a,o,ac,oc,false,allowed)
			0x4ed:
				if allowed and a.state==0xe and incoming>0: e.request(a,0xf,"Ball-O-Yarn landing",o,true)
				elif allowed and incoming==0: e.request(a,0x30,"Ball-O-Yarn contact",o,true)
			0x521:
				if incoming>0:
					e.set_vy(a,incoming)
					e.request(a,0,"Air Mattress contact",o)
			0x535: _incline(e,a,o,body,incoming,allowed,false)
			0x5aa: _hat_pin(e,a,o,ac,oc,false,incoming)
			0x643:
				if allowed and o.trigger_state!=0 and e.vy(o)>0 and ac.y>oc.y and absi(ac.x-oc.x)<25:
					e.request(a,0x29,"Piano impact",o,true)
			0x684:
				if absi(e.vy(o)>>9)<1 and allowed: e.request(a,0x2a,"Bubble Gum contact",o,true)
			0x6ac:
				if allowed: e.request(a,0x2e,"Pencil contact",o,true)
			0x6c2:
				if allowed: e.request(a,0x32,"Fish contact",o,true)
			0x6d8:
				if absi(ac.x-oc.x)<10:
					e.request(a,0x38,"Rug contact",o)
					e.request(o,1,"Al landed on Rug",a)
			0x6fa:
				if allowed: e.request(a,0x36 if o.appearance==4 else 0x37,"Banana contact",o,true)
			0x71d:
				if allowed and e.vy(o)-e.vy(a)>0xa00: e.request(a,0x3b,"Egg impact",o,true)

func _actor_pair(e, al: SimulationState.SimPart, sid: SimulationState.SimPart) -> void:
	if not accepts(al): return
	if al.state in [6,0xe]:
		if sid.state not in [11,45,46,47,48,49]: e.request(al,0x14,"actor collision",sid,true)
	else:
		e.request(al,5,"actor collision",sid)
		e.request(sid,0x1b,"actor collision",al)

func _scissors_actor(e,a,o,ac: Vector2i,oc: Vector2i,sid: bool,allowed: bool) -> void:
	var front: bool = (ac.x>oc.x and (not a.flip_x if sid else a.flip_x) and not o.flip_x) or (ac.x<oc.x and (a.flip_x if sid else not a.flip_x) and o.flip_x)
	if front and o.appearance==0 and allowed:
		e.request(a,9 if sid else 0x19,"Scissors contact",o,true)
	elif (ac.x>oc.x and o.flip_x) or (ac.x<oc.x and not o.flip_x):
		if sid:
			e.face(a,o.flip_x)
			e.request(a,0xf,"Scissors side contact",o)
		else:
			e.request(a,0x10 if a.flip_x==o.flip_x else 0x25,"Scissors side contact",o)

func _incline(e,a,o,body,incoming: int,allowed: bool,sid: bool) -> void:
	var supported: bool = (body.b1!=0 if not o.flip_x else body.b2!=0)
	e.set_vy(a,incoming)
	if incoming>0 and allowed and e.xy(a).y<e.xy(o).y and supported:
		a.target_part=o.index
		if o.appearance>=0 and o.appearance<4:
			e.request(a,(0x29-o.appearance) if sid else (0x22-o.appearance),"incline slide",o,true)

func _hat_pin(e,a,o,ac: Vector2i,oc: Vector2i,sid: bool,incoming_y: int) -> void:
	if o.appearance==0:
		if ac.y>oc.y if o.flip_y else ac.y<oc.y:
			# The shared contact prelude has already cleared live VY. Original
			# 05BF/05D9 tests the incoming value saved in the stack local.
			if sid or (incoming_y<0 if o.flip_y else incoming_y>0):
				e.set_vx(a,0)
				e.set_vy(a,0)
				e.request(a,(0x25 if o.flip_y else 0x24) if sid else (0x24 if o.flip_y else 0x23),"Hat Pin contact",o)
	elif (ac.x<oc.x and o.flip_x) or (ac.x>oc.x and not o.flip_x):
		if sid:
			e.face(a,o.flip_x)
			e.set_vx(a,0)
			e.set_vy(a,0)
			e.request(a,0xf,"Hat Pin side",o)
		elif (e.vx(a)>0 if o.flip_x else e.vx(a)<0):
			# 32F3:05EB..063B: approaching the point tail-first produces
			# CATPIN3; the opposite facing selects CATSHOT. Check incoming VX
			# before clearing it so stationary/receding contacts do not retrigger.
			e.request(a,0x25 if a.flip_x==o.flip_x else 0x10,"Hat Pin side",o)
			e.set_vx(a,0)

func update(e,a: SimulationState.SimPart) -> void:
	if a.flags08 & 0x40: return
	a.flags08 |= 0x40
	if a.flags & 1 and e.vy(a)>0xbff: e.set_vy(a,0xbff)
	var pending := a.trigger_state
	if pending>=0 and pending!=a.state and accepts(a):
		var row: Dictionary=tables.actor(a.part_type,pending)
		if not row.is_empty():
			var before:=a.appearance
			_entry(e,a,pending)
			if int(row.initial_frame)>=0: a.appearance=int(row.initial_frame)
			if a.appearance!=before:
				var old:=a.state
				a.state=pending
				a.reaction_state=0
				e.event("actor_state",a,{"from":old,"state":pending,"frame":a.appearance,"target":a.target_part})
	elif pending>=0 and pending!=a.state:
		e.event("reaction_rejected",a,{"state":a.state,"request":pending})
	a.trigger_state=-1
	if a.aux_a5 & 0xff00:
		var cooldown: int=(a.aux_a5&255)-1
		a.aux_a5=(a.aux_a5&0xff00)|cooldown if cooldown>0 else 0
	var row: Dictionary=tables.actor(a.part_type,a.state)
	if _custom(e,a): return
	if row.has("animation"):
		_linear(e,a,row.animation)
		if a.part_type==37 and a.state in [0x1f,0x20,0x21,0x22]:
			if e.vy(a)>0xc00: e.request(a,5,"idle animation falling")
			else: sight.scan(e,a)
	elif row.get("normalized_handler")!=null:
		# Explicit trace rather than invent a replacement for a complex actor
		# locomotion/perception state absent from the physical-state translation.
		if not a.reaction_data.has("pending_handler"):
			a.reaction_data["pending_handler"]=row.normalized_handler
			e.event("unresolved_actor_handler",a,{"handler":row.normalized_handler,"state":a.state})

func _entry(e,a: SimulationState.SimPart,next: int) -> void:
	if next==(0xb if a.part_type==37 else 0x18):
		traversal.enter_ladder(e,a)
		return
	var branch: int=tables.branch("32F3:4505" if a.part_type==37 else "32F3:08CB",next)
	var target=e.part(a.target_part)
	match branch:
		0x8d0,0x46f9:
			e.set_vx(a,0)
			e.set_vy(a,0)
		0x8db:
			# 08CB entries 09/16/17: falling, avoidance startup and glass
			# recoil clear horizontal motion before their first updater call.
			e.set_vx(a,0)
		0x8de: a.target_part=-1
		0x450a,0x452a,0x454a:
			var code: int={0x450a:1,0x452a:3,0x454a:4}[branch]
			if a.aux_a5>>8!=code:
				e.set_vx(a,0)
				a.appearance={1:1,3:5,4:8}[code]
				a.aux_a5=(code<<8)|60
		0x8e7:
			if target!=null and target.part_type==37:
				e.deactivate(target,"Al captured Sid",a)
				a.target_part=-1
				a.appearance=0x87
		0x97d,0x456a:
			if target!=null and target.part_type==16:
				var offset: int=(0x26 if not a.flip_x else -0x16) if a.part_type==37 else (-0x2f if not a.flip_x else 0x26)
				e.position(a,e.xy(target)+Vector2i(offset,1 if a.part_type==37 else -2))
				# 32F3:4593/45A4 and09A6/09B9 relocate +23/+25 too.
				# The new pose is the sweep origin, not motion through Scissors.
				a.previous_position=e.xy(a)
				a.appearance=0x2d if a.part_type==37 else 0xc5
		0xa40,0x464e:
			if target!=null and target.part_type==60:
				e.freeze(a)
				a.appearance=0x7f if a.part_type==37 else 0xf7
				if a.part_type==36: e.face(a,false)
		0xab9:
			# Al's Tunnel entry aligns before 2E97 freezes and animates him.
			# Sid has a separate position sequence inside 65D6.
			if target!=null and target.part_type==46:
				var x: int=e.xy(target).x+(target.width-a.width if a.flip_x else 0)
				e.position(a,Vector2i(x,e.xy(a).y))
				a.previous_position.x=x
		0x9f4,0x46b4:
			if target!=null and target.part_type in [47,48,49,50,51,84]:
				e.face(a,not target.flip_x if a.part_type==37 else target.flip_x)
		0xb00:
			if target!=null and target.part_type==56:
				e.set_vx(a,0)
				e.set_vx(target,0)
		0xb1a:
			if target!=null and target.part_type==77:
				e.position(a,Vector2i(e.xy(target).x-(a.width>>1),e.xy(a).y))
			e.set_vx(a,0)

func _linear(e,a: SimulationState.SimPart,program: Dictionary) -> void:
	var first:=a.reaction_state==0
	_pre_linear(e,a,first)
	a.reaction_state+=1
	a.animation_tick=a.reaction_state
	var cadence:=int(program.cadence)
	if a.reaction_state%cadence!=0:
		_actor_sound_cues(e,a,first)
		# 32F3:2D3F: Al cancels the Bubble Gum launch on the odd hold update.
		if a.part_type==36 and a.state==0x2a and a.appearance==0x112: e.set_vy(a,0)
		return
	var limit:=int(program.limit)
	if limit==0 or a.reaction_state<limit:
		var index: int=K.divide(a.reaction_state,cadence)
		a.appearance=(tables.s8(int(program.base)+index) if bool(program.signed) else tables.u8(int(program.base)+index))+int(program.add)
	else:
		_terminal(e,a,program)
	# Collision-driven follow-throughs at specific appearances.
	var target=e.part(a.target_part)
	_actor_sound_cues(e,a,first)
	if a.part_type==37 and a.state==9 and a.appearance==0x30 and a.previous_appearance==0x2f and target!=null and target.part_type==16:
		e.request(target,1,"Sid closes Scissors",a)
	if a.part_type==36 and a.state==0x19 and target!=null and target.part_type==16 and a.appearance==0xc8 and a.previous_appearance==0xc7:
		# 32F3:2299-22BC sends the request only on the C7 -> C8 transition.
		e.request(target,1,"Al closes Scissors",a)
	_post_linear(e,a,first,limit>0 and a.reaction_state>=limit)


func _actor_sound_cues(e,a: SimulationState.SimPart,first: bool) -> void:
	# These are literal audio-dispatch IDs from the actor state handlers in
	# decompilation/contact_reactions/helpers_repaired.c. Keep their frame and
	# state guards at the original callback transitions.
	if a.part_type==36 and a.state==0xf and a.reaction_state<66 and a.reaction_state%2==0 and a.appearance<0x6d:
		_guarded_voice(e,a)
	if a.part_type==37:
		match a.state:
			0x04:
				if first: e.sound_effect(a,3021,"32F3:4FF4")
			0x08:
				_actor_frame_cue(e,a,0x1d,3044,"32F3:508F")
				_actor_frame_cue(e,a,0x22,3046,"32F3:508F",0x21)
				_actor_frame_cue(e,a,0x26,3065,"32F3:508F")
			0x0d:
				if first: e.sound_effect(a,3001,"32F3:5531")
				_actor_frame_cue(e,a,0x43,3051,"32F3:5531",0x42)
			0x0e:
				_actor_frame_cue(e,a,0x4b,3031,"32F3:55A9")
				_actor_frame_cue(e,a,0x4f,3008,"32F3:55A9",0x4e)
			0x0f:
				_actor_frame_cue(e,a,0x53,3061,"32F3:56AC")
			0x10:
				_actor_frame_cue(e,a,0x5a,16,"32F3:5732")
				_actor_frame_cue(e,a,0x61,2,"32F3:5732")
			0x11:
				_actor_frame_cue(e,a,0x63,22,"32F3:57B2")
				_actor_frame_cue(e,a,0x6a,22,"32F3:57B2")
			0x12:
				# 32F3:581F starts the synthesized toneup cue on state entry,
				# then plays RAW garbage when the half-rate animation reaches 70h.
				if first: e.sound_effect(a,8,"32F3:581F")
				if a.reaction_state%2==0 and a.appearance==0x70:
					e.sound_effect(a,3071,"32F3:581F")
			0x13:
				_actor_frame_cue(e,a,0x76,3006,"32F3:58BF",0x75)
				_actor_frame_cue(e,a,0x79,3031,"32F3:58BF",0x78)
				_actor_frame_cue(e,a,0x7b,3104,"32F3:58BF",0x79)
				_actor_frame_cue(e,a,0x7c,3064,"32F3:58BF")
				_actor_frame_cue(e,a,0x76,3131,"32F3:58BF",0x7e)
			0x15,0x16:
				if first: e.sound_effect(a,3047,"32F3:5AF5" if a.state==0x15 else "32F3:5B5C")
			0x17:
				if first: e.sound_effect(a,3103,"32F3:5BC3")
			0x1a:
				_actor_frame_cue(e,a,0x91,3031,"32F3:5CB9",0x90)
				_actor_frame_cue(e,a,0x94,3061,"32F3:5CB9")
				_actor_frame_cue(e,a,0xa5,3019,"32F3:5CB9",0xa4)
				_actor_frame_cue(e,a,0xaf,9,"32F3:5CB9")
			0x1b:
				if first: e.sound_effect(a,3063,"32F3:5D98")
			0x1c:
				_actor_frame_cue(e,a,0xc0,3065,"32F3:5DEC")
			0x1e:
				_actor_frame_cue(e,a,0xd3,3043,"32F3:5EC6")
				_actor_frame_cue(e,a,0xd4,3070,"32F3:5EC6",0xd3)
			0x1f:
				_actor_frame_cue(e,a,0xd9,5,"32F3:5FBC")
			0x20:
				_actor_frame_cue(e,a,0xdb,3043,"32F3:6039")
			0x21:
				_actor_frame_cue(e,a,0xde,3043,"32F3:60B6")
			0x22:
				_actor_frame_cue(e,a,0xe1,3125,"32F3:6133")
				_actor_frame_cue(e,a,0xe3,3064,"32F3:6133")
			0x23:
				if first: e.sound_effect(a,3033,"32F3:621A")
				_actor_frame_cue(e,a,0xe6,3009,"32F3:621A")
			0x24:
				if first: e.sound_effect(a,10,"32F3:629C")
				_actor_frame_cue(e,a,0xee,3090,"32F3:629C")
			0x25:
				if first: e.sound_effect(a,10,"32F3:633E")
				_actor_frame_cue(e,a,0xf6,3043,"32F3:633E")
			0x2e:
				for frame in [0x14a,0x14d,0x150,0x153]:
					_actor_frame_cue(e,a,frame,3131,"32F3:6933")
			0x30:
				if first: e.sound_effect(a,3075,"32F3:6B21")
				for frame in [0x15d,0x160,0x163]:
					_actor_frame_cue(e,a,frame,3131,"32F3:6B21")
				_actor_frame_cue(e,a,0x16a,3002,"32F3:6B21")
				_actor_frame_cue(e,a,0x16f,3009,"32F3:6B21")
				_actor_frame_cue(e,a,0x178,3040,"32F3:6B21")
			0x31:
				if first: e.sound_effect(a,21,"32F3:6C1B")
				for frame in [0x17e,0x181,0x184,0x187,0x18a]:
					_actor_frame_cue(e,a,frame,3131,"32F3:6C1B")
			0x32:
				if first: e.sound_effect(a,3061,"32F3:6D43")
			0x33:
				_actor_frame_cue(e,a,0x196,9,"32F3:6CCC")
			0x34:
				_actor_frame_cue(e,a,0x199,3115,"32F3:6DFC",0x198)
				_actor_frame_cue(e,a,0x1a0,3072,"32F3:6DFC",0x19f)
				_actor_frame_cue(e,a,0x1a1,3010,"32F3:6DFC",0x1a0)
				if a.appearance>0x1a1: e.sound_effect(a,3064,"32F3:6DFC")
			0x35:
				if first: e.sound_effect(a,3040,"32F3:6FB7")
			0x36:
				if first: e.sound_effect(a,3005,"32F3:7018")
				_actor_frame_cue(e,a,0x1ac,3043,"32F3:7018")
				_actor_frame_cue(e,a,0x1ad,3063,"32F3:7018")
			0x37:
				if first: e.sound_effect(a,3067,"32F3:70A1")
				_actor_frame_cue(e,a,0x1ba,3067,"32F3:70A1")
				_actor_frame_cue(e,a,0x1be,3051,"32F3:70A1")
				_actor_frame_cue(e,a,0x1e1,3036,"32F3:70A1")
		return
	if a.part_type!=36: return
	match a.state:
		1:
			if a.reaction_state>0 and a.reaction_state%80==0:
				e.sound_effect(a,3016,"32F3:150D")
		2:
			if a.appearance==6 and a.previous_appearance==4:
				e.sound_effect(a,3065,"32F3:157B")
		4:
			if first: e.sound_effect(a,3004,"32F3:1629")
			if a.appearance==0x1e and a.previous_appearance==0x1d:
				e.sound_effect(a,3065,"32F3:1629")
		5:
			if first: e.sound_effect(a,3050,"32F3:15D6")
		7:
			# The DOS callback repeats licking/gag requests on each even
			# animation update at these frames, including held appearances.
			_actor_frame_cue(e,a,0x2c,3013,"32F3:17D7")
			_actor_frame_cue(e,a,0x32,3014,"32F3:17D7")
			_actor_frame_cue(e,a,0x37,3015,"32F3:17D7",0x36)
		8:
			if first:
				e.sound_effect(a,6,"32F3:18F0")
				e.sound_effect(a,3051,"32F3:18F0")
		9:
			if first: e.sound_effect(a,3059,"32F3:1955")
		0x0e:
			if first: e.sound_effect(a,3053,"32F3:3C1E")
		0x1a:
			if first: e.sound_effect(a,3009,"32F3:2306")
		0x1b:
			if first: e.sound_effect(a,3002,"32F3:2376")
		0x1c:
			if first: e.sound_effect(a,3055,"32F3:23E6")
		0x1d,0x1e:
			if first: e.sound_effect(a,3067,"32F3:2456" if a.state==0x1d else "32F3:24C6")
		0x23,0x24,0x25:
			if first: e.sound_effect(a,10,"32F3:26D2" if a.state==0x23 else "32F3:276F" if a.state==0x24 else "32F3:2822")
			if a.state==0x25: _actor_frame_cue(e,a,0xe9,3061,"32F3:2822")
		0x2a:
			_actor_frame_cue(e,a,0xfe,16,"32F3:2B5B",0xfd)
			_actor_frame_cue(e,a,0x107,3073,"32F3:2B5B")
			_actor_frame_cue(e,a,0x109,3043,"32F3:2B5B",0x108)
			_actor_frame_cue(e,a,0x10a,3070,"32F3:2B5B",0x109)
		0x2b:
			if first: e.sound_effect(a,3043,"32F3:357B")
			_actor_frame_cue(e,a,0x107,3073,"32F3:2B5B")
			_actor_frame_cue(e,a,0x10a,3070,"32F3:2B5B",0x109)
			_actor_frame_cue(e,a,0x119,3043,"32F3:357B",0x118)
		0x2c:
			_actor_frame_cue(e,a,0x11a,3130,"32F3:2D51")
			_actor_frame_cue(e,a,0x121,3005,"32F3:2D51",0x120)
			_actor_frame_cue(e,a,0x124,3017,"32F3:2D51",0x123)
			_actor_frame_cue(e,a,0x12b,18,"32F3:2D51")
			_actor_frame_cue(e,a,0x130,3028,"32F3:2D51")
			_actor_frame_cue(e,a,0x13a,3013,"32F3:2D51",0x139)
			_actor_frame_cue(e,a,0x147,3064,"32F3:2D51")
			_actor_frame_cue(e,a,0x14d,3028,"32F3:2D51",0x151)
		0x2e:
			_actor_frame_cue(e,a,0x178,3010,"32F3:3161")
		0x2f:
			_actor_frame_cue(e,a,0x17c,3075,"32F3:33AB")
		0x30:
			_actor_frame_cue(e,a,0x186,3010,"32F3:3D36",0x185)
		0x31:
			if first: e.sound_effect(a,21,"32F3:350A")
		0x32:
			_actor_frame_cue(e,a,0x197,3104,"32F3:360C",0x196)
			_actor_frame_cue(e,a,0x19a,7,"32F3:360C")
		0x36:
			if first: e.sound_effect(a,8,"32F3:3798")
			_actor_frame_cue(e,a,0x1c5,3003,"32F3:3798")
		0x37:
			_actor_frame_cue(e,a,0x1ce,3072,"32F3:382D")
			_actor_frame_cue(e,a,0x1d5,3073,"32F3:382D")
			_actor_frame_cue(e,a,0x1d7,3064,"32F3:382D")
		0x39:
			if first: e.sound_effect(a,3040,"32F3:39F5")
		0x3a:
			_actor_frame_cue(e,a,0x1db,3005,"32F3:3A71")
			_actor_frame_cue(e,a,0x1de,3013,"32F3:3A71",0x1dd)
			_actor_frame_cue(e,a,0x1e3,3043,"32F3:3A71",0x1e2)
			_actor_frame_cue(e,a,0x1e4,3073,"32F3:3A71")
			_actor_frame_cue(e,a,0x1e7,3013,"32F3:3A71")
		0x3b:
			if first: e.sound_effect(a,3067,"32F3:3B56")
			_actor_frame_cue(e,a,0x1f1,3003,"32F3:3B56",0x1f0)
			_actor_frame_cue(e,a,0x1f4,3044,"32F3:3B56")
			_actor_frame_cue(e,a,0x207,3003,"32F3:3B56")

func _guarded_voice(e,a: SimulationState.SimPart) -> void:
	# 32F3:0D6D queries all four IDs before selecting with RNG &3.
	# AUDBLAST's class-3000 query observes the shared RAW channel, even
	# for another ID. Disabled queries return zero before the RNG draw.
	const IDS=[3053,3062,3103,3104]
	for id in IDS:
		if e.audio_playing(id): return
	var choice:int=e.state.next_random()&3
	e.sound_effect(a,IDS[choice],"32F3:0D6D")

func _actor_frame_cue(e,a,frame: int,sound_id: int,dos_source: String,previous_frame: int=-1) -> void:
	if a.appearance!=frame: return
	var row: Dictionary=tables.actor(a.part_type,a.state)
	var program: Dictionary=row.get("animation",{})
	var cadence: int=maxi(1,int(program.get("cadence",1)))
	var limit: int=int(program.get("limit",0))
	if a.reaction_state%cadence!=0 or (limit>0 and a.reaction_state>=limit): return
	if previous_frame>=0 and a.previous_appearance!=previous_frame: return
	e.sound_effect(a,sound_id,dos_source)

func _pre_linear(e,a: SimulationState.SimPart,first: bool) -> void:
	var sid:=a.part_type==37
	var s:=a.state
	var target=e.part(a.target_part)
	if sid and s==0x0d:
		# 32F3:5552: the shot animation cancels horizontal motion every update,
		# after the impact response and before the next position integration.
		e.set_vx(a,0)
	if first and not sid and s==0x2b:
		# 32F3:357B: rear-shot entry clears both velocities once. Later
		# collision responses can still impart motion during the animation.
		e.set_vx(a,0)
		e.set_vy(a,0)
	if first and not sid and s in [0x1b,0x1c,0x1d]:
		# 32F3:2397/23E6/2456: compression and side-hit entries cancel motion.
		e.set_vx(a,0)
		e.set_vy(a,0)
	if first and not sid and s==0x1e:
		# 32F3:24C6,24E7..24EE: side-impact entry cancels both velocities
		# once; later collisions may still move Al during this reaction.
		e.set_vx(a,0)
		e.set_vy(a,0)
	if first and not sid and s==0x37:
		# 32F3:382D: eating a Banana cancels entry motion once. Later
		# contacts can still move Al while the eating animation continues.
		e.set_vx(a,0)
		e.set_vy(a,0)
	if first and s==(0x1e if sid else 0x2a):
		e.set_vx(a,0)
		e.set_vy(a,0)
		if target!=null and target.part_type==54:
			e.set_vx(target,0)
			e.set_vy(target,0)
			if sid: a.target_part=-1
	if sid and s==0x2e:
		e.set_vx(a,0)
		if first:
			e.set_vy(a,0)
			if target!=null and target.part_type==64:
				e.deactivate(target,"Sid Pencil reaction",a)
				a.target_part=-1
	if sid and s==0x30:
		if first:
			e.set_vx(a,0)
			e.set_vy(a,0)
			if target!=null and target.part_type==36: e.deactivate(target,"Sid physical sequence",a)
		if a.flags&1: e.set_vx(a,0)
	if first:
		var food_type: int=57 if sid and s==0x12 else 59 if (sid and s in [0x32,0x34]) or (not sid and s==0x36) else 7 if not sid and s==0xf else 55 if s==(0x37 if sid else 0x3b) else -1
		if target!=null and target.part_type==food_type:
			e.deactivate(target,"actor consumed target",a)
			#32F3:70C7 clears Sid's +B1 after consuming Egg. Banana's
			#0x34 sequence retains its target for the later throw/reuse.
			if s not in [0x34,0x37] or (sid and s==0x37): a.target_part=-1
		if s in ([9,0x1a,0x24,0x25,0x33] if sid else [0x19,0x23,0x24,0x25]): e.freeze(a)
	if s in ([0xe,0x2b,0x1d] if sid else [0x36]):
		e.set_vx(a,0)
		if s!=0xe: e.set_vy(a,0)
	if sid and s==0x32 and absi(e.vx(a))<0x400:
		e.set_vx(a,e.vx(a)+(0xa00 if a.flip_x else -0xa00))
	if not sid and s==0x39:
		if a.reaction_state==0: e.set_vy(a,40<<9)
		elif a.reaction_state==1: e.set_vy(a,0)

func _terminal(e,a: SimulationState.SimPart,program: Dictionary) -> void:
	var sid:=a.part_type==37
	var s:=a.state
	if sid and s in [0x1f,0x20,0x21,0x22]:
		# 32F3:61C9: residues 0..2 repeat the first wait, then 20/21/22.
		var choice: int=e.state.next_random()%6
		e.request(a,[0x1f,0x1f,0x1f,0x20,0x21,0x22][choice],"idle animation selection")
		return
	var target=e.part(a.target_part)
	if (sid and s in [0x26,0x27,0x28,0x29]) or (not sid and s in [0x1f,0x20,0x21,0x22]):
		a.reaction_state=0 # Incline animation repeats while physics carries it.
	elif sid and s==0x32: a.reaction_state=4
	elif not sid and s==0xf:
		a.appearance=0x6d if a.appearance==0x6f else a.appearance+1
		a.reaction_state=66
	elif not sid and s==0xe:
		# 32F3:3C51..3CA4: only counters below ten select a pounce
		# frame. Thereafter hold the airborne pose until another reaction.
		# Advancing here escapes CATPOUNC into unrelated appearance layouts.
		pass
	elif (sid and s in [0x24,0x25]) or (not sid and s in [0x23,0x24,0x25]):
		if a.reaction_state==int(program.limit):
			e.release(a)
			if sid: e.set_vy(a,-0x3000)
			elif s==0x23: e.set_vy(a,-0x3000)
			elif s==0x25:
				e.set_vx(a,(-1 if a.flip_x else 1)*0xc00)
				e.set_vy(a,-0xc00)
		if e.vy(a)>0xc00: e.request(a,5 if sid else 9,"Hat Pin follow-through")
		if not sid and s==0x25: a.appearance=0xeb if a.appearance==0xea else 0xea
	elif sid and s in [0x1a,0x33]:
		if a.reaction_state==int(program.limit): e.release(a)
		a.collision_enabled=false
	elif s==(9 if sid else 0x19):
		e.release(a)
		if not sid and target!=null:
			e.position(a,Vector2i(e.xy(a).x,e.xy(target).y+e.shape_rect(target).size.y-14))
		e.request(a,0,"Scissors reaction completed")
	elif (sid and s in [0x13,0x34]) or (not sid and s in [0x2c,0x37]):
		# These protected states end by writing the active state directly;
		# sending a request through their acceptance guard would never finish.
		_idle(a)
	elif (sid and s==0x1e) or (not sid and s==0x2a):
		_lift(e,a,0x400)
	elif bool(program.removes_actor): e.deactivate(a,"actor reaction completed")
	elif int(program.next)>=0: e.request(a,int(program.next),"actor animation completed")

func _lift(e,a: SimulationState.SimPart,power: int) -> void:
	var acceleration: int=e.world.kernel.types.environment(a.part_type,e.puzzle.pressure,e.puzzle.gravity).acceleration_q9
	e.set_vy(a,e.vy(a)-power-acceleration)
	e.clamp_velocity(a)
	a.momentum=((absi(e.vx(a))+absi(e.vy(a)))*a.collision_weight)&0xffffffff
	if a.momentum&0x80000000: a.momentum-=0x100000000

func _post_linear(e,a: SimulationState.SimPart,_first: bool,terminal: bool=false) -> void:
	var sid:=a.part_type==37
	var s:=a.state
	var target=e.part(a.target_part)
	if not sid and s==7 and a.appearance==0x35 and a.previous_appearance==0x37:
		e.spawn(4,e.xy(a)+Vector2i(-55 if a.flip_x else 55,12),Vector2i(-0x2000 if a.flip_x else 0x2000,-0x800),a.flip_x)
	if not sid and s==0x32 and a.appearance==0x194 and a.previous_appearance==0x193 and target!=null and target.part_type==56:
		e.deactivate(target,"Al ate Fish",a)
		a.target_part=-1
		e.set_vx(a,0)
	if not sid and s==0x37 and a.appearance==0x1cc and a.previous_appearance==0x1cb and target!=null and target.part_type==59:
		# 32F3:3887..38AB: hide the Banana at the bite frame, retaining
		# the object pointer for its later reuse as the emitted peel.
		e.deactivate(target,"Al ate Banana",a)
	if sid and s==0xf and a.appearance==0x53:
		e.set_vx(a,(1 if a.flip_x else -1)*0x600)
		e.set_vy(a,-0x1200)
	# The held E4 frame must not overwrite the terminal Hat Pin launch.
	# HARD7/110, HARD24/100 and LOON5/55 retain -0x3000 in DOS.
	if not sid and s==0x23 and a.appearance==0xe4 and not terminal:
		e.release(a)
		e.set_vy(a,-0x2000)
	if sid and s==0xe and a.appearance>0x4f:
		for o in e.query(a,Rect2i(a.width+25 if a.flip_x else -93,15,68,32),0x1000):
			e.set_vx(o,e.vx(o)+(0x400 if a.flip_x else -0x400))
			e.clamp_velocity(o)
	if not sid and s==0x2a and a.reaction_state<0x6e:
		if a.appearance==0x112: e.set_vy(a,-(40<<9))
		elif a.appearance>0x112: _lift(e,a,0x400)
	if not sid and s==0x2a and a.appearance==0xfe and a.previous_appearance==0xfd and target!=null and target.part_type==54:
		e.deactivate(target,"Al consumed Bubble Gum",a)
		a.target_part=-1
	if not sid and s==0xe and a.appearance==0x69 and a.previous_appearance==0x68:
		e.set_vx(a,-0x400 if a.flip_x else 0x400)
		e.set_vy(a,-0x1000)
	if target!=null and target.part_type==59 and s==(0x34 if sid else 0x37) and a.appearance==(0x1a6 if sid else 0x1d3) and a.previous_appearance==(0x1a5 if sid else 0x1d2):
		target.active=true
		target.flags08&=~0x2000
		target.appearance=4
		a.target_part=-1
		# 32F3:6DFC/382D subtract +4D AND +45 for flipped emission.
		# Refresh the new animation frame before reading its right edge.
		var frame: Rect2i=e.shape_rect(a)
		var right_edge: int=frame.end.x-e.xy(a).x
		e.position(target,e.xy(a)+Vector2i((91 if sid else 45) if not a.flip_x else a.width-right_edge-(91 if sid else 35),15 if sid else 8))
		e.set_vx(target,-0x800 if a.flip_x else 0x800)
		e.set_vy(target,-0xa00)
		e.event("banana_peel",target,{"producer":a.index})

func _custom(e,a: SimulationState.SimPart) -> bool:
	var sid:=a.part_type==37
	var target=e.part(a.target_part)
	var state_id:=a.state
	if not sid and state_id==0x33:
		# 32F3:36B6: startup can return to idle; the subsequent floating
		# phase repeats 63/62 and never runs the generic animation terminal.
		a.reaction_state=K.s16(a.reaction_state+1)
		if a.reaction_state%2==0:
			if a.reaction_state<60:
				a.appearance=tables.u8(0x5f56+K.divide(a.reaction_state,2))+0x1a1
			else:
				_lift(e,a,0x100)
				# Native +3D/+3F is recalculated before the one-time kick.
				a.momentum=((absi(e.vx(a))+absi(e.vy(a)))*a.collision_weight)&0xffffffff
				if a.momentum&0x80000000: a.momentum-=0x100000000
				if a.reaction_state==60:
					if target!=null and target.part_type==52: e.set_vx(a,e.vx(a)+(-0x400 if e.xy(a).x<e.xy(target).x else 0x400))
					e.set_vy(a,e.vy(a)-0x400)
				a.reaction_state=62
		if a.reaction_state<60: e.request(a,0,"Hair-Dryer inflation startup")
		return true
	if not sid and state_id==0x26:
		# 32F3:28F2: half-rate animation, but request idle on EVERY update.
		a.reaction_state=K.s16(a.reaction_state+1)
		if a.reaction_state%2==0:
			if a.reaction_state<26:
				a.appearance=tables.u8(0x5c64+K.divide(a.reaction_state,2))+0xeb
			else: a.reaction_state=0
		e.request(a,0,"Vacuum pull update completed")
		return true
	# 5085/508A/51B1 are genuine empty callbacks, including glass fallback 07.
	if sid and state_id in [6,7,10]: return true
	if state_id==(0xb if sid else 0x18):
		traversal.ladder(e,a,sight)
		return true
	if state_id==0x2d:
		traversal.tunnel(e,a)
		return true
	if not sid and state_id==0x30:
		a.reaction_state+=1
		if a.reaction_state%2==0:
			if a.reaction_state<32: a.appearance=tables.u8(0x60b2+(a.reaction_state>>1))+0x184
			elif sight.scan(e,a)==-1: e.request(a,0,"Yarn sequence no target")
		return true
	if (not sid and state_id in [0x2e,0x2f]) or (sid and state_id==0x2f):
		_pencil(e,a,target,sid)
		return true
	if (sid and state_id==0x14) or (not sid and state_id==0x29):
		_piano(e,a,target,sid)
		return true
	if sid and state_id==0x1d and target!=null and target.part_type==52 and target.trigger_state==0:
		_idle(a)
		return true
	if not sid and state_id==1:
		a.reaction_state+=1
		if a.reaction_state%10==0:
			a.appearance=tables.u8(0x5a12+K.divide(a.reaction_state,10))+1
			if a.reaction_state>79:
				e.sound_effect(a,3016,"32F3:150D")
				a.reaction_state=0
				a.appearance=1
			if e.vy(a)>0xbff: e.request(a,9,"idle falling")
		return true
	if sid and state_id==3:
		if a.reaction_state==0: e.sound_effect(a,3019,"32F3:4F8A")
		a.reaction_state+=1
		if a.reaction_state>=24: e.request(a,0,"idle animation completed")
		elif a.reaction_state%2==0: a.appearance=tables.u8(0x6d03+(a.reaction_state>>1))+5
		return true
	if state_id==0:
		if sid:
			a.reaction_state+=1
			if a.reaction_state>90: e.request(a,0x1f,"Sid idle animation")
			if e.vy(a)>0xc00: e.request(a,5,"falling")
			sight.scan(e,a)
		elif sight.scan(e,a)==-1:
			if e.vy(a)<0xc00:
				a.reaction_state+=1
				if a.reaction_state>179: e.request(a,1,"Al idle animation")
			else: e.request(a,9,"falling")
		return true
	if (sid and state_id==5) or (not sid and state_id==9):
		if sid and a.reaction_state==0: e.sound_effect(a,3051,"32F3:5047")
		if not sid and a.reaction_state==0: e.sound_effect(a,3059,"32F3:1955")
		a.reaction_state+=1
		a.appearance=a.appearance+1 if a.appearance<(15 if sid else 78) else (10 if sid else 67)
		return true
	if sid and state_id==1:
		if a.reaction_state==0: e.sound_effect(a,3023,"32F3:4EB6")
		a.reaction_state+=1
		if a.reaction_state>10:
			a.aux_a5=0x10a
			e.request(a,0,"idle completed")
		return true
	if (sid and state_id in [2,0xc]) or (not sid and state_id in [3,6,0x15]):
		if not (sid and state_id==0xc): a.reaction_state+=1
		if not sid and state_id==3:
			e.set_vx(a,0)
			if a.reaction_state%2!=0: return true
		var base:=2 if sid and state_id==2 else 55 if sid else 14 if state_id==3 else 39 if state_id==6 else 182
		var end:=4 if sid and state_id==2 else 62 if sid else 24 if state_id==3 else 42 if state_id==6 else 185
		var sid_step_wrap: bool=sid and state_id==2 and a.appearance>=4
		var al_step_wrap: bool=not sid and a.appearance>=end
		a.appearance=a.appearance+1 if a.appearance<end else base
		if sid_step_wrap: e.sound_effect(a,13,"32F3:4EF2")
		if al_step_wrap:
			e.sound_effect(a,3003 if state_id==3 else 3041,{3:"32F3:169E",6:"32F3:1743",0x15:"32F3:1DD4"}[state_id])
		var velocity: int=tables.u8(0x6cfe+a.appearance)*2 if sid and state_id==2 else tables.s8(0x6d54+a.appearance) if sid else tables.u8((0x5a6a if state_id==3 else 0x5a5c if state_id==6 else 0x5b47)+a.appearance)
		e.set_vx(a,velocity*512*(-1 if a.flip_x else 1))
		if sid and state_id==0xc and a.appearance in [0x39,0x3d]:
			# 32F3:547C plays bank cue pip at these two frame values.
			e.sound_effect(a,3,"32F3:547C")
		if e.vy(a)>0xc00: e.request(a,5 if sid else 9,"falling from movement")
		if not sid and state_id==0x15 and a.reaction_state<=30: return true
		if sight.scan(e,a)==-1:
			var old_counter:=a.reaction_state
			if sid and state_id==0xc: a.reaction_state+=1
			var limit: int=24 if sid else 20 if state_id==3 else 10
			if (not sid and state_id==0x15) or (old_counter>limit and a.target_part<0):
				e.request(a,(0x23 if state_id==2 else 0) if sid else (0 if state_id==3 else 0x1a),"movement without target")
				e.set_vx(a,0)
		return true
	if not sid and state_id in [0x12,0x13,0x16]:
		if a.reaction_state==0 and state_id!=0x12:
			e.sound_effect(a,3011 if state_id==0x13 else 3061,"32F3:1C07" if state_id==0x13 else "32F3:1E63")
		# 32F3:1BBF calls 0DF3 once on entry: select an impact voice
		# from the original 17-word table using the shared RNG. Audio
		# selection also advances the stream used by Sid's idle choices.
		if state_id==0x12 and a.reaction_state==0:
			var sample: int=tables.u16(0x59e0+(e.state.next_random()%17)*2)
			e.sound_effect(a,sample,"32F3:1BBF -> 0DF3")
		a.reaction_state+=1
		var lo: int={0x12:0x7f,0x13:0x83,0x16:0xba}[state_id]
		var hi: int={0x12:0x82,0x13:0x86,0x16:0xbd}[state_id]
		a.appearance=a.appearance+1 if a.appearance<hi else lo
		if a.reaction_state>int({0x12:18,0x13:9,0x16:20}[state_id]): e.request(a,int({0x12:6,0x13:0,0x16:0x15}[state_id]),"actor movement follow-through")
		if e.vy(a)>0xbff: e.request(a,9,"falling from reaction")
		return true
	if not sid and state_id==0x14:
		if a.reaction_state==0:
			e.set_vx(a,0)
			e.set_vy(a,0)
		a.reaction_state+=1
		if a.reaction_state%2==0:
			if a.reaction_state>>1<107:
				a.appearance=tables.u8(0x5b92+(a.reaction_state>>1))+0x86
				if a.appearance<0x95: _guarded_voice(e,a)
				# 32F3:1C5E compares both current and previous animation frames.
				if a.appearance==0x9f and a.previous_appearance==0x9e: e.sound_effect(a,3042,"32F3:1C5E")
				if a.appearance==0xa1 and a.previous_appearance==0x9e: e.sound_effect(a,3044,"32F3:1C5E")
				if a.appearance==0xa4 and a.previous_appearance==0xa3: e.sound_effect(a,8,"32F3:1C5E")
				if a.appearance==0xab and a.previous_appearance==0xaa: e.sound_effect(a,3073,"32F3:1C5E")
				if a.appearance==0xad and a.previous_appearance==0xac: e.sound_effect(a,3043,"32F3:1C5E")
				if a.appearance==0xae and a.previous_appearance==0xac: e.sound_effect(a,3073,"32F3:1C5E")
				if a.appearance==0xb1: e.sound_effect(a,3013,"32F3:1C5E")
				if a.appearance==0xb5: e.sound_effect(a,3035,"32F3:1C5E")
			else: _idle(a)
		return true
	if not sid and state_id==0x10:
		if a.reaction_state==0:
			a.target_part=-1
			e.set_vy(a,0)
			a.settings=-1
		e.set_vx(a,0)
		a.reaction_state+=1
		if a.reaction_state<69:
			var selector:=tables.s8(0x5af0+a.reaction_state)
			if selector!=a.settings:
				a.appearance=tables.s8(selector*3+0x5b37)+0x6f
				e.set_vx(a,e.vx(a)+(tables.s8(selector*3+0x5b35)<<9)*(-1 if a.flip_x else 1))
				e.set_vy(a,e.vy(a)+(tables.s8(selector*3+0x5b36)<<9))
				a.settings=selector
				# 32F3:1993 dispatches these sounds only when the selector changes.
				match selector:
					2: e.sound_effect(a,3061,"32F3:1993")
					0x12: e.sound_effect(a,3039,"32F3:1993")
					0x1b: e.sound_effect(a,3017,"32F3:1993")
		elif a.reaction_state==69:
			var clone=e.spawn(36,e.xy(a),Vector2i.ZERO,a.flip_x,0x4000)
			if clone!=null:
				clone.state=0x11
				clone.appearance=0x7c
				clone.trigger_state=0
				clone.collision_enabled=false
				e.world.frame_geometry(clone) # 32F3:1B10 after setting ghost appearance.
				a.target_part=clone.index
		return true
	if not sid and state_id==0x11:
		a.reaction_state+=1
		if a.reaction_state%3==0:
			# Original 1B44 reads DS:4707 (view Y), before ghost displacement.
			if a.appearance>=0x7e and e.xy(a).y>e.state.dos_view_origin.y-100:
				e.sound_effect(a,3012,"32F3:1B1A")
			a.appearance=a.appearance+1 if a.appearance<0x7e else 0x7c
			# 32F3:1B67/1B7E read near DS567F, unlike the far440F animation
			# tables. These signed offsets lift the angel independently of VX/VY.
			var motion: Array=tables.metadata.al_ghost_displacements[a.appearance-0x7c]
			e.position(a,e.xy(a)+Vector2i(int(motion[0]),int(motion[1])))
			e.world.frame_geometry(a) # 32F3:1BB8 after each ghost animation step.
		return true
	if not sid and state_id==0x17:
		if a.reaction_state==0:
			e.sound_effect(a,3052,"32F3:1EBA")
			e.set_vx(a,0)
			e.set_vy(a,0)
			a.aux_a5=-1
		a.reaction_state+=1
		if a.reaction_state<32:
			var bytes: Array=tables.metadata.al_rebound_triplets
			var index:=a.reaction_state*3
			a.appearance=_signed_byte(int(bytes[index+2]))+0xbd
			e.set_vx(a,(_signed_byte(int(bytes[index]))<<9)*(-1 if a.flip_x else 1))
			e.set_vy(a,(_signed_byte(int(bytes[index+1]))<<9)*(-1 if a.flip_x else 1))
		else:
			e.request(a,0x16,"Al rebound completed")
			e.face(a,not a.flip_x)
		return true
	if not sid and state_id==0x27:
		a.reaction_state+=1
		if a.reaction_state%2==0:
			if e.vy(a)>0xc00: e.request(a,9,"falling from suction")
			else:
				if sight.scan(e,a)==-1: e.request(a,0,"suction recovery no target")
				if a.reaction_state>>1>31: a.reaction_state=0
				var index: int=a.reaction_state>>1
				a.appearance=tables.s8(0x5c73+index*3)+0xee
				e.set_vx(a,(tables.s8(0x5c71+index*3)<<9)*(-1 if a.flip_x else 1))
		return true
	if sid and state_id==0x18:
		if a.reaction_state==0:
			# 32F3:5C2A's raw 3103 dispatch is state-entry only.
			e.sound_effect(a,3103,"32F3:5C2A")
		a.reaction_state+=1
		if a.reaction_state%2==0:
			if a.reaction_state<6: a.appearance=tables.u8(0x6f57+(a.reaction_state>>1))+0x8a
			else: e.request(a,0,"side impact completed")
		return true
	if sid and state_id==0x19:
		a.reaction_state+=1
		if e.vy(a)>0xc00: e.request(a,5,"falling after boost")
		if a.reaction_state>5: e.request(a,0x1f,"boost follow-through")
		return true
	if (sid and state_id in [0x2c]) or (not sid and state_id==0x28):
		e.request(a,0,"physical transient completed")
		return true
	if not sid and state_id==0x38:
		# Rug keeps Al in its wrapped state; the Rug updater carries geometry.
		# DOS 32F3:39CD: sound gate is a zero-to-one latch.
		if a.reaction_state==0:
			e.sound_effect(a,3059,"32F3:39CD")
			a.reaction_state=1
		return true
	return false

func _idle(a: SimulationState.SimPart) -> void:
	a.state=0
	a.trigger_state=0
	a.appearance=0
	a.reaction_state=0

static func _signed_byte(value: int) -> int:
	return value-256 if value>=128 else value

func _piano(e,a: SimulationState.SimPart,target,sid: bool) -> void:
	if target==null or target.part_type!=60:
		e.release(a)
		e.request(a,0,"Piano removed")
		return
	a.collision_enabled=false
	if target.appearance!=7:
		if a.reaction_state==0:
			# 32F3:2B19/5AB3 rewrite Y and its previous pixel only. X can
			# still contain a collision remainder when the Piano catches an actor.
			var next_y:=K.s16(e.xy(a).y+(7 if sid else 18))
			a.y_fixed=next_y<<15
			a.previous_position.y=next_y
			a.reaction_state=1
	else:
		a.reaction_state+=1
		if sid or a.reaction_state%2==0:
			var index: int=a.reaction_state if sid else a.reaction_state>>1
			if index>(38 if sid else 40):
				e.deactivate(a,"Piano crush animation completed",target)
				return
			var base: int=0x6ed7 if sid else 0x5cd1
			a.appearance=tables.s8(base+index*3+2)+(0x7e if sid else 0xf6)
			e.position(a,e.xy(target)+Vector2i(tables.s8(base+index*3)-18,tables.s8(base+index*3+1)+20))
	# Native normal returns cancel even impulses received during a held frame.
	# The deactivation above returns before these writes in both callbacks.
	e.set_vx(a,0)
	e.set_vy(a,0)

func _pencil(e,a: SimulationState.SimPart,target,sid: bool) -> void:
	# These are scripted regions inside a contact-triggered sequence, not the
	# general sight/attraction helpers 0E5E/4906.
	if not sid and a.state==0x2f:
		if a.reaction_state==0:
			if target==null or target.part_type!=37 or e.xy(target).y<=e.xy(a).y or e.xy(target).y>=e.xy(a).y+20:
				_idle(a)
				return
			e.deactivate(target,"Al physical sequence",a)
			e.freeze(a)
		a.reaction_state+=1
		if a.reaction_state<32:
			a.appearance=tables.u8(0x5ed9+a.reaction_state)+0x178
			if a.appearance==0x17c: e.sound_effect(a,3075,"32F3:33AB")
		else:
			e.release(a)
			e.request(a,0x31,"Al physical sequence completed")
			if target!=null and target.part_type==37:
				target.active=true
				target.flags08&=~0x2000
				target.trigger_state=0x33
				e.position(target,e.xy(a)+Vector2i(0,15))
		return
	if a.reaction_state==0:
		if sid: e.sound_effect(a,3041,"32F3:69E0")
		e.set_vx(a,0)
		e.set_vy(a,0)
		var candidate=null
		for other in e.query(a,Rect2i(-600,0,e.shape_rect(a).size.x+1200,e.shape_rect(a).size.y),0x1000):
			if other.part_type==(36 if sid else 37) and (sid or absi(e.vy(other))<0x200):
				candidate=other
				break
		if candidate!=null:
			if not sid and target!=null and target.part_type==64: e.deactivate(target,"Al Pencil reaction",a)
			a.target_part=candidate.index
			target=candidate
			if not sid:
				target.state=4
				target.trigger_state=4
				target.appearance=8
				target.reaction_state=0
				e.set_vx(target,0)
				e.face(target,e.xy(a).x>=e.xy(target).x)
			e.face(a,e.xy(target).x<e.xy(a).x if not sid else e.xy(a).x<e.xy(target).x)
		elif not sid:
			_idle(a)
			return
	a.reaction_state+=1
	if not sid and a.reaction_state<10:
		a.appearance=tables.u8(0x5ecf+a.reaction_state)+0x175
		if a.appearance==0x178: e.sound_effect(a,3010,"32F3:3161")
		return
	if target==null or target.part_type!=(36 if sid else 37):
		if sid:
			a.state=0x31
			a.trigger_state=0x31
			a.appearance=0x17b
			a.reaction_state=0
		else: _idle(a)
		return
	var target_x: int=e.xy(target).x+(target.width>>1)
	var actor_x: int=e.xy(a).x+(a.width>>1)
	if absi(actor_x-target_x)<(56 if sid else 81):
		e.request(a,0x30 if sid else 0x2f,"Pencil sequence contact range")
		e.set_vx(a,0)
		if not sid:
			if a.reaction_state%2!=0: e.position(a,e.xy(a)+Vector2i(0,8))
			e.set_vy(a,0)
	else:
		e.set_vx(a,-0x2000 if target_x<actor_x else 0x2000)
		if sid: a.appearance=0x157 if a.appearance==0x156 else 0x156
		else: e.position(a,e.xy(a)+Vector2i(0,-8 if a.reaction_state%2==0 else 8))
