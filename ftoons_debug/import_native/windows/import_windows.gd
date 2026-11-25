extends RefCounted
## Import the Windows version from its installed files or CD. Write into the
## caller's staging project; only the caller publishes a finished import.
const Win16 = preload("res://import_native/windows/win16.gd")
const Disc = preload("res://import_native/windows/disc.gd")
const RULES = preload("res://import_native/windows/win_play_rules.json")
const MATCHES = preload("res://import_native/windows/win_cd_matches.json")
const DLL_HASH := "e0407b4dc36129cc29fbf53b997b4bbb1b1e9795c5a079386f6fc61fe3c358d9"
const MPC_HASH := "1a414bebc121f154521d382cda5e9771eadc227c10c94dfd7d1591e431aa3ff1"
const INTRO_HASH := "1cf30fb2a645fc0424d95aa416febe03ab5eca8c6e763263940b938fbf386210"
const WIN_HASH := "ceb1c7f0afcf31c515c9356d64a7a5e877b8645b1b67dc6d11b0580b2df66d88"
const NAMES := ["TOONRSRC.DLL","INTROS.DLL","TOON2.AVI","CAT.DA_","SID.DA_","WIN_TOON.EX_","MPC_TOON.EXE","WIN_TOON.EXE","CAT.DAT","SID.DAT"]
const FOLDERS := ["WIN_DISTRIB","WIN_DISTRIB_MPC","CD_CONTENTS","CD_ISO","SIERRA","TOONS"]
const MAX_FILE := 32*1024*1024
var error := ""
var folder := ""
var loose := {}
var disc_files := {}
var images: Array[String] = []
var disc
var graphics := []
var warnings := []

func _hash(data: PackedByteArray) -> String:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	if not data.is_empty(): hash.update(data)
	return hash.finish().hex_encode()

func _save(name: String, bytes: PackedByteArray) -> String:
	if not error.is_empty(): return ""
	var target := folder.path_join(name)
	if DirAccess.make_dir_recursive_absolute(target.get_base_dir())==OK:
		var f := FileAccess.open(target,FileAccess.WRITE)
		if f!=null and f.store_buffer(bytes): return "res://dlc_win_data/"+name
	error = "Could not write imported asset "+name
	return ""

func _json(name: String, data: Dictionary) -> void:
	_save(name,JSON.stringify(data).to_utf8_buffer())

func _fail(message: String) -> Dictionary:
	error = message
	return {}

func _scan(source: String) -> void:
	var queue: Array[String]=[source]
	var scanned := {}
	var cues: Array[String]=[]
	var bins: Array[String]=[]
	var isos: Array[String]=[]
	while not queue.is_empty():
		var directory: String = queue.pop_front()
		if scanned.has(directory): continue
		scanned[directory]=true
		var dir := DirAccess.open(directory)
		if dir==null:
			error="Cannot read Windows game directory "+directory
			return
		var children: Array[String]=[]
		for child in dir.get_directories():
			if dir.is_link(child): continue
			children.append(directory.path_join(child))
			if child.to_upper() in FOLDERS: queue.append(directory.path_join(child))
		var recognizable := false
		for name in dir.get_files():
			var key := name.to_upper()
			var full := directory.path_join(name)
			if dir.is_link(name): continue
			if key in NAMES or (key.ends_with(".MID") and key.get_basename().is_valid_identifier()):
				if not loose.has(key): loose[key]=full
				recognizable=true
			match name.get_extension().to_upper():
				"CUE": cues.append(full)
				"BIN": bins.append(full)
				"ISO": isos.append(full)
		# ZIP programs often wrap the entire installation in one named folder.
		if not recognizable and children.size()==1: queue.append(children[0])
	# A CUE explicitly identifies its companion. Without one, an ISO and a
	# BIN can be independent discs; let the player choose which to import.
	if not cues.is_empty():
		images = cues
	else:
		images = isos + bins

func _bytes(name: String) -> PackedByteArray:
	if loose.has(name):
		var f := FileAccess.open(loose[name],FileAccess.READ)
		if f==null or f.get_length()>MAX_FILE:
			error="Cannot read supported size for "+name
			return PackedByteArray()
		return f.get_buffer(f.get_length())
	return disc_files.get(name,PackedByteArray())

func _graphic(type: String, name: String, relative: String, offset: int, data: PackedByteArray) -> void:
	var path := _save("graphics/binary/"+relative,data)
	graphics.append({"type":type,"name":name,"source_offset":offset,"byte_length":data.size(),"asset_path":path,"sha256":_hash(data)})

func _sound_wave(data: PackedByteArray, name: String) -> PackedByteArray:
	# The WAVE resources are padded to segments inside the Windows module.
	# Forty-five have an odd last PCM chunk, with RIFF length ending before
	# the word-alignment pad. Include that pad when saving a standalone WAV.
	if data.size()<12 or data.slice(0,4).get_string_from_ascii()!="RIFF" or data.slice(8,12).get_string_from_ascii()!="WAVE":
		error="Invalid Windows WAVE header for "+name
		return PackedByteArray()
	var end := 8+data.decode_u32(4)
	if end>data.size() or end<12:
		error="Invalid Windows WAVE length for "+name
		return PackedByteArray()
	var wave := data.slice(0,end)
	var offset := 12
	while offset+8<=end:
		var size := wave.decode_u32(offset+4)
		var after := offset+8+size
		if after>end: break
		if after==end and size%2==1:
			wave.append(0)
			wave.encode_u32(4,wave.size()-8)
			return wave
		offset=after+(size%2)
	if offset!=end:
		error="Truncated Windows WAVE chunk for "+name
		return PackedByteArray()
	return wave

func _intro_resource(index: Dictionary, raw: Dictionary, key: String, offset: int, data: PackedByteArray) -> void:
	var path := _save("intros/binary/"+key+".bin",data)
	index[key]={"path":path,"size":data.size(),"sha256":_hash(data),"source_offset":offset}
	raw[key]=data

func _intros(dll: PackedByteArray, exe: PackedByteArray, palette: Dictionary) -> int:
	if _hash(dll)!=INTRO_HASH or _hash(exe)!=MPC_HASH or palette.is_empty():
		error="Unsupported Windows introduction data."
		return 0
	var raw := {}
	var index := {}
	for item: Dictionary in Win16.resources(dll):
		_intro_resource(index,raw,"INTROS/%s/%s"%[item.type,item.name],item.offset,item.data)
	for item: Dictionary in Win16.resources(exe):
		if item.type=="TYPE_32513":
			_intro_resource(index,raw,"MPC_TOON/CLU/DRIVE_IN",item.offset,item.data)
		elif item.type=="TYPE_32516" and item.name=="2":
			_intro_resource(index,raw,"MPC_TOON/PAK/DRIVE_IN",item.offset,item.data)
	_intro_resource(index,raw,"TOONRSRC/CLU/TOON_PAL",palette.offset,palette.data)
	var levels := {}
	for campaign: Array in [["CAKE","CAKE",30],["BRAWN","BRAN",20],["HARD","HARD",25],["LOON","LOON",25]]:
		var words: PackedByteArray = raw["INTROS/INTRO/"+campaign[0]]
		var pos := 0
		for n in range(1,campaign[2]+1):
			var sequence := []
			while words.decode_u16(pos):
				sequence.append(words.decode_u16(pos))
				pos+=2
			pos+=2
			levels["%s%d.LEV"%[campaign[1],n]]=sequence
	var clips := {}
	for key: String in raw:
		if not key.begins_with("INTROS/MUV/"): continue
		var id := key.get_file()
		var data: PackedByteArray = raw[key]
		var ply: PackedByteArray = raw["INTROS/PLY/"+id]
		var commands := []
		for i in data.decode_u16(22):
			var p := i*16
			commands.append({"op":ply.decode_u16(p),"frame":ply.decode_u16(p+2),"start":ply.decode_u32(p+4),"duration":ply.decode_u32(p+8),"y":ply.decode_s16(p+12),"x":ply.decode_s16(p+14)})
		clips[id]={"origin":[data.decode_s16(2),data.decode_s16(4)],"duration":data.decode_u32(14),"step":data.decode_u16(20),"commands":commands}
	var ne := exe.decode_u32(60)
	var table := ne+exe.decode_u16(ne+34)
	var base := exe.decode_u16(table+8*(exe.decode_u16(ne+14)-1))<<exe.decode_u16(ne+50)
	var mouths := []
	for i in 9:
		var p := base+0x2f48+8*i
		mouths.append([[exe.decode_s16(p),exe.decode_s16(p+2)],[exe.decode_s16(p+4),exe.decode_s16(p+6)]])
	_json("intros/intro_index.json",{"format":"windows-level-intros-v1","ticks_per_second":600,"resources":index,"clips":clips,"levels":levels,"mouth_origins":mouths})
	return clips.size()

func run(source: String, stage: String, progress: Callable=Callable()) -> Dictionary:
	folder=stage.path_join("dlc_win_data")
	if DirAccess.dir_exists_absolute(source):
		_scan(source)
	elif source.get_extension().to_lower() in ["bin","cue","iso"]:
		images.append(source)
	else:
		return _fail("Select a Windows installation, a disc image (.cue, .bin, .iso), or a ZIP.")
	if not error.is_empty(): return {}
	if images.size()>1: return _fail("Multiple disc images found. Select the desired CUE, BIN or ISO directly.")
	if not images.is_empty():
		disc=Disc.new()
		if not disc.open(images[0]): return _fail(disc.error)
		disc_files=disc.files(NAMES)
		if not disc.error.is_empty(): return _fail(disc.error)
		if _hash(disc_files.get("TOONRSRC.DLL",PackedByteArray()))!=DLL_HASH:
			return _fail("This disc does not contain the supported Incredible Toon Machine Windows game.")
		if disc.starts.is_empty():
			warnings.append("The supplied data track contains game files only. Supply the mixed-mode CUE/BIN for CD music.")
	var dll := _bytes("TOONRSRC.DLL")
	if _hash(dll)!=DLL_HASH: return _fail("Select the Windows game files containing the supported TOONRSRC.DLL, or the Windows game CD.")
	if progress.is_valid(): progress.call("Importing Windows graphics, effects and puzzles…")
	var palette := {}
	var puzzles := []
	var effects := 0
	for item: Dictionary in Win16.resources(dll):
		var name: String=item.name
		var data: PackedByteArray=item.data
		match item.type:
			"PAK","CLU":
				_graphic(item.type,name,"TOONRSRC/%s/%s.bin"%[item.type,name],item.offset,data)
				if item.type=="CLU" and name=="TOON_PAL": palette=item
			"PUZ":
				if not name.begins_with("PLAY") or not name.substr(4).is_valid_int(): continue
				var n := int(name.substr(4))
				var title := data.slice(4).get_string_from_ascii()
				var instructions := data.slice(5+title.length()).get_string_from_ascii()
				_save("head_to_head/"+name+".bin",data)
				puzzles.append({"number":n,"source":name+".H2H","file":name+".bin","title":title,"instructions":instructions,"sha256":_hash(data),"goal":RULES.data[n-1]})
			"WAVE":
				var wave := _sound_wave(data,name)
				if not error.is_empty(): return {}
				_save("audio/windows_sfx/"+name+".wav",wave)
				effects+=1
	if puzzles.size()!=50 or palette.is_empty(): return _fail("Incomplete Windows puzzle or graphics directory.")
	puzzles.sort_custom(func(a:Dictionary,b:Dictionary): return a.number<b.number)
	_json("head_to_head/index.json",{"format":1,"source_sha256":DLL_HASH,"levels":puzzles,"turn_seconds":{"default":45,"minimum":10,"maximum":599},"tournament_rounds":{"default":7,"minimum":1,"maximum":9}})
	var exe := _bytes("MPC_TOON.EXE")
	if exe.is_empty(): exe=_bytes("WIN_TOON.EXE")
	var compressed := _bytes("WIN_TOON.EX_")
	if not compressed.is_empty() and _hash(exe)!=MPC_HASH: exe=Win16.expand(compressed)
	var exe_hash := _hash(exe)
	if not compressed.is_empty() and exe.is_empty(): return _fail("Invalid compressed Windows game executable.")
	if not exe.is_empty() and exe_hash not in [WIN_HASH,MPC_HASH]: return _fail("Unsupported Windows game executable.")
	for item: Dictionary in Win16.resources(exe):
		if item.type in Win16.NATIVE_GRAPHICS.values():
			_graphic(item.type,item.name,"WIN_TOON/%s/%s.bin"%[item.type,item.name],item.offset,item.data)
	for actor: String in ["CAT","SID"]:
		var data := _bytes(actor+".DAT")
		if data.is_empty():
			var packed := _bytes(actor+".DA_")
			if not packed.is_empty():
				data=Win16.expand(packed)
				if data.is_empty(): return _fail("Invalid compressed "+actor+" graphics data.")
		if not data.is_empty(): _graphic("ACTOR_DATA",actor+".DAT","actor_data/"+actor+".DAT",0,data)
	_json("graphics/binary/resource_index.json",{"format":"windows-ne-graphics-pack-v1","entries":graphics})
	var midi := 0
	for name: String in loose:
		if name.ends_with(".MID"):
			var bytes := _bytes(name)
			if bytes.slice(0,4).get_string_from_ascii()=="MThd":
				_save("audio/windows_midi/"+name,bytes)
				midi+=1
	var intro := _bytes("INTROS.DLL")
	var clips := 0
	if not intro.is_empty():
		if exe_hash==MPC_HASH:
			if progress.is_valid(): progress.call("Importing intro animation and dialogue…")
			clips=_intros(intro,exe,palette)
		else: warnings.append("Intro animation also requires the accompanying MPC_TOON.EXE or WIN_TOON.EX_.")
	var avi := _bytes("TOON2.AVI")
	if not avi.is_empty(): _save("intros/TOON2.AVI",avi)
	var tracks := 0
	if disc!=null and not disc.starts.is_empty() and error.is_empty():
		var cd: Dictionary=disc.extract_tracks(folder.path_join("audio"),MATCHES.data,progress)
		if not disc.error.is_empty(): return _fail(disc.error)
		tracks=cd.tracks.size()
		_json("audio/audio_index.json",{"cd_tracks":cd.tracks})
		_json("audio/music_matches.json",{"matches":cd.mapping})
	if not error.is_empty(): return {}
	return {"graphics":graphics.size(),"head_to_head":puzzles.size(),"windows_sfx":effects,"windows_midi":midi,"intro_clips":clips,"cd_tracks":tracks,"warnings":warnings}
