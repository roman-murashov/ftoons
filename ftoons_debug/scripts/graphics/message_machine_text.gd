class_name MessageMachineText
extends RefCounted

## 5F1E:01B5 + 728C:08DA/096B. Original font, centering, cardinal
## black outline and position-dependent multicolor character selection.
const Formats=preload("res://scripts/graphics/dynamix_formats.gd")
const COLORS: Array[int]=[4,10,14,15,12] # raw main DS:0AEC
# Captured gameplay drawing offset (-DS:4709, -DS:4707). Godot omits
# the toolbar but must retain this offset in DOS's color-selection formula.
const DOS_SCREEN_OFFSET:=Vector2i(91,8)
var font: Dictionary={}
var palette: Array=[]
var cache: Dictionary={}

func _init(catalog: ResourceCatalog,colors: Array) -> void:
	font=Formats.decode_font(catalog.read_asset("TUXEDO.FNT"))
	palette=colors

func resolve(character: int,part_position: Vector2i) -> Dictionary:
	if not font.get("ok",false) or palette.size()<256: return {}
	var glyph: Dictionary=font.glyphs.get(character,{})
	if glyph.is_empty() or int(glyph.width)==0: return {}
	var width:=int(glyph.width)
	var height:=int(glyph.height)
	var offset:=Vector2i(26-width/2,30-height/2)
	var screen:=part_position+offset+DOS_SCREEN_OFFSET
	var color_index:=((character^screen.x^screen.y)&0xffff)%5
	# 728C:0A4C excludes background palette 12, retrying the next index.
	if COLORS[color_index]==12: color_index=(color_index+1)%5
	var color:=COLORS[color_index]
	var key:="%d/%d"%[character,color]
	if not cache.has(key):
		var image:=Image.create(width+2,height+2,false,Image.FORMAT_RGBA8)
		image.fill(Color.TRANSPARENT)
		var mask: PackedByteArray=glyph.pixels
		for y in height:
			for x in width:
				if mask[y*width+x]==0: continue
				for delta in [Vector2i.LEFT,Vector2i.RIGHT,Vector2i.UP,Vector2i.DOWN]:
					image.set_pixel(x+1+delta.x,y+1+delta.y,palette[0])
		for y in height:
			for x in width:
				if mask[y*width+x]!=0: image.set_pixel(x+1,y+1,palette[color])
		cache[key]=ImageTexture.create_from_image(image)
	return {"texture":cache[key],"position":Vector2(offset-Vector2i.ONE),"color":color}
