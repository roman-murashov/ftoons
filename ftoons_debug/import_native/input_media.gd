extends RefCounted
## Resolve DOS installations and Windows discs supplied directly or inside ZIPs.
## Callers own and remove the private staging directory after import.

const DOS := ["TOONS.EXE", "RESOURCE.001", "ADL.DRV"]
const WINDOWS := ["TOONRSRC.DLL", "INTROS.DLL", "TOON2.AVI", "CAT.DA_", "SID.DA_", "WIN_TOON.EX_",
	"MPC_TOON.EXE", "WIN_TOON.EXE", "CAT.DAT", "SID.DAT"]
const IMAGE_EXTENSIONS := ["CUE", "BIN", "ISO"]
const MIB := 1024 * 1024
const ZIP_LIMIT := 2048 * MIB
const MAX_ENTRIES := 25000
const MAX_DIRECTORIES := 6000
var error := ""
var _windows_inputs: Array[String] = []

## Return an installation directory or a direct Windows image path. Return an
## empty string and set error when media is missing, ambiguous or malformed.
func prepare(edition: String, source_absolute: String, private_empty_work_dir: String) -> String:
	error = ""
	_windows_inputs.clear()
	if edition not in ["dos", "windows"]:
		return _fail("Unrecognized game edition.")
	var source := source_absolute.replace("\\", "/")
	if not source.is_absolute_path():
		return _fail("Choose an absolute game folder or file.")
	if DirAccess.dir_exists_absolute(source):
		return _find_dos(source) if edition == "dos" else source
	if not FileAccess.file_exists(source):
		return _fail("Selected game files could not be found.")
	var extension := source.get_extension().to_upper()
	if edition == "windows" and extension in IMAGE_EXTENSIONS:
		return source
	if extension != "ZIP":
		return _fail("Select an installed folder, ZIP archive, or supported Windows disc image.")
	var destination := private_empty_work_dir.path_join("input-" + edition)
	# Always create a fresh child directory. This also avoids existing links,
	# stale extracted files and overwriting anything in the selected installation.
	if DirAccess.make_dir_recursive_absolute(private_empty_work_dir) != OK or DirAccess.make_dir_absolute(destination) != OK:
		return _fail("Could not create an empty media staging directory.")
	if not _extract(source, destination, edition):
		return ""
	if edition == "dos":
		return _find_dos(destination)
	# Eliminate arbitrary wrapper folders used by ZIP creation tools.
	while DirAccess.get_files_at(destination).is_empty():
		var children := DirAccess.get_directories_at(destination)
		if children.size() != 1: break
		destination = destination.path_join(children[0])
	# Conventional installed/CD layouts can be combined by the Windows
	# reader (including loose MIDI files alongside the disc). A ZIP made
	# with arbitrary sibling folder names can still supply one complete CD.
	var child_names := Array(DirAccess.get_directories_at(destination)).map(func(n): return n.to_upper())
	var files_here := DirAccess.get_files_at(destination)
	var conventional := ["WIN_DISTRIB", "WIN_DISTRIB_MPC", "CD_CONTENTS", "CD_ISO", "SIERRA", "TOONS"]
	if files_here.is_empty() and not child_names.any(func(n): return n in conventional):
		for kind in ["CUE", "ISO", "BIN", "DLL"]:
			var candidates := []
			for path: String in _windows_inputs:
				if path.get_extension().to_upper() == kind: candidates.append(path)
			if candidates.size() > 1: return _fail("Select a ZIP containing one Windows installation or one CD image.")
			if candidates.size() == 1:
				return candidates[0].get_base_dir() if kind == "DLL" else candidates[0]
	return destination


func _fail(reason: String) -> String:
	error = reason
	return ""


func _find_dos(root: String) -> String:
	var pending: Array[String] = [root]
	var found := ""
	var scanned := 0
	while not pending.is_empty():
		scanned += 1
		if scanned > MAX_DIRECTORIES:
			return _fail("Select a more specific DOS installation folder.")
		var path: String = pending.pop_back()
		var dir := DirAccess.open(path)
		if dir == null: continue
		var names := {}
		for leaf in dir.get_files():
			if leaf.to_upper() in DOS and not dir.is_link(leaf):
				names[leaf.to_upper()] = true
		if names.size() == DOS.size():
			if path == root: return path
			if not found.is_empty(): return _fail("Multiple DOS installations found. Choose the specific game folder.")
			found = path
			continue
		for child in dir.get_directories():
			if not dir.is_link(child):
				pending.append(path.path_join(child))
	if found.is_empty():
		return _fail("Choose a DOS installation containing TOONS.EXE, RESOURCE.001 and ADL.DRV together.")
	return found


## Inspect classic ZIP central directory sizes before ZIPReader allocates
## decoded buffers. DOS resources and the mixed-mode Windows CD fit ZIP32.
func _zip_entries(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 22 or file.get_length() > ZIP_LIMIT:
		_fail("Unreadable ZIP or unsupported archive size.")
		return {}
	var tail_start := maxi(0, file.get_length() - 65557)
	file.seek(tail_start)
	var tail := file.get_buffer(file.get_length() - tail_start)
	var eocd := tail.size() - 22
	while eocd >= 0:
		if tail.decode_u32(eocd) == 0x06054b50 and eocd + 22 + tail.decode_u16(eocd+20) == tail.size(): break
		eocd -= 1
	if eocd < 0:
		_fail("ZIP end record is missing.")
		return {}
	var entries := tail.decode_u16(eocd+10)
	var bytes := tail.decode_u32(eocd+12)
	var start := tail.decode_u32(eocd+16)
	if tail.decode_u32(eocd+4) != 0 or entries != tail.decode_u16(eocd+8) or entries == 0 or entries > MAX_ENTRIES or bytes > 16*MIB or start+bytes != tail_start+eocd:
		_fail("Invalid or unsupported ZIP directory. Choose one ordinary ZIP archive.")
		return {}
	file.seek(start)
	var table := file.get_buffer(bytes)
	var at := 0
	var result := {}
	var seen := {}
	var reserved := RegEx.create_from_string('(?i)^(CON|PRN|AUX|NUL|CLOCK\\$|CONIN\\$|CONOUT\\$|COM[1-9¹²³]|LPT[1-9¹²³])(\\.|$)')
	for i in entries:
		if at+46 > table.size() or table.decode_u32(at) != 0x02014b50:
			_fail("Truncated ZIP directory.")
			return {}
		var flags := table.decode_u16(at+8)
		var method := table.decode_u16(at+10)
		var compressed := table.decode_u32(at+20)
		var size := table.decode_u32(at+24)
		var name_length := table.decode_u16(at+28)
		var end_name := at+46+name_length
		var next := end_name + table.decode_u16(at+30) + table.decode_u16(at+32)
		var local := table.decode_u32(at+42)
		if next > table.size() or name_length == 0 or name_length > 2048 or local+30+compressed > start or flags & 1 or method not in [0, 8] or size == 0xffffffff or table.decode_u16(at+34) != 0:
			_fail("Unsupported ZIP entry. Use a single unencrypted stored or deflated ZIP.")
			return {}
		var raw_name := table.slice(at+46, end_name)
		var name := raw_name.get_string_from_utf8()
		if name.to_utf8_buffer() != raw_name or name.contains("\\") or not _safe_path(name.trim_suffix("/"), reserved):
			_fail("Invalid filename in the ZIP archive.")
			return {}
		var key := name.trim_suffix("/").to_upper()
		if seen.has(key):
			_fail("Duplicate case-insensitive filename in the ZIP archive.")
			return {}
		seen[key] = true
		result[name] = size
		at = next
	if at != table.size():
		_fail("Invalid ZIP directory length.")
		return {}
	return result


func _safe_path(relative: String, reserved: RegEx) -> bool:
	for part in relative.split("/"):
		if part.is_empty() or part.ends_with(".") or part.ends_with(" ") or reserved.search(part) != null:
			return false
		for ch in part:
			if ch.unicode_at(0) < 32 or '<>:"|?*'.contains(ch): return false
	return true


func _wanted(edition: String, path: String) -> bool:
	if path.ends_with("/") or "__MACOSX" in path.split("/"): return false
	var leaf := path.get_file().to_upper()
	if edition == "dos": return leaf in DOS
	return leaf in WINDOWS or leaf.get_extension() in IMAGE_EXTENSIONS or leaf.get_extension() == "MID"


func _extract(path: String, destination: String, edition: String) -> bool:
	var entries := _zip_entries(path)
	if entries.is_empty(): return false
	var selected := []
	var total := 0
	for name: String in entries:
		if not _wanted(edition, name): continue
		var size: int = entries[name]
		total += size
		var limit := 768 * MIB if name.get_extension().to_upper() in ["BIN", "ISO"] else 32 * MIB
		if name.get_extension().to_upper() == "CUE": limit = MIB
		if size > limit or total > ZIP_LIMIT:
			_fail("The ZIP exceeds the supported size for this game media.")
			return false
		selected.append(name)
	if selected.is_empty():
		_fail("No %s game files found in the ZIP." % edition)
		return false
	var zip := ZIPReader.new()
	if zip.open(path) != OK:
		_fail("Cannot open the selected ZIP.")
		return false
	var files := zip.get_files()
	if files.size() != entries.size():
		_fail("Inconsistent ZIP directory entries.")
		return false
	for name in files:
		if not entries.has(name):
			_fail("Inconsistent ZIP filenames.")
			return false
	for name: String in selected:
		var target := destination.path_join(name)
		if edition == "windows" and (target.get_extension().to_upper() in IMAGE_EXTENSIONS or target.get_file().to_upper() == "TOONRSRC.DLL"):
			_windows_inputs.append(target)
		var data := zip.read_file(name)
		if data.size() != entries[name]:
			_fail("Unable to unpack " + name)
			return false
		if DirAccess.make_dir_recursive_absolute(target.get_base_dir()) != OK:
			_fail("Cannot create ZIP staging folders.")
			return false
		var f := FileAccess.open(target, FileAccess.WRITE)
		if f == null or not f.store_buffer(data):
			_fail("Could not write extracted file " + name)
			return false
		f.close()
	zip.close()
	return true
