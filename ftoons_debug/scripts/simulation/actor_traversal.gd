class_name ActorTraversal
extends RefCounted

## 5D2D:008C/0180; actor handlers 1F94/51B6/2E97/65D6.
const K = preload("res://scripts/simulation/bearing_physics.gd")

func floor_row(e,a,l,down: bool,ordinal: int) -> int:
	if l==null or l.part_type!=45: return -1
	var ap: Vector2i=e.xy(a)
	var lp: Vector2i=e.xy(l)
	var ls: Vector2i=e.frame_size(l)
	var region:=Rect2i(lp.x-ap.x-8,0 if down else lp.y-ap.y,ls.x+16,lp.y-ap.y+ls.y+8 if down else ap.y-lp.y)
	if down and ordinal==1: ordinal=2
	var count:=0
	var last=null
	for o in e.query(a,region,0x2000):
		if o.part_type!=0:
			if o.part_type not in [26,27,28,29,82,83]: continue
			if e.frame_size(o).x<e.frame_size(o).y: continue
		count+=1
		last=o
		if count==ordinal: break
	if last==null: return 0x1f
	a.traversal_af=(a.traversal_af&~0x80)|(0x80 if e.xy(last).x<=lp.x else 0)
	return e.xy(last).y>>4

func enter_ladder(e,a) -> void:
	var l=e.part(a.target_part)
	var sid: bool=a.part_type==37
	if l==null or l.part_type!=45:
		a.appearance=0
		e.request(a,0,"missing Ladder")
		return
	if a.aux_a5>>8==(0xb if sid else 0x18): return
	var x: int=e.xy(l).x+(0 if not a.flip_x else l.width-a.width) if sid else e.xy(l).x+K.divide(l.width-a.width,2)
	# Entry aligns X only (32F3:45DF); retain the existing Q9 Y fraction
	# until the first actual climbing movement writes a new integer Y.
	a.x_fixed=x<<15
	a.previous_position.x=x
	e.freeze(a)
	a.traversal_af=0x40 if e.xy(a).y+(e.frame_size(a).y>>1)<e.xy(l).y+(e.frame_size(l).y>>1) else 0
	if a.flip_x: a.traversal_af|=0x80
	if sid: a.traversal_af^=0x80
	var running: bool=a.state==(2 if sid else 6)
	if running: a.traversal_af|=0x20
	a.traversal_af|=floor_row(e,a,l,bool(a.traversal_af&0x40),1 if running else 99)
	if a.traversal_af&0x1f==0x1f:
		_reverse(e,a,l)
		if a.traversal_af&0x1f==0x1f:
			a.traversal_af^=0x40
			if not a.traversal_af&0x40: a.traversal_af&=~0x1f
	a.appearance=0x34 if sid else 0xc2

func _reverse(e,a,l) -> void:
	a.traversal_af=(a.traversal_af^0x40)&~0x1f
	a.traversal_af|=floor_row(e,a,l,bool(a.traversal_af&0x40),1)

func _reverse_at_end(e,a,l) -> void:
	_reverse(e,a,l)
	if not a.traversal_af&0x40 and a.traversal_af&0x1f==0x1f: a.traversal_af&=~0x1f

func ladder(e,a,sight) -> void:
	var l=e.part(a.target_part)
	if l==null or not l.active or l.part_type!=45:
		e.release(a)
		e.request(a,0,"Ladder removed")
		return
	var sid: bool=a.part_type==37
	a.reaction_state+=1
	if a.reaction_state%2!=0: return
	if a.reaction_state==8: a.reaction_state=0
	# 32F3:1F94/51B6 use the preceding +4F for the ladder-end check,
	# then refresh geometry before the floor-exit test. frame_size() writes
	# the new sprite bounds, so querying it after changing appearance reverses
	# actors early when the next climbing frame is shorter (BRAN1's third ladder).
	var prior_height: int=a.frame_size.y if e.world!=null else e.frame_size(a).y
	var index: int=a.reaction_state>>1
	var base: int=(0x6d80 if a.traversal_af&0x40 else 0x6d74) if sid else (0x5c09 if a.traversal_af&0x40 else 0x5c01)
	base+=index*(3 if sid else 2)
	a.appearance=e.tables.s8(base+1)+(0x34 if sid else 0xc2)
	e.position(a,e.xy(a)+Vector2i(0,e.tables.s8(base)))
	# 32F3:1F94 -> 2043 emits Al's ladder step before testing its ends.
	# Sid's separate 51B6 cue follows the geometry refresh below.
	if not sid and a.appearance in [0xc2,0xc4]: e.sound_effect(a,5,"32F3:1F94")
	var cy: int=e.xy(a).y+(prior_height>>1)
	if cy<e.xy(l).y or cy>e.xy(l).y+e.frame_size(l).y:
		e.position(a,Vector2i(e.xy(a).x,a.previous_position.y))
		_reverse_at_end(e,a,l)
	var row: int=e.xy(a).y>>4
	var desired: int=(a.traversal_af&0x1f)-(e.frame_size(a).y>>4)
	if sid and a.appearance in [0x34,0x36]: e.sound_effect(a,5,"32F3:51B6")
	if row==desired or row==desired+1:
		a.target_part=-1
		e.face(a,not bool(a.traversal_af&0x80) if sid else bool(a.traversal_af&0x80))
		e.position(a,Vector2i(e.xy(a).x,(a.traversal_af&0x1f)*16-a.height+5))
		a.previous_position=e.xy(a)
		a.older_position=e.xy(a)
		a.aux_a5=0xb0a if sid else 0x180f
		a.reaction_state=0
		e.release(a)
		var next: int=sight.scan(e,a)
		if next==-1: next=(2 if a.traversal_af&0x20 else 0xc) if sid else (6 if a.traversal_af&0x20 else 3)
		elif not sid and next==0x12: next=6
		a.state=next
		a.trigger_state=next
		a.appearance=absi(int(e.tables.actor(a.part_type,next).get("initial_frame",0)))
		e.event("ladder_exit",a,{"state":next,"floor_row":a.traversal_af&0x1f})
	elif (a.traversal_af&0x40 and row>desired) or (not a.traversal_af&0x40 and row<desired):
		_reverse_at_end(e,a,l)

func tunnel(e,a) -> void:
	var entrance=e.part(a.target_part)
	var exit_part=e.part(entrance.target_part) if entrance!=null else null
	if entrance==null or entrance.part_type!=46 or exit_part==null or exit_part.part_type!=46 or not exit_part.active:
		e.release(a)
		e.request(a,0,"unpaired Tunnel")
		a.target_part=-1
		return
	var sid: bool=a.part_type==37
	if a.reaction_state==0:
		var delta: Vector2i=e.xy(entrance)-e.xy(exit_part)
		a.scratch61=(absi(delta.x)+absi(delta.y))>>1
		if sid: e.position(a,e.xy(entrance)+Vector2i(36-a.width if a.flip_x else 16,20))
		e.freeze(a)
	a.reaction_state+=1
	# Preserve phase computed BEFORE the hold counter is changed (original C).
	var phase: int=a.reaction_state>>1
	if phase==(54 if sid else 71):
		if a.scratch61==0:
			a.reaction_state=110 if sid else 144
			var x: int=(42-a.width if a.flip_x else 10) if sid else (-2 if a.flip_x else 10)
			e.position(a,e.xy(exit_part)+Vector2i(x,10 if sid else 12))
			# Al (32F3:2E97) commits previous coordinates here; Sid (65D6) does not.
			if not sid: a.previous_position=e.xy(a)
		else:
			a.reaction_state=108 if sid else 142
			a.scratch61-=1
			e.position(a,Vector2i(1000,1000))
			a.previous_position=Vector2i(1000,1000)
			if sid and a.scratch61==35:
				e.sound_effect(a,3115,"32F3:65D6")
			elif not sid and a.scratch61 in [35,70]:
				var sound_id: int=e.tables.u16(0x5a02+(e.state.next_random()&7)*2)
				e.sound_effect(a,sound_id,"32F3:2E97 -> 0E2C")
	if a.reaction_state%2!=0: return
	if phase<(94 if sid else 93):
		if sid:
			a.appearance=e.tables.s8(0x71a9+phase*3)+0x130
			e.position(a,e.xy(a)+Vector2i(e.tables.s8(0x71a7+phase*3)*(-1 if a.flip_x else 1),e.tables.s8(0x71a8+phase*3)))
			match a.appearance:
				0x134:
					if a.previous_appearance==0x133: e.sound_effect(a,3055,"32F3:65D6")
				0x138,0x147: e.sound_effect(a,3010,"32F3:65D6")
				0x140:
					if a.previous_appearance==0x13f: e.sound_effect(a,5,"32F3:65D6")
				0x144: e.sound_effect(a,3105,"32F3:65D6")
		else:
			a.appearance=e.tables.u8(0x5e72+phase)+0x151
			match a.appearance:
				0x155:
					if a.previous_appearance==0x154: e.sound_effect(a,3044,"32F3:2E97")
				0x159: e.sound_effect(a,3069,"32F3:2E97")
				0x15c: e.sound_effect(a,5,"32F3:2E97")
				0x163: e.sound_effect(a,3010,"32F3:2E97")
				0x168: e.sound_effect(a,3043,"32F3:2E97")
				0x16a:
					if a.previous_appearance==0x168: e.sound_effect(a,3017,"32F3:2E97")
				0x16c: e.sound_effect(a,3003,"32F3:2E97")
				0x16e: e.sound_effect(a,3102,"32F3:2E97")
				0x171: e.sound_effect(a,3024,"32F3:2E97")
	else:
		e.release(a)
		a.state=0xc if sid else 3
		a.trigger_state=a.state
		a.appearance=0x37 if sid else 0xe
		a.reaction_state=0
		a.target_part=-1
		a.aux_a5=0x2d0f if sid else 0x2d14
		e.event("tunnel_exit",a,{"entrance":entrance.index,"exit":exit_part.index})
