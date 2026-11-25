extends RefCounted
## Export the frames used by the debug renderer into PNG atlases. Rectangles
## use top-left pixel coordinates and preserve native frame order, including
## empty slots. Animation schedules remain independent of atlas packing.
const DOS = preload("res://scripts/graphics/dynamix_formats.gd")
const WIN = preload("res://scripts/graphics/windows_graphics_formats.gd")
const Intro = preload("res://scripts/graphics/windows_intro_library.gd")

var error := ""
var stage := ""
var out := ""
var notify: Callable
var sheets := []
var skipped := []
var frame_count := 0

func _data(resource_path: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(stage.path_join(resource_path.trim_prefix("res://")))

func _index(resource_path: String) -> Dictionary:
	var result: Variant = JSON.parse_string(_data(resource_path).get_string_from_utf8())
	if result is Dictionary:
		return result
	error="Invalid graphics catalogue "+resource_path
	return {}

func _json(relative: String, value: Dictionary) -> void:
	var target := out.path_join(relative)
	if DirAccess.make_dir_recursive_absolute(target.get_base_dir()) == OK:
		var f := FileAccess.open(target, FileAccess.WRITE)
		if f != null and f.store_string(JSON.stringify(value)): return
	error="Cannot save graphics metadata "+relative

func _atlas(key: String, source: String, frames: Array, colors: Array, palette_name: String, transparent: int, coverage: bool) -> void:
	var area := 0
	var max_width := 1
	for frame: Dictionary in frames:
		var w := int(frame.get("width",0))
		var h := int(frame.get("height",0))
		max_width=maxi(w,max_width)
		area+=w*h
	# Pack consecutive frames into rows, trimming the last unused columns/rows.
	var limit := maxi(max_width,mini(4096,ceili(sqrt(float(area)))))
	var x := 0
	var y := 0
	var row_height := 0
	var used_width := 1
	var rects := []
	for frame: Dictionary in frames:
		var w := int(frame.get("width",0))
		var h := int(frame.get("height",0))
		if w==0 or h==0:
			rects.append(null)
			continue
		if x+w>limit:
			x=0
			y+=row_height
			row_height=0
		rects.append([x,y,w,h])
		x+=w
		row_height=maxi(h,row_height)
		used_width=maxi(x,used_width)
	var atlas := Image.create_empty(used_width,maxi(1,y+row_height),false,Image.FORMAT_RGBA8)
	for i in frames.size():
		if rects[i]==null: continue
		var frame: Dictionary=frames[i]
		var image: Image
		if coverage:
			image=Intro.frame_image(frame,colors)
		else:
			image=DOS.frame_to_image(frame,colors,transparent)
		var r: Array=rects[i]
		atlas.blit_rect(image,Rect2i(0,0,r[2],r[3]),Vector2i(r[0],r[1]))
	var path := out.path_join(key+".png")
	if DirAccess.make_dir_recursive_absolute(path.get_base_dir())!=OK or atlas.save_png(path)!=OK:
		error="Cannot write decoded graphics "+key+".png"
		return
	var alpha_mode := "command coverage" if coverage else ("opaque" if transparent<0 else "palette index")
	_json(key+".json",{"source":source,"atlas":key.get_file()+".png","palette":palette_name,"alpha":alpha_mode,
		"transparent_index":null if coverage or transparent<0 else transparent,"rect_xywh":rects})
	sheets.append({"layout":key+".json","source":source,"frames":frames.size()})
	frame_count+=frames.size()

func _progress(name: String) -> void:
	if notify.is_valid() and sheets.size()%8==0: notify.call("Decoding sprite atlases… "+name)

func _dos() -> void:
	var index := _index("assets/original/resource_index.json")
	if not error.is_empty(): return
	var palettes := {}
	for entry: Dictionary in index.entries:
		if entry.type=="PAL":
			var p := DOS.decode_palette(_data(entry.asset_path))
			if not p.ok:
				error=p.error
				return
			palettes[entry.name]=p.colors
	for entry: Dictionary in index.entries:
		var name: String=entry.name
		if entry.type not in ["SCR","BMP","TTM"]: continue
		var bytes := _data(entry.asset_path)
		if name=="TOONS.BMP" and bytes.slice(0,48).get_string_from_ascii().contains("Length Name"):
			skipped.append({"resource":name,"reason":"DOS linker map text"})
			continue
		if entry.type=="TTM":
			var timing := DOS.decode_ttm(bytes)
			if not timing.ok:
				skipped.append({"resource":name,"reason":timing.error})
			else:
				_json("animation/"+name.get_basename()+".json",{"source":name,"commands":timing.commands})
			if not error.is_empty(): return
			continue
		_progress(name)
		var scr: bool = entry.type=="SCR"
		var decoded := DOS.decode_scr(bytes) if scr else DOS.decode_bmp(bytes)
		if not decoded.ok:
			error="Cannot decode "+name+": "+str(decoded.error)
			return
		var palette_name := name.get_basename()+".PAL"
		if not palettes.has(palette_name): palette_name="GAME.PAL"
		_atlas(("screens/" if scr else "sprites/")+name.get_basename(),name,
			[decoded] if scr else decoded.frames,palettes[palette_name],palette_name,-1 if scr else 0,false)
		if not error.is_empty(): return

func _windows() -> void:
	var index := _index("dlc_win_data/graphics/binary/resource_index.json")
	if not error.is_empty(): return
	var colors := []
	for entry: Dictionary in index.entries:
		if entry.type=="CLU" and entry.name=="TOON_PAL":
			var p := WIN.decode_palette(_data(entry.asset_path))
			if not p.ok:
				error=p.error
				return
			colors=p.colors
	if colors.is_empty():
		error="Missing TOON_PAL for Windows sprites."
		return
	for entry: Dictionary in index.entries:
		if entry.type!="PAK": continue
		var name: String=entry.name
		_progress(name)
		var coverage := name in ["H2HTURN","H2HPTS1","H2HPTS2"]
		var decoded := WIN.decode_pak(_data(entry.asset_path),coverage)
		if not decoded.ok:
			error="Cannot decode Windows sprite "+name+": "+str(decoded.error)
			return
		_atlas("sprites/"+name,name,decoded.frames,colors,"TOON_PAL",decoded.transparent_index,coverage)
		if not error.is_empty(): return
	var intro_index := "dlc_win_data/intros/intro_index.json"
	if not FileAccess.file_exists(stage.path_join(intro_index)): return
	var intros := _index(intro_index)
	if not error.is_empty(): return
	for key: String in intros.resources:
		if "/PAK/" not in key: continue
		var palette_key := "MPC_TOON/CLU/DRIVE_IN" if key=="MPC_TOON/PAK/DRIVE_IN" else "TOONRSRC/CLU/TOON_PAL"
		var palette: Array=colors
		if key=="MPC_TOON/PAK/DRIVE_IN":
			var p := WIN.decode_palette(_data(intros.resources[palette_key].path))
			if not p.ok:
				error=p.error
				return
			palette=p.colors
		_progress(key)
		var decoded := WIN.decode_pak(_data(intros.resources[key].path),true)
		if not decoded.ok:
			error="Cannot decode "+key+": "+str(decoded.error)
			return
		_atlas("intros/"+key.get_file(),key,decoded.frames,palette,palette_key,-1,true)
		if not error.is_empty(): return

func run(edition: String, staged_project: String, progress: Callable=Callable()) -> Dictionary:
	stage=staged_project
	notify=progress
	out=stage.path_join("assets/decoded_graphics" if edition=="dos" else "dlc_win_data/decoded_graphics")
	if edition=="dos": _dos()
	else: _windows()
	if not error.is_empty(): return {}
	var timing := "animation/*.json and ../original/part_render_tables.json" if edition=="dos" else "../intros/intro_index.json when supplied"
	_json("index.json",{"format":1,"edition":edition,"sheets":sheets,"frame_slots":frame_count,"skipped":skipped,"animation_metadata":timing})
	return {"decoded_atlases":sheets.size(),"decoded_frame_slots":frame_count}
