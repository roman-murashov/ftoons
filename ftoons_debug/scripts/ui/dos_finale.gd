extends RefCounted
## The FINALE.TTM opcode subset proved against original 2F9C:0D7A.
const Formats=preload("res://scripts/graphics/dynamix_formats.gd")
const TIMER_SECONDS:=5041.0/1193182.0
var catalog: ResourceCatalog
var commands: Array=[]
var palette: Array=[]
var sheets: Dictionary={}
var slots: Dictionary={}
var buffers: Dictionary={}
var buffer_slot:=0
var bitmap_slot:=0
var color:=0
var delay:=0
var cursor:=0
var frame:=0
var wait:=0.0
var pending_hold:=0.0
var canvas: Image
var texture: ImageTexture
var finished:=false
var error:=""
var frame_hashes: Array[String]=[]
var sound_requests: Array[int]=[]
var emit_audio:=true
var use_timing_profile:=true
var presentation_interrupts: Array=[]
var setup_wait:=0.0
var setup_interrupts:=0
var prepared:=false

func _init(resources: ResourceCatalog) -> void:
	catalog=resources

func begin() -> bool:
	var decoded:=Formats.decode_ttm(catalog.read_asset("FINALE.TTM"))
	if not decoded.ok:
		error=decoded.error
		return false
	commands=decoded.commands
	presentation_interrupts=[]
	setup_interrupts=0
	if use_timing_profile and FileAccess.file_exists("res://assets/original/dos_finale_timing.json"):
		var profile: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://assets/original/dos_finale_timing.json"))
		presentation_interrupts=profile.presentation_interrupts
		setup_interrupts=int(profile.get("setup_interrupts",0))
	cursor=0;frame=0;wait=0;pending_hold=0;delay=0
	bitmap_slot=0;buffer_slot=0;color=0
	slots.clear();buffers.clear();sheets.clear();frame_hashes.clear();sound_requests.clear()
	finished=false;error=""
	setup_wait=float(setup_interrupts)*TIMER_SECONDS
	prepared=false
	palette=Formats.decode_palette(catalog.read_asset("GAME.PAL")).colors
	canvas=Image.create(640,400,false,Image.FORMAT_RGBA8)
	canvas.fill(palette[0])
	# 2F9C:09FD..0A56 tiles GFWALPPR before the interpreter starts.
	var wallpaper:=Formats.decode_bmp(catalog.read_asset("GFWALPPR.BMP"))
	if not wallpaper.get("ok",false): error="Missing finale wallpaper";return false
	var tile:=Formats.frame_to_image(wallpaper.frames[0],palette,0)
	var x:=0;var y:=-62
	while y<400:
		while x<640:
			_blend(tile,Vector2i(x,y))
			x+=tile.get_width()
		y+=69;x-=58
		while x>0: x-=tile.get_width()
	texture=ImageTexture.create_from_image(canvas)
	advance(0)
	return error.is_empty()

func _blend(image: Image,point: Vector2i) -> void:
	canvas.blend_rect(image,Rect2i(Vector2i.ZERO,image.get_size()),point)

func _line(a: Vector2i,b: Vector2i) -> void:
	# Integer rasterization; no filtered CanvasItem line interpolation.
	var p:=a;var dx:=absi(b.x-a.x);var dy:=-absi(b.y-a.y)
	var sx:=1 if a.x<b.x else -1;var sy:=1 if a.y<b.y else -1
	var err:=dx+dy
	while true:
		if p.x>=0 and p.x<640 and p.y>=0 and p.y<400: canvas.set_pixelv(p,palette[color])
		if p==b: break
		var twice:=2*err
		if twice>=dy: err+=dy;p.x+=sx
		if twice<=dx: err+=dx;p.y+=sy

func _prepare() -> void:
	while cursor<commands.size():
		var command: Dictionary=commands[cursor]
		cursor+=1
		var a: Variant=command.args
		match int(command.opcode):
			0x1061: pass # Not in native dispatch table: skip the one-word operand.
			0xf05f: palette=Formats.decode_palette(catalog.read_asset(a)).colors
			0x1051: bitmap_slot=int(a[0])
			0xf02f:
				var name:=String(a).to_upper()
				var decoded:=Formats.decode_bmp(catalog.read_asset(name))
				if not decoded.get("ok",false): error="Cannot decode finale sheet "+name;finished=true;return
				var images: Array[Image]=[]
				for source in decoded.frames: images.append(Formats.frame_to_image(source,palette,0))
				sheets[name]=images;slots[bitmap_slot]=name
			0x2002: color=int(a[0])&15
			0xa104: canvas.fill_rect(Rect2i(a[0],a[1],a[2],a[3]),palette[color])
			0xa504,0xa524:
				var image: Image=sheets[slots[int(a[3])]][int(a[2])]
				if int(command.opcode)==0xa524: image=image.duplicate();image.flip_x()
				_blend(image,Vector2i(a[0],a[1]))
			0x1121: buffer_slot=int(a[0])
			0x4214:
				var box:=Rect2i(a[0],a[1],a[2],a[3])
				buffers[buffer_slot]={"image":canvas.get_region(box),"position":box.position}
			0xa601:
				var saved: Dictionary=buffers[int(a[0])]
				canvas.blit_rect(saved.image,Rect2i(Vector2i.ZERO,saved.image.get_size()),saved.position)
			0xa0a4: _line(Vector2i(a[0],a[1]),Vector2i(a[2],a[3]))
			0x1021: delay=int(a[0])
			0xc051:
				sound_requests.append(int(a[0]))
				if emit_audio:
					if int(a[0])>=1000 and int(a[0])<2000: MusicPlayer.select_song(int(a[0]),true)
					# 1DD9:00D3 prepares the resource; 0254 requests priority0,
					# retrigger0. An already playing cue must retain its playback.
					else: AudioEffects.play_sample(int(a[0]))
			0xc061:
				sound_requests.append(-int(a[0]))
				if emit_audio:
					if int(a[0])>=1000 and int(a[0])<2000:
						if MusicPlayer.current_song_id==int(a[0]): MusicPlayer.stop_music()
					else: AudioEffects.stop_sample(int(a[0]))
			0x0ff0:
				wait=pending_hold
				if frame<presentation_interrupts.size(): wait=float(presentation_interrupts[frame])*TIMER_SECONDS
				if frame==0: wait=maxf(0,wait-float(setup_interrupts)*TIMER_SECONDS)
				pending_hold=4.0*delay*TIMER_SECONDS
				return
			_:
				error="Unimplemented finale opcode %04X"%int(command.opcode)
				finished=true;return
	finished=true

func advance(delta: float) -> float:
	if not prepared:
		var used:=minf(delta,setup_wait)
		setup_wait-=used;delta-=used
		if setup_wait>0: return 0.0
		prepared=true
		_prepare()
	while not finished:
		var used:=minf(delta,wait)
		wait-=used;delta-=used
		if wait>0: return 0.0
		texture.update(canvas)
		var digest:=HashingContext.new()
		digest.start(HashingContext.HASH_SHA256);digest.update(canvas.get_data())
		frame_hashes.append(digest.finish().hex_encode())
		frame+=1
		_prepare()
	return delta
