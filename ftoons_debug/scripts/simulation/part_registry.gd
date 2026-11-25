class_name PartRegistry
extends RefCounted

## Behavior hooks are intentionally small until per-type dispatch is recovered.
## The default hook preserves state; fixed-point integration is in the runner.

class PartBehavior:
	func acceleration(_part: SimulationState.SimPart, _puzzle: PuzzleDefinition) -> Vector2i:
		return Vector2i.ZERO

	func on_contact(_part: SimulationState.SimPart, _other: SimulationState.SimPart, _state: SimulationState) -> void:
		pass

var _behaviors: Dictionary = {}
var _default := PartBehavior.new()

func register(part_type: int, behavior: PartBehavior) -> void:
	_behaviors[part_type] = behavior

func behavior_for(part_type: int) -> PartBehavior:
	return _behaviors.get(part_type, _default)
