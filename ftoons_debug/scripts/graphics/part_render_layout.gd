class_name PartRenderLayout
extends RefCounted

## Frame roles and component positions from DOS 16B1:109F/136C.
var _types: Dictionary = {}
var _reaction_data := ReactionTables.new()

func _init() -> void:
	var file := FileAccess.open("res://assets/original/part_render_tables.json", FileAccess.READ)
	if file != null:
		var parsed = JSON.parse_string(file.get_as_text())
		if parsed is Dictionary:
			_types = parsed.get("types", {})

func body_commands(part: PartDefinition, dimensions: Vector2, runtime_appearance: int = -1, runtime_settings: int = -1) -> Array[Dictionary]:
	var commands: Array[Dictionary] = []
	var metadata: Dictionary = _types.get(str(part.part_type), {})
	var repeats := int(metadata.get("repeat_count", 0))
	var layers: Array = metadata.get("layers", [5, 255])
	var layer := int(layers[0])
	if part.part_type == 0:
		return _conveyor_commands(dimensions, runtime_appearance if runtime_appearance >= 0 else part.appearance, layer)
	if part.part_type == 40:
		return _thumpulator_commands(dimensions, runtime_settings if runtime_settings >= 0 else part.wire_terminal, metadata, layer)
	if (part.flags_1 & 0x40) != 0 and repeats > 0:
		var cell_width := 32 if part.part_type == 45 else 16
		var columns := int(dimensions.x) / cell_width
		var rows := int(dimensions.y) / 16
		var counter := 0
		for row in range(rows):
			for column in range(columns):
				var frame := runtime_appearance if runtime_appearance >= 0 else part.appearance
				if rows == 1:
					if column == columns - 1 and column > 0:
						frame += repeats + 1
					elif column > 0:
						frame += 1 + counter % repeats
						counter += 1
				elif columns == 1:
					if row == 0:
						frame += repeats + 2
					elif row == rows - 1:
						frame += repeats * 2 + 3
					else:
						frame += repeats + 3 + counter % repeats
						counter += 1
				commands.append({"frame": frame, "position": Vector2(column * cell_width, row * 16), "layer": layer, "tiled": true})
		return commands
	var states: Array = metadata.get("states", [])
	var appearance := runtime_appearance if runtime_appearance >= 0 else part.appearance
	# Message machines draw the backing screen before their curtains/hook.
	# The custom draw routine is in ovr_056 at original file offset 0x55595.
	if part.part_type == 42:
		commands.append({"frame": 0, "position": Vector2.ZERO, "layer": layer, "tiled": false, "unmirrored": true})
		# 5F1E:01B5 draws the AF character before the curtain components.
		var setting:=runtime_settings if runtime_settings>=0 else part.wire_terminal
		commands.append({"kind":"message_letter","character":setting&255,"frame":-1,"position":Vector2.ZERO,"layer":layer,"tiled":false,"unmirrored":true})
	if ((part.flags_2 & 0x1000) != 0 or part.part_type in [36,37]) and appearance >= 0 and appearance < states.size():
		for component in states[appearance]:
			commands.append({"frame": int(component.frame), "position": Vector2(component.x, component.y), "layer": int(component.layer), "tiled": false})
	else:
		commands.append({"frame": appearance, "position": Vector2.ZERO, "layer": layer, "tiled": false})
	if part.part_type==39:
		# 5DB1:030D draws direction markers and decimal digits after the
		# component layout. Positions are per-digit tables, not font metrics.
		var setting:=runtime_settings if runtime_settings>=0 else part.wire_terminal
		commands.append({"frame":21 if setting&0x4000 else 22,"position":Vector2(21,9),"layer":layer,"tiled":false,"unmirrored":true})
		commands.append({"frame":22 if setting&0x4000 else 21,"position":Vector2(66,12),"layer":layer,"tiled":false,"unmirrored":true})
		var number: int=(setting&0xbfff)%100
		for digit in [[number%10,0x1b3c],[number/10,0x1b50]]:
			var index:=int(digit[0])
			var base:=int(digit[1])+index*2
			commands.append({"frame":index,"position":Vector2(_reaction_data.u8(base)+1,_reaction_data.u8(base+1)),"layer":layer,"tiled":false,"unmirrored":true})
	return commands

func _thumpulator_commands(dimensions: Vector2, settings: int, metadata: Dictionary, layer: int) -> Array[Dictionary]:
	# Custom draw 5E33:0732..0A2C. Appearance is not its animation selector:
	# live +AF holds section count, active section, button presses and phase.
	if settings == 0:
		settings = clampi((int(dimensions.y) - 26) / 65, 0, 5) << 4
	var count := (settings >> 4) & 15
	var active_section := settings & 15
	var phase := (settings >> 10) & 7
	var top_pressed := (settings & 0x100) != 0
	var bottom_pressed := (settings & 0x200) != 0
	var commands: Array[Dictionary] = []
	commands.append({"frame": 1 if top_pressed else 0, "position": Vector2(0, 5 if top_pressed else 0), "layer": layer, "tiled": false})
	var states: Array = metadata.get("states", [])
	for section in count:
		var section_phase := phase if section == active_section else 0
		if section_phase >= states.size():
			continue
		var y := 17 + section * 65
		for component in states[section_phase]:
			commands.append({"frame": int(component.frame), "position": Vector2(component.x, y + int(component.y)), "layer": int(component.layer), "tiled": false})
		# Each third section changes the figure on the moving platform.
		# DOS reads signed x/y/frame triples, then adds a phase-dependent x.
		var figure := 0x1e49 + (section % 3) * 3
		commands.append({"frame": _reaction_data.s8(figure + 2), "position": Vector2(_reaction_data.s8(figure) + _reaction_data.s8(0x1e52 + section_phase), y + _reaction_data.s8(figure + 1)), "layer": layer, "tiled": false})
	commands.append({"frame": 6 if bottom_pressed else 7, "position": Vector2(19 if top_pressed else 21, 17 + count * 65), "layer": layer, "tiled": false})
	# Native +45 + +4D equals the logical 102px width even when extended
	# and mirrored (-40 + 142). PuzzleCanvas's normal X pivot is therefore
	# also correct for these custom sprites and the compositor components.
	return commands

func _conveyor_commands(dimensions: Vector2, appearance: int, layer: int) -> Array[Dictionary]:
	# Custom draw callback 799D:01BD (raw 699D:01BD), not the wall tiler.
	# Original data 340F:4820/4826/482C selects left/right/middle sprites
	# for the six live appearances. Each column advances 16px; height does
	# not create more rows. Sprite mask zero ignores the object's flip bits.
	var commands: Array[Dictionary] = []
	var columns := int(dimensions.x) >> 4
	var phase := posmod(appearance, 6)
	var middle_count := 0
	var y_offset := 0
	for column in columns:
		var frame: int
		if column == 0:
			frame = _reaction_data.u8(0x4820 + phase)
		elif column == columns - 1:
			frame = _reaction_data.u8(0x4826 + phase)
		else:
			frame = _reaction_data.u8(0x482c + phase)
			if frame == 4 and middle_count % 2 == 1:
				frame = 5
			y_offset = 1 if frame == 6 and middle_count % 2 == 1 else 0
			middle_count += 1
		# 799D:0249..0290 deliberately retains the last middle tile's y
		# offset when drawing the right cap. It is not reset at that branch.
		commands.append({"frame": frame, "position": Vector2(column * 16, y_offset), "layer": layer, "tiled": true})
	return commands
