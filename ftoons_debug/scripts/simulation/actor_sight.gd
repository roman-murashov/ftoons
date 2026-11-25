class_name ActorSight
extends RefCounted

## 32F3:0E5E/1075/4906/4B7E/74A8 and 79CC helpers.
## State numbers are hexadecimal; type numbers are decimal. See SIGHT_BEHAVIORS_ANALYSIS.

static func live(p) -> bool:
	return p!=null and p.active and p.placed and not p.flags08&0x2000

func blocked(e,a,o) -> bool:
	var ar: Rect2i=e.shape_rect(a)
	var r: Rect2i=e.shape_rect(o)
	if e.xy(a).y>=r.end.y-10 or e.xy(o).y>=ar.position.y+a.height-10: return false
	if o.flags&0x2000: return o.part_type not in [15,30,45,46,63]
	return o.part_type in [6,36,37,60,61] or (o.part_type==59 and o.appearance!=4)

func scan(e,a: SimulationState.SimPart) -> int:
	# The DOS counter starts at zero. Runner increments tick before calling us.
	if e.state.tick<3 or absi(e.vy(a)>>9)>=2 or e.xy(a).y!=a.older_position.y: return -1
	var sid:=a.part_type==37
	var old=e.part(a.target_part)
	var retained:=false
	if live(old):
		if not sid: retained=old.part_type==37 and a.state!=0
		elif old.part_type==36:
			if old.state in [3,6,0xe,0x12,0x27]:
				retained=true
				if a.aux_a5>>8==1 or a.state==2:
					if a.state!=2: e.face(a,not a.flip_x)
					e.request(a,2,"retained Al threat",old)
				else: e.request(a,1,"retained Al threat",old)
			else:
				a.target_part=-1
				e.request(a,0x23 if a.state==2 else 0,"Al no longer threatening")
	var mirror:=a.flip_x
	var left_open:=true
	var right_open:=true
	var actor_center: int=e.shape_rect(a).position.x+(a.width>>1)
	var rows: Array[Dictionary]=e.query_details(a,Rect2i(-600,0,a.width+1200,a.height))
	for row in rows:
		var o: SimulationState.SimPart=row.part
		if retained and o.part_type not in ([30,45,46] if sid else [30,37,45,46]): continue
		var other_center: int=e.center(o).x
		var value: int=-1
		if actor_center<other_center and right_open:
			value=decision(e,a,o,int(row.dx),rows)
			if blocked(e,a,o): right_open=false
		elif other_center<actor_center and left_open:
			value=decision(e,a,o,int(row.dx),rows)
			if blocked(e,a,o): left_open=false
		if value>=0:
			a.target_part=o.index
			# Test the pre-decision mirror, but toggle the CURRENT mirror. Hazard
			# decisions already toggled it. Assigning 'face target' loses that.
			var turn: bool=(actor_center<e.xy(o).x if not mirror else e.xy(o).x<actor_center) if sid else (e.xy(o).x<e.xy(a).x if not mirror else e.xy(a).x<e.xy(o).x)
			if turn: e.face(a,not a.flip_x)
			e.request(a,value,"sight",o,true)
			return value
	if not retained:
		old=e.part(a.target_part)
		if live(old):
			if e.xy(old).y>=e.xy(a).y+a.height or e.xy(a).y>=e.xy(old).y+old.height:
				a.target_part=-1
				var stop: int=(0x23 if a.state==2 else 0) if sid else (0x1a if a.state in [6,0x15] else 0)
				e.request(a,stop,"sight target left vertical span")
				return stop
		else: a.target_part=-1
	return -1

func decision(e,a,o,dx: int,rows: Array[Dictionary]=[]) -> int:
	var sid: bool=a.part_type==37
	var ap: Vector2i=e.xy(a)
	var op: Vector2i=e.xy(o)
	var os: Vector2i=e.frame_size(o)
	var cooldown: int=a.aux_a5>>8
	match o.part_type:
		36:
			if not sid: return -1
			if o.state==0: return 4 if cooldown!=4 else -1
			if o.state in [4,5,9,0x11,0x15,0x16]: return 3 if cooldown!=3 else -1
			if o.state in [3,6,0x12] and a.state!=2 and ((op.x<ap.x and not o.flip_x) or (ap.x<op.x and o.flip_x)):
				if cooldown!=1: return 1
				e.face(a,not a.flip_x)
				return 2
		37:
			if not sid: return _al_sees_sid(e,a,o,dx)
		7:
			if not sid:
				if absi(ap.x+(a.width>>1)-op.x-(o.width>>1))<=80: return 0xe if a.state==0x30 else 0x30
				return 3
		54: return 0xc if sid else 3
		56: return -1 if sid else 3
		57: return 0xc if sid else -1
		59:
			if o.appearance!=4: return 0xc if sid else 3
		16:
			if o.appearance==0 and ((ap.x>op.x and not o.flip_x) or (ap.x<op.x+os.x and o.flip_x)): return 0xc if sid else 3
		19,20,35:
			if o.appearance==0: return -1
			if o.part_type!=20 and absi(dx)>=60: return -1
			if o.part_type==35:
				if not sid and o.appearance>4: return -1
				if not ((ap.x>op.x and o.flip_x) or (ap.x<op.x and not o.flip_x)): return -1
			if o.part_type==20 and not ((ap.x>op.x and not o.flip_x) or (ap.x<op.x and o.flip_x)): return -1
			if sid: return 1
			e.face(a,not a.flip_x)
			return 0x15 if a.state==0x15 else 0x16
		30: return _glass_sid(e,o,a,rows) if sid else _glass_al(e,o,a)
		45:
			var climb: int=0xb if sid else 0x18
			if cooldown==climb or a.state==climb: return -1
			if ap.y+a.height<op.y or op.y+os.y<ap.y: return -1
			if sid:
				if ap.x+a.width<op.x or op.x+os.x<ap.x: return -1
			elif ap.x+(a.width>>1)<op.x or op.x+os.x<ap.x+(a.width>>1): return -1
			return climb
		46:
			if cooldown==0x2d: return -1
			var enter: bool=op.y+15<ap.y and ap.y<op.y+25 and op.x<ap.x and ap.x<op.x+o.width if sid else op.y<ap.y and ap.y<op.y+20 and ((op.x-30<ap.x and ap.x<op.x) if not a.flip_x else (op.x+20<ap.x and ap.x<op.x+40))
			if enter:
				a.traversal_af=a.state
				if sid: a.target_part=o.index
				return 0x2d
	return -1

func _al_sees_sid(e,a,s,dx: int) -> int:
	if s.state in [8,9,11,15,18,19,20,26,28,29,42,43,44,45,46,47,48,49,51,52]: return -1
	if s.state in [3,4] and s.reaction_state>15:
		if (dx>=0 or not s.flip_x) and (dx<=0 or s.flip_x):
			e.face(a,not a.flip_x)
			return 0x12
		if absi(dx)<80: return 0xe
		return 6 if a.state==6 else 0x12
	if s.state in [2,38,39,40,41,50] and ((dx<0 and not s.flip_x) or (dx>0 and s.flip_x)):
		if absi(dx)<35: return 0xe
		return 6 if a.state==6 else 0x12
	if s.state in [1,21,22,23,24,35] and absi(dx)<80: return 0xe
	return 0xe if s.reaction_state>=16 and absi(dx)<80 else -1

func _glass_al(e,g,a) -> int:
	var distance: int=e.center(a).x-e.center(g).x
	return 0x17 if ((g.appearance==1 and distance< -35 and distance> -400) or (g.appearance==2 and distance>35 and distance<400)) else -1

func _glass_sid(e,g,s,rows: Array[Dictionary]) -> int:
	var sx: int=e.xy(s).x+(s.width>>1)
	var gx: int=e.xy(g).x+(g.width>>1)
	if absi(sx-gx)<35 or absi(sx-gx)>125: return -1
	for row in rows:
		var a: SimulationState.SimPart=row.part
		if a.part_type!=36 or a.state in [1,2,4,7,9,15,16,17,20,21,22,23]: continue
		var ax: int=e.xy(a).x+(a.width>>1)
		if (ax<gx and sx<gx) or (ax>gx and sx>gx) or absi(ax-gx)<35: return -1
		if absi(ax-gx)<=400:
			if g.aux_a5==0:
				e.request(g,2 if sx<gx else 1,"magnified Sid image",s,true)
				return 4
			if s.state==7: return -1
		return 7
	return -1

func magnifier(e,g: SimulationState.SimPart) -> void:
	var sid=e.part(g.target_part)
	if g.trigger_state!=0 and sid!=null and sid.state==4 and g.appearance==0 and g.aux_a5==0:
		g.appearance=g.trigger_state
		g.reaction_state=15
		g.aux_a5=30
		g.trigger_state=0
		g.target_part=-1
		e.event("magnified_image",g,{"frame":g.appearance})
	if g.reaction_state==0:
		if g.aux_a5!=0:
			g.aux_a5-=1
			if g.aux_a5==0: g.trigger_state=0
	else:
		g.reaction_state-=1
		if g.reaction_state==0: g.appearance=0

func elephant_acquire(e,p: SimulationState.SimPart) -> bool:
	var size_value: Vector2i=e.frame_size(p)
	var region:=Rect2i(0,0,size_value.x+200,size_value.y) if p.flip_x else Rect2i(-200,0,200,size_value.y)
	for o in e.query(p,region,0x1000):
		if o.part_type==37 and ((e.xy(p).x<e.xy(o).x) if p.flip_x else (e.xy(o).x<e.xy(p).x)):
			e.face(p,not p.flip_x)
			p.state=4
		elif o.part_type==58:
			p.state=2
			if (e.xy(o).x<e.xy(p).x and p.flip_x) or (e.xy(p).x<e.xy(o).x and not p.flip_x): e.face(p,not p.flip_x)
		else: continue
		p.reaction_state=0
		e.event("Eunice_sight",p,{"target":o.index,"state":p.state})
		return true
	return false
