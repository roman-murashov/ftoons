extends RefCounted
## New rooms start with the Home Toons part bin and an empty stage.
const Document := preload("res://scripts/io/home_toons_document.gd")

static func blank() -> Dictionary:
	return {"format":Document.FORMAT, "version":Document.VERSION, "gravity":272, "pressure":67,
		"music":0, "title":"", "goal":"", "parts":[], "ropes":[], "belts":[]}

static func piece(doc: Dictionary, id: String, type: int, pos: Vector2i,
		pinned := true, extent := Vector2i.ZERO) -> Dictionary:
	var row := Document.factory_row(type, id)
	row.pos_x = pos.x
	row.pos_y = pos.y
	if pinned: row.flags_3 = int(row.flags_3) | 0x40
	if extent != Vector2i.ZERO:
		row.width_1 = extent.x
		row.height_1 = extent.y
		# Tunnels have a separate, fixed native sprite width.
		if type != 46: row.width_2 = extent.x
		row.height_2 = extent.y
	doc.parts.append(row)
	return row
