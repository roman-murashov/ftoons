extends RefCounted
## Port progress only. Original TOONS.SAV and research saves are never written.
const Goals = preload("res://scripts/simulation/campaign_goals.gd")
var path := preload("res://scripts/io/portable_paths.gd").profile().path_join("campaign_progress.json")
var entries: Dictionary = {}
var error := ""
var loaded := false
var dirty := false
var preserve_invalid_file := false
var native_status: Array=[]
var last_presentation: Dictionary={}
const PRESENTATIONS="res://assets/original/dos_campaign_presentations.json"

func _initial_status() -> Array:
	return JSON.parse_string(FileAccess.get_file_as_string(PRESENTATIONS)).initial_status.duplicate()

func remaining_tiles() -> int:
	# 779E:05D5: the204-piece password picture counts non-status3 puzzles.
	var available:=100;var solved:=0
	for value in native_status:
		if int(value)==3: available-=1
		elif int(value)==1: solved+=1
	if available==100: return -1
	return maxi(0,int((available-solved)*204/available)) if available>0 else 0

func _classify(index: int) -> int:
	# Literal control flow of779E:0434. Status2 is cleared only within the
	# completed group;3 is preserved until the password unlock action.
	if int(native_status[index])==1 and remaining_tiles()>0: return 0
	native_status[index]=1
	var bounds: Array=[0,30,50,75,100]
	var group:=0
	while index>=int(bounds[group+1]): group+=1
	var first:=int(bounds[group])
	while first<int(bounds[group+1]) and int(native_status[first])==1: first+=1
	if first==int(bounds[group+1]) or int(native_status[first])==3:
		var bonus:=false
		for value in native_status:
			if int(value) not in [1,3]: return 1
			bonus=bonus or int(value)==3
		return 3 if bonus else 4
	if int(native_status[first])==0: return 0
	for i in range(first,int(bounds[group+1])):
		if int(native_status[i])==2: native_status[i]=0
	return 2

func unlock_bonus() -> void:
	# 779E:0670, reached by the original WIND password comparison.
	for i in native_status.size():
		if int(native_status[i])>1: native_status[i]=0
	dirty=true
	_save()

func next_native_level(level: String) -> String:
	# 779E:02E5: seek unfinished puzzles in this group, wrap the group,
	# then search all groups. Only after those scans use the next unlocked
	# solved puzzle. The completion caller has already marked this one solved.
	if not loaded: load_progress()
	var current:=Goals.level_index(level)
	if current<0: return ""
	var names: Array=Goals.level_names()
	var bounds: Array=[0,30,50,75,100]
	var group:=0
	while current>=int(bounds[group+1]): group+=1
	for i in range(current+1,int(bounds[group+1])):
		if int(native_status[i])==0: return names[i]
	for i in range(int(bounds[group]),int(bounds[group+1])):
		if int(native_status[i])==0: return names[i]
	for i in 100:
		if int(native_status[i])==0: return names[i]
	for i in range(current+1,100):
		if int(native_status[i])<=1: return names[i]
	return names[0]

func load_progress() -> void:
	loaded=true
	entries.clear()
	error=""
	dirty=false
	preserve_invalid_file=false
	native_status=_initial_status()
	if not FileAccess.file_exists(path): return
	var parser:=JSON.new()
	if parser.parse(FileAccess.get_file_as_string(path))!=OK:
		error="Invalid campaign progress file; it has been preserved."
		preserve_invalid_file=true
		return
	var value: Variant=parser.data
	if not value is Dictionary or value.get("version")!=1 or not value.get("completed") is Dictionary:
		error="Invalid campaign progress file; it has been preserved."
		preserve_invalid_file=true
		return
	for name in value.completed:
		var row: Variant=value.completed[name]
		if Goals.level_index(name)>=0 and row is Dictionary and row.get("date") is String and (row.get("tick") is float or row.get("tick") is int):
			entries[name]=row
		else:
			error="Invalid campaign progress entry; the file has been preserved."
			preserve_invalid_file=true
	if value.has("native_status"):
		var statuses: Variant=value.native_status
		if statuses is Array and statuses.size()==100:
			for state in statuses:
				if not (state is int or state is float) or float(state)!=floorf(float(state)) or int(state)<0 or int(state)>3:
					error="Invalid campaign status; the file has been preserved."
					preserve_invalid_file=true
			if not preserve_invalid_file: native_status=statuses.duplicate()
		else:
			error="Invalid campaign status; the file has been preserved."
			preserve_invalid_file=true
	else:
		# Additive migration of existing port progress, never replace solved dates.
		for name in entries: native_status[Goals.level_index(name)]=1

func record(level: String, tick: int) -> Dictionary:
	if not loaded: load_progress()
	if Goals.level_index(level)<0: return {}
	var previous:=native_status.duplicate()
	var branch:=_classify(Goals.level_index(level))
	last_presentation={"branch":branch,"remaining_tiles":remaining_tiles()}
	if previous!=native_status: dirty=true
	if not entries.has(level):
		entries[level]={"date":Time.get_datetime_string_from_system(false,true),"tick":tick}
		dirty=true
	var entry: Dictionary=entries[level]
	_save()
	return entry

func _save() -> void:
	if preserve_invalid_file or not dirty: return
	error=""
	var temporary:=path+".tmp"
	var file:=FileAccess.open(temporary,FileAccess.WRITE)
	if file==null:
		error="Unable to save campaign progress."
		return
	file.store_string(JSON.stringify({"version":1,"completed":entries,"native_status":native_status},"\t"))
	file.flush()
	var write_error:=file.get_error()
	file.close()
	if write_error!=OK or DirAccess.rename_absolute(temporary,path)!=OK:
		error="Unable to commit campaign progress."
	else:
		dirty=false
