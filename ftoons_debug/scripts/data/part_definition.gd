class_name PartDefinition
extends RefCounted

## Common packed Sid & Al part body. Extra bytes are kept by PuzzleDefinition.

var record_offset: int = 0
var record_size: int = 48
var list_index: int = 0
## Stable identity in a Home Toons document, independent of simulation slots.
var goal_id: String = ""
var part_type: int = 0
var construction_context: String = "campaign"
var flags_1: int = 0
var flags_2: int = 0
var flags_3: int = 0
var appearance: int = 0
var unknown_10: int = 0
var width_1: int = 0
var height_1: int = 0
var width_2: int = 0
var height_2: int = 0
var pos_x: int = 0
var pos_y: int = 0
var behavior: int = 0
var unknown_26: int = 0
var belt_connect_pos_x: int = 0
var belt_connect_pos_y: int = 0
var belt_line_distance: int = 0
var belt_endpoints: Array[int] = []
var unknown_32: int = 0
var rope_1_connect_pos_x: int = 0
var rope_1_connect_pos_y: int = 0
var unknown_36: int = 0
var rope_2_connect_pos_x: int = 0
var rope_2_connect_pos_y: int = 0
var campaign_rope_inventory: bool = false
var rope_slots: Array[Dictionary] = []
var pulley_rope_owner: int = -1
var wire_links_offset: int = 40
var connected_1: int = -1
var connected_2: int = -1
var outlet_plugged_1: int = -1
var outlet_plugged_2: int = -1
var raw_common: PackedByteArray = PackedByteArray()
## Bytes between the common 48-byte prefix and the trailing terminal word.
## These contain version/type dependent fields and remain attached to the part
## for future decoding.
var raw_extension: PackedByteArray = PackedByteArray()
## Final serialized word: DOS authored +AD, copied to live +AF on reset;
## Windows +CB. Holds ammunition, counter value/direction and other settings.
var wire_terminal: int = 0
## Serialized type-46 extra word -> DOS +B1 (Windows +CF), global part index.
var tunnel_partner: int = -1
## Names and offsets for fields that have been mapped from the wire record.
var wire_fields: Dictionary = {}
var packed_gap_after: PackedByteArray = PackedByteArray()
var section: String = ""
var variant: String = "common"
var raw_record: PackedByteArray = PackedByteArray()

func is_fixed() -> bool:
	return (flags_1 & 0x4000) != 0

func is_moving() -> bool:
	return (flags_1 & 0x1000) != 0

func is_in_parts_bin() -> bool:
	# Home Toons saves describe the authored stage. They do not apply the
	# campaign's removal of solution objects lacking flags_3 bit 0x40.
	if construction_context == "home_toons":
		return (flags_1 & 0x0800) != 0
	# 198D:5D59 moves solution-only objects into the bin when +0x0A lacks
	# 0x40. Their original list (fixed/moving) alone does not identify placement.
	return campaign_rope_inventory or (flags_1 & 0x0800) != 0 or ((flags_3 & 0x0040) == 0 and part_type not in [1, 14])

## DOS 16B1:136C reads the live second flag word for sprite mirroring.
func initial_flip_x() -> bool:
	return (flags_2 & 0x0010) != 0

func initial_flip_y() -> bool:
	return (flags_2 & 0x0020) != 0

func rect() -> Rect2:
	return Rect2(pos_x, pos_y, placement_width(), placement_height())

func placement_width() -> int:
	# 7AE2:0000 retains zero wall extents: its right vertices become -1.
	# A zero serialized wall is still a placed, collision-active object.
	if part_type in [26,27,28,29,82,83]:
		return width_1 >> 8 if width_1 > 1024 else width_1
	return maxi(1, width_1 >> 8) if width_1 > 1024 else maxi(1, width_1)

func placement_height() -> int:
	if part_type in [26,27,28,29,82,83]:
		return height_1 >> 8 if height_1 > 1024 else height_1
	return maxi(1, height_1 >> 8) if height_1 > 1024 else maxi(1, height_1)

func category() -> String:
	if is_in_parts_bin():
		return "parts-bin"
	if is_fixed():
		return "fixed"
	if is_moving():
		return "moving"
	return "unclassified"
