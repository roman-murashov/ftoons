extends RefCounted
## Read the Windows CD's ISO9660 file system and its Red Book audio tracks.
## Sector numbers in a CUE are relative to its BIN. PREGAP directives do not
## consume bytes in that BIN. A plain 2048-byte ISO only holds the data track.
const BIN_HASH := "547609858f3123badabffae99fc826d08fab935da9c79f3f58eb689db3d06634"
const TOC := [0,18541,28985,39115,48961,53247,63260,72805,82629,92347,103358,113375,121870,131251,142374,155174,168666,178667,189666,196465,205377,216080,224653,234350,244235]

var error := ""
var file: FileAccess
var stride := 2048
var offset := 0
var starts: Array = []
var data_end := 0

func _bad_cue() -> String:
	error = "Expected the Windows game CD's single-BIN, 25-track CUE and its companion BIN."
	return ""

func _cue(path: String) -> String:
	if FileAccess.get_size(path)>1024*1024: return _bad_cue()
	var tracks: Array = []
	var bin := ""
	var file_pattern := RegEx.create_from_string('(?i)^FILE\\s+"([^"]+)"\\s+BINARY$')
	for row in FileAccess.get_file_as_string(path).split("\n"):
		var line := row.strip_edges().trim_prefix("\ufeff")
		var words := line.replace("\t"," ").to_upper().split(" ",false)
		if words.is_empty(): continue
		match words[0]:
			"FILE":
				var found := file_pattern.search(line)
				if not bin.is_empty() or found == null: return _bad_cue()
				var leaf := found.get_string(1)
				if leaf != leaf.replace("\\","/").get_file() or ":" in leaf or leaf in [".",".."]: return _bad_cue()
				for name in DirAccess.get_files_at(path.get_base_dir()):
					if name.to_upper() == leaf.to_upper(): bin = path.get_base_dir().path_join(name)
				if bin.is_empty(): return _bad_cue()
			"TRACK":
				if words.size() != 3 or int(words[1]) != tracks.size()+1: return _bad_cue()
				if words[2] != ("MODE1/2352" if tracks.is_empty() else "AUDIO"): return _bad_cue()
				tracks.append(-1)
			"INDEX":
				if words.size() != 3 or tracks.is_empty(): return _bad_cue()
				if words[1] != "01": continue
				var msf := words[2].split(":")
				if msf.size() != 3 or not msf[0].is_valid_int() or not msf[1].is_valid_int() or not msf[2].is_valid_int(): return _bad_cue()
				if mini(int(msf[0]),mini(int(msf[1]),int(msf[2])))<0 or int(msf[1])>=60 or int(msf[2])>=75: return _bad_cue()
				var sector := int(msf[0])*4500 + int(msf[1])*75 + int(msf[2])
				if tracks.back() != -1 or (tracks.size() > 1 and sector <= int(tracks[-2])): return _bad_cue()
				tracks[-1] = sector
	# A supported cue describes the one data track and all 24 CD-DA tracks.
	if bin.is_empty() or tracks.size() != 25 or tracks[0] != 0 or tracks.has(-1):
		return _bad_cue()
	starts = tracks
	return bin

func open(path: String) -> bool:
	var extension := path.get_extension().to_lower()
	if extension == "cue":
		path = _cue(path)
	elif extension == "bin":
		# Prefer the descriptor referring to this file, including renamed CUEs.
		for name in DirAccess.get_files_at(path.get_base_dir()):
			if name.get_extension().to_lower() != "cue": continue
			var candidate := _cue(path.get_base_dir().path_join(name))
			if not candidate.is_empty() and candidate.get_file().to_upper() == path.get_file().to_upper(): break
			starts.clear()
			error = ""
	if path.is_empty(): return false
	file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		error = "Cannot read disc image " + path.get_file()
		return false
	file.seek(16*2048)
	if file.get_buffer(7) != PackedByteArray([1,67,68,48,48,49,1]):
		stride = 2352
		offset = 16
	if file.get_length() % stride != 0:
		error = "The disc image ends within a sector."
		return false
	var sectors := file.get_length() / stride
	if starts.is_empty() and stride == 2352 and file.get_length() == 597589104 and FileAccess.get_sha256(path) == BIN_HASH:
		starts = TOC.duplicate()
	if not starts.is_empty() and (starts.back() >= sectors or stride != 2352):
		error = "The track positions and disc image size do not agree."
		return false
	data_end = sectors if starts.is_empty() else int(starts[1])
	return true

func read_extent(sector: int, size: int) -> PackedByteArray:
	var count := (size+2047)/2048
	if size > 32*1024*1024 or sector + count > data_end:
		error = "Invalid file extent in Windows disc data."
		return PackedByteArray()
	file.seek(sector*stride)
	if stride == 2048: return file.get_buffer(size)
	var out := PackedByteArray()
	for i in count:
		file.seek((sector+i)*stride+offset)
		out.append_array(file.get_buffer(mini(2048, size-out.size())))
	return out

func files(wanted: Array) -> Dictionary:
	var result := {}
	var pvd := read_extent(16,2048)
	if pvd.size() != 2048 or pvd.slice(0,7) != PackedByteArray([1,67,68,48,48,49,1]):
		error = "The image has no supported ISO9660 data track."
		return {}
	var directory := read_extent(pvd.decode_u32(158),pvd.decode_u32(166))
	var pos := 0
	while pos < directory.size():
		var size := directory[pos]
		if size == 0:
			pos = (pos/2048 + 1)*2048
			continue
		if size < 34 or pos+size > directory.size() or 33+directory[pos+32] > size:
			error = "Invalid ISO9660 directory record."
			return {}
		var name := directory.slice(pos+33,pos+33+directory[pos+32]).get_string_from_ascii().get_slice(";",0).to_upper()
		if name in wanted and not directory[pos+25] & 2:
			result[name] = read_extent(directory.decode_u32(pos+2),directory.decode_u32(pos+10))
			if not error.is_empty(): return {}
		pos += size
	return result

func extract_tracks(folder: String, matches: Dictionary, progress: Callable) -> Dictionary:
	var tracks := []
	var mapping := []
	if DirAccess.make_dir_recursive_absolute(folder.path_join("cd")) != OK:
		error = "Cannot create CD music directory."
		return {}
	for i in range(1, starts.size()):
		if progress.is_valid(): progress.call("Importing CD audio track %d of 24…" % i)
		var last: int = starts[i+1] if i+1 < starts.size() else file.get_length()/2352
		var count: int = (last-starts[i])*2352
		var relative := "cd/track_%02d.wav" % (i+1)
		var out := FileAccess.open(folder.path_join(relative),FileAccess.WRITE)
		if out == null:
			error = "Cannot write " + relative
			return {}
		out.store_buffer("RIFF".to_ascii_buffer())
		out.store_32(count+36)
		out.store_buffer("WAVEfmt ".to_ascii_buffer())
		out.store_32(16)
		out.store_16(1)
		out.store_16(2)
		out.store_32(44100)
		out.store_32(176400)
		out.store_16(4)
		out.store_16(16)
		out.store_buffer("data".to_ascii_buffer())
		out.store_32(count)
		var hash := HashingContext.new()
		hash.start(HashingContext.HASH_SHA256)
		file.seek(starts[i]*2352)
		var remaining := count
		while remaining > 0:
			var block := file.get_buffer(mini(1048576,remaining))
			if block.is_empty() or not out.store_buffer(block):
				error = "Failed to copy " + relative
				return {}
			hash.update(block)
			remaining -= block.size()
		out.close()
		tracks.append({"number":i+1,"path":relative,"frames":count/4,"pcm_bytes":count,"pcm_sha256":hash.finish().hex_encode()})
		if matches.has(str(i+1)):
			mapping.append({"dos_song_id":matches[str(i+1)],"cd_track":i+1,"path":relative})
	return {"tracks":tracks,"mapping":mapping}
