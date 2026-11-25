extends "res://scripts/ui/dos_inventory_art.gd"
## DOS piggy-bank presentation; loading is delegated to the shared construction session.
var owner_modal: Control
var host: Control
var groups: Array = [[],[],[],[],[]]
var category := 0
var category_phase := 0
var category_elapsed := 0.0
var top := 0
var selection := 0
var error := ""
var buttons := {}
var title_cache := {}
var save_mode := false
const PREFIXES := ["CAKE","BRAN","HARD","LOON"]

func _init(modal: Control) -> void:
	owner_modal=modal
	host=modal.host
	super(host.catalog, host.sprite_graphics)
	layout=JSON.parse_string(FileAccess.get_file_as_string("res://assets/original/dos_piggy.json"))
	_load_sheets(layout.tables.values())
	mouse_filter=Control.MOUSE_FILTER_IGNORE
	visible=false

func begin() -> void:
	save_mode=false
	groups=[[],[],[],[],[]]
	var reader:=LevelReader.new(host.catalog)
	category=0
	selection=0
	for source in host.construction.level_sources:
		var group:=4
		for i in 4:
			if String(source).begins_with(PREFIXES[i]) and String(source).get_extension()=="LEV": group=i; break
		var entry := reader.menu_entry(source)
		if entry.is_empty(): continue
		groups[group].append(entry)
		if source==host.construction.runner.puzzle.source_name:
			category=group
			selection=groups[group].size()-1
	top=(selection/5)*5
	error=""
	category_phase=0
	category_elapsed=0
	visible=true
	refresh_buttons()

func refresh_buttons() -> void:
	buttons={"cancel":Rect2(458,335,90,41),"load":Rect2(155,331,86,42),
		"down":Rect2(524,235,37,49),"up":Rect2(518,157,46,67)}
	var rects:=[Rect2(148,64,77,61),Rect2(228,24,77,61),Rect2(309,26,77,61),Rect2(397,22,77,61),Rect2(481,51,72,64)]
	for i in 5: buttons["group_"+str(i)]=rects[i]
	for i in mini(5,groups[category].size()-top): buttons["row_"+str(i)]=Rect2(155,168+i*28,354,28)
	owner_modal.buttons=buttons
	queue_redraw()

func activate(action: String) -> void:
	error=""
	if action=="cancel": owner_modal.close(); return
	if action=="load":
		if groups[category].is_empty(): return
		var source: String=groups[category][selection].source
		if host.construction.request_level(source): owner_modal.close()
		else: error="Unable to load puzzle."
	elif action.begins_with("group_"):
		category=int(action.trim_prefix("group_"))
		category_phase=0
		category_elapsed=0
		top=0
		selection=0
	elif action.begins_with("row_"): selection=top+int(action.trim_prefix("row_"))
	elif action=="down": top=mini(top+5,maxi(0,groups[category].size()-5))
	elif action=="up": top=maxi(0,top-5)
	refresh_buttons()

func advance(delta: float) -> void:
	if not visible: return
	category_elapsed+=delta
	var interval:=float(layout.category_timer_ticks)/60.0
	if category_elapsed>=interval:
		category_elapsed=fmod(category_elapsed,interval)
		category_phase=(category_phase+1)%layout.categories[category].sequence.size()
		queue_redraw()

func _draw() -> void:
	if not visible: return
	if save_mode:
		for key in [0,31 if category_phase%2==0 else 32,52,53,54,55,56,50,39,33,35]: commands(str(key))
		return
	commands("0")
	for i in 5:
		var desc: Dictionary=layout.categories[i]
		var bg: Array=desc.background
		if int(bg[0])!=0: commands("1",Vector2(bg[0],bg[1]))
		var phase: int=int(desc.sequence[category_phase]) if i==category else 0
		for key in desc.phases[phase]: commands(str(int(key)))
	for key in [2,52,33,35,37,39,41]: commands(str(key))
	for i in mini(5,groups[category].size()-top):
		var item: Dictionary=groups[category][top+i]
		commands("49",Vector2(160,168+i*28))
		var title: String=item.title if not String(item.title).is_empty() else item.source
		while owner_modal.text_width(title)>294: title=title.left(title.length()-1)
		draw_texture(title_image(title,10 if selection==top+i else 1),Vector2(215,168+i*28))
	if groups[category].is_empty(): draw_texture(owner_modal.text_image("No puzzles",1),Vector2(210,200))
	if not error.is_empty(): draw_texture(owner_modal.text_image(error,4),Vector2(245,338))

func title_image(text: String, color: int) -> Texture2D:
	var key:=str(color)+text
	if title_cache.has(key): return title_cache[key]
	var font: Dictionary=owner_modal.font
	var img:=Image.create(maxi(1,owner_modal.text_width(text)),int(font.height),false,Image.FORMAT_RGBA8)
	img.fill(Color.TRANSPARENT)
	var x:=0
	for ch in text:
		var g: Dictionary=font.glyphs.get(ch.unicode_at(0),font.glyphs[32])
		for y in int(g.height):
			for col in int(g.width):
				if g.pixels[y*int(g.width)+col]!=0: img.set_pixel(x+col,y,palette[color])
		x+=int(g.width)
	var texture:=ImageTexture.create_from_image(img)
	title_cache[key]=texture
	return texture
