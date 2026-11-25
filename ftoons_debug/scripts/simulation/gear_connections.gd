class_name GearConnections
extends RefCounted

## 7939:0160 rebuilds +63/+65/+67/+69 from saved +95/+97 positions.
## This is mechanical adjacency, not the still-unverified editor placement rule.
static func rebuild(state: SimulationState) -> void:
	var gears: Array[SimulationState.SimPart]=[]
	for index in state.query_chains.get(0x2000,[]):
		var p:=state.parts[int(index)]
		if p.part_type==18 and p.placed and p.active:
			p.links.assign([-1,-1,-1,-1])
			gears.append(p)
	for p in gears:
		for other in gears:
			if p==other: continue
			var delta:=p.list_position-other.list_position
			if delta==Vector2i(32,0): p.links[0]=other.index
			elif delta==Vector2i(-32,0): p.links[1]=other.index
			elif delta==Vector2i(0,32): p.links[2]=other.index
			elif delta==Vector2i(0,-32): p.links[3]=other.index
