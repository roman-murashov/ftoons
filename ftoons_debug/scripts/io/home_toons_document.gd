extends RefCounted
## Authored data only: no scripts, heap pointers or running simulation state.
const FORMAT := "sid-and-al-home-toons"
const VERSION := 2
const AuthoredGoals = preload("res://scripts/simulation/authored_goals.gd")
const Paths := preload("res://scripts/io/portable_paths.gd")
const FIELDS := ["part_type","flags_1","flags_2","flags_3","appearance","unknown_10","width_1","height_1","width_2","height_2","pos_x","pos_y","behavior","wire_terminal","belt_connect_pos_x","belt_connect_pos_y","belt_line_distance","rope_1_connect_pos_x","rope_1_connect_pos_y","rope_2_connect_pos_x","rope_2_connect_pos_y","connected_1","connected_2","outlet_plugged_1","outlet_plugged_2","tunnel_partner"]
const LINKS := ["connected_1","connected_2","outlet_plugged_1","outlet_plugged_2","tunnel_partner"]
var error := ""
static var _part_id_pattern := RegEx.create_from_string("\\A[A-Za-z0-9_-]{1,64}\\z")
static var _templates := {}
static var _construction_rows := {}

static func default_folder() -> String:
	return Paths.profile().path_join("user_levels")

static func templates() -> Dictionary:
	if _templates.is_empty():
		var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/original/dos_home_editor.json"))
		for row in data.templates: _templates[int(row.part_type)] = row
	return _templates

static func factory(type_id: int) -> PartDefinition:
	var rows:=templates()
	if not rows.has(type_id): return null
	var d:=PartDefinition.new()
	for key in rows[type_id]: d.set(key,int(rows[type_id][key]))
	# Native bin templates omit mover-list membership. Retain the bin bit
	# until placement, but restore the object's stage scheduling category.
	if (d.flags_1&0x6000)==0: d.flags_1|=0x1000
	d.construction_context="home_toons"
	return d

static func factory_row(type_id: int, id: String) -> Dictionary:
	if not _construction_rows.has(type_id):
		var definition := factory(type_id)
		if definition == null: return {}
		var template := {}
		for key in FIELDS: template[key] = definition.get(key)
		template.flags_1 = int(template.flags_1) & ~0x800
		_construction_rows[type_id] = template
	var row: Dictionary = _construction_rows[type_id].duplicate()
	row.id = id
	return row

static func capture(runner: SimulationRunner, include_inventory: bool=false) -> Dictionary:
	var doc: Dictionary={"format":FORMAT,"version":VERSION,"title":runner.puzzle.title,"goal":runner.puzzle.instructions,
		"goals":runner.puzzle.authored_goals.duplicate(true),
		"music":runner.puzzle.music,"gravity":runner.puzzle.gravity,"pressure":runner.puzzle.pressure,"parts":[],"ropes":[],"belts":[]}
	if runner.puzzle.construction_context == "campaign" and (runner.puzzle.campaign_goal_index >= 0 or not runner.puzzle.head_to_head_goal.is_empty()):
		doc.goals = {"version": 1, "original": runner.puzzle.source_name.to_upper()}
	var ids: Dictionary={}
	for p in runner.state.parts:
		if p.active and not p.spawned and (p.placed or include_inventory): ids[p.index]=ids.size()
	for p in runner.state.parts:
		if not ids.has(p.index): continue
		if p.definition.goal_id.is_empty(): runner.puzzle.assign_goal_id(p.definition)
		var row: Dictionary={"id": p.definition.goal_id}
		for key in FIELDS: row[key]=p.definition.get(key)
		row.merge({"pos_x":p.x_fixed>>15,"pos_y":p.y_fixed>>15,"width_1":p.width,"height_1":p.height,
			"width_2":p.stored_extent.x,"height_2":p.stored_extent.y,"appearance":p.appearance,
			"flags_1":p.flags&~0x800,"flags_2":(p.flags08&~0x30)|(0x10 if p.flip_x else 0)|(0x20 if p.flip_y else 0),
			"flags_3":p.flags0a,"wire_terminal":p.authored_settings,"rotation":p.rotation,
			"mirror_x":p.editor_mirror_x,"mirror_y":p.editor_mirror_y},true)
		for slot in 4: row[LINKS[slot]]=ids.get(p.links[slot],-1)
		row.tunnel_partner=ids.get(p.target_part if p.part_type==46 else p.definition.tunnel_partner,-1)
		# Static attachment offsets must follow the current native facing.
		var anchors: Array=RopePhysics.anchors(p)
		for slot in 2:
			row["rope_%d_connect_pos_x"%(slot+1)]=anchors[slot].x
			row["rope_%d_connect_pos_y"%(slot+1)]=anchors[slot].y
		doc.parts.append(row)
	for rope in runner.state.ropes:
		if not ids.has(int(rope.owner)): continue
		var route: Array=[]
		for id in rope.route:
			if ids.has(int(id)): route.append(ids[int(id)])
		if route.size()==rope.route.size(): doc.ropes.append({"owner":ids[int(rope.owner)],"route":route,"slots":rope.slots.duplicate()})
	for belt in runner.state.belts:
		if ids.has(int(belt.owner)) and ids.has(int(belt.ends[0])) and ids.has(int(belt.ends[1])):
			doc.belts.append({"owner":ids[int(belt.owner)],"ends":[ids[int(belt.ends[0])],ids[int(belt.ends[1])]]})
	return doc

static func placed_goal_targets(runner: SimulationRunner) -> Dictionary:
	var result := {}
	for part in runner.state.parts:
		if part.active and part.placed and not part.spawned:
			if part.definition.goal_id.is_empty(): runner.puzzle.assign_goal_id(part.definition)
			result[part.definition.goal_id] = part.part_type
	return result

func decode(doc: Variant, source: String, editor: bool=true) -> PuzzleDefinition:
	error="Invalid Home Toons JSON document."
	if not doc is Dictionary or doc.get("format")!=FORMAT or not _integer(doc.get("version"),1,VERSION): return null
	var legacy := int(doc.version) == 1
	if legacy and doc.has("goals"):
		error = "Structured goals require Home Toons version 2."
		return null
	if not doc.get("parts") is Array or doc.parts.size()>1024: return null
	if not doc.get("title") is String or not doc.get("goal") is String: return null
	if doc.title.length()>255 or doc.goal.length()>4096: return null
	for key in ["music","gravity","pressure"]:
		if not _integer(doc.get(key),0,65535): return null
	var result:=PuzzleDefinition.new()
	result.source_name=source
	result.name=source.get_file().get_basename()
	result.title=doc.title
	result.instructions=doc.goal
	result.music=int(doc.music)
	result.gravity=int(doc.gravity)
	result.pressure=int(doc.pressure)
	result.construction_context="home_toons" if editor else "campaign"
	result.authored_logical_extents=true
	result.magic="JSON v%d" % int(doc.version)
	var allowed:=templates()
	var part_ids := {}
	for row in doc.parts:
		if not row is Dictionary: return null
		for key in FIELDS:
			if not _integer(row.get(key),-32768,65535): return null
		if not allowed.has(int(row.part_type)): return null
		if row.width_1<0 or row.width_1>640 or row.height_1<0 or row.height_1>400: return null
		for key in LINKS:
			if row[key]<-1 or row[key]>=doc.parts.size(): return null
		if not _integer(row.get("rotation",0),0,3): return null
		var d:=PartDefinition.new()
		if legacy:
			result.assign_goal_id(d)
		else:
			var id: Variant = row.get("id")
			if not id is String or _part_id_pattern.search(id) == null or part_ids.has(id):
				error = "Part %d needs a unique id of 1–64 letters, digits, underscores or hyphens." % (result.parts.size() + 1)
				return null
			result.assign_goal_id(d, id)
		for key in FIELDS: d.set(key,int(row[key]))
		part_ids[d.goal_id] = d.part_type
		# Repair early editor JSONs saved without the mover-list flag.
		# Preserve fixed/frozen categories and pin state independently.
		if (d.flags_1&0x7000)==0: d.flags_1|=0x1000
		d.list_index=result.parts.size()
		d.construction_context=result.construction_context
		d.campaign_rope_inventory=d.part_type==14 and not (d.flags_3&0x40)
		result.parts.append(d)
		result.editor_transforms.append({"rotation":int(row.get("rotation",0)),"mirror_x":bool(row.get("mirror_x",false)),"mirror_y":bool(row.get("mirror_y",false))})
		if d.is_fixed(): result.fixed_parts.append(d)
		if d.is_moving(): result.moving_parts.append(d)
		if d.part_type in [36,37,68,69]: result.actor_candidates.append(d)
	if not legacy:
		var goal_error := AuthoredGoals.validate(doc.get("goals"), part_ids)
		if not goal_error.is_empty():
			error = goal_error
			return null
		result.authored_goals = doc.goals.duplicate(true)
	var owners: Array=[]
	for key in ["ropes","belts"]:
		if not doc.get(key) is Array: return null
		for graph in doc[key]:
			if not graph is Dictionary or not _index(graph.get("owner"),result.parts.size()): return null
			var id:=int(graph.owner)
			if owners.has(id) or result.parts[id].part_type!=(14 if key=="ropes" else 1): return null
			owners.append(id)
			var nodes=graph.get("route" if key=="ropes" else "ends")
			if not nodes is Array or nodes.size()<2 or nodes.size()>result.parts.size(): return null
			var seen: Array=[]
			for n in nodes:
				if not _index(n,result.parts.size()) or seen.has(int(n)) or int(n)==id: return null
				seen.append(int(n))
				# Playable mode removes connections along with their inventory
				# endpoints or pulleys, just as the packed campaign loader does.
				if not editor and result.parts[int(n)].is_in_parts_bin():
					result.parts[id].campaign_rope_inventory = true
			if key=="belts":
				if nodes.size()!=2: return null
				result.parts[id].belt_endpoints.assign(seen)
			else:
				var slots=graph.get("slots")
				if not slots is Array or slots.size()!=2 or not _integer(slots[0],0,1) or not _integer(slots[1],0,1): return null
				result.parts[id].rope_slots.assign([{"present":1,"ends":[seen[0],seen.back()],"slots":[int(slots[0]),int(slots[1])]}])
				for i in seen.size():
					var d:=result.parts[seen[i]]
					if i==0: d.set(LINKS[int(slots[0])],seen[1])
					elif i==seen.size()-1: d.set(LINKS[int(slots[1])],seen[i-1])
					else:
						if d.part_type!=17: return null
						d.pulley_rope_owner=id
						d.connected_1=seen[i+1]
						d.connected_2=seen[i-1]
	for part in result.parts:
		if part.is_in_parts_bin(): result.inventory_parts.append(part)
	result.fixed_count=result.fixed_parts.size()
	result.moving_count=result.moving_parts.size()
	result.declared_counts_match=true
	error=""
	return result

static func _integer(value: Variant, minimum: int, maximum: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value)==floorf(float(value)) and value>=minimum and value<=maximum

static func _index(value: Variant, count: int) -> bool:
	return _integer(value,0,count-1)

func load_file(path: String, editor: bool=true) -> PuzzleDefinition:
	var file:=FileAccess.open(path,FileAccess.READ)
	if file==null: error="Cannot open puzzle file."; return null
	if file.get_length()>4*1024*1024: error="Puzzle file is too large."; return null
	return decode(JSON.parse_string(file.get_as_text()),path,editor)

func save_file(path: String, doc: Dictionary, overwrite: bool=false) -> bool:
	if decode(doc,path)==null: return false
	if path.get_extension().to_lower()!="json": error="Use a .json filename."; return false
	if FileAccess.file_exists(path) and not overwrite: error="File exists. Confirm replacement."; return false
	if DirAccess.make_dir_recursive_absolute(path.get_base_dir())!=OK: error="Cannot create destination folder."; return false
	var temporary:=path+".tmp"
	var file:=FileAccess.open(temporary,FileAccess.WRITE)
	if file==null: error="Cannot write puzzle file."; return false
	file.store_string(JSON.stringify(doc,"\t")+"\n")
	file.flush()
	var write_error:=file.get_error()
	file.close()
	if write_error!=OK: error="Unable to finish writing puzzle."; return false
	if DirAccess.rename_absolute(temporary,path)!=OK: error="Cannot replace destination file."; return false
	error=""
	return true
