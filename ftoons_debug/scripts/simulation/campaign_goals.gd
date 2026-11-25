extends "res://scripts/data/original_goal_catalog.gd"
## Native 7B09 goal callbacks, evaluated after object updates by 1000:246B.
## Native expressions are trusted program data. Home Toons declares typed conditions.
const Authored = preload("res://scripts/simulation/authored_goals.gd")
const NULL_GHOST_TARGET_CALLBACKS := ["7B09:0C48", "7B09:0CE7"]

static func reset(puzzle: PuzzleDefinition, state: SimulationState) -> void:
	var enabled := (puzzle.campaign_goal_index >= 0 or not puzzle.head_to_head_goal.is_empty()) and puzzle.construction_context == "campaign"
	enabled = enabled or not puzzle.authored_goals.is_empty()
	state.goal = {"enabled":enabled,"initialized":false,"callback":"","countdown":-1,
		"trigger_tick":-1,"completion_tick":-1,"completed":false,"completed_date":"",
		"bindings":{},"vars":{},"error":""}

static func advance(puzzle: PuzzleDefinition, state: SimulationState, events: Array = []) -> void:
	var goal := state.goal
	if not goal.get("enabled",false) or goal.get("completed",false): return
	if int(goal.countdown) < 0:
		var authored := puzzle.authored_goals
		if authored.has("when"):
			if not goal.initialized: Authored.bind(authored, state)
			if not String(goal.error).is_empty(): return
			if Authored.satisfied(authored.when, state, events):
				goal.countdown = int(authored.delay_updates)
				goal.trigger_tick = state.tick
		else:
			var spec := _spec(puzzle)
			if spec.is_empty():
				goal.error = "Missing original goal specification"
				return
			evaluate_callback(spec,state)
		if not String(goal.error).is_empty(): return
	# DOS decrements on the triggering update; completion happens after the
	# next full update that observes zero. Never re-check an armed predicate.
	if int(goal.countdown) == 0:
		goal.completed = true
		goal.completion_tick = state.tick
		state.running = false
	elif int(goal.countdown) > 0:
		goal.countdown = int(goal.countdown)-1

static func evaluate_callback(spec: Dictionary, state: SimulationState) -> void:
	var goal:=state.goal
	# The original initializer is tick==0, not a once-per-process guard.
	# A still-pending goal rebinds and clears latches on uint16 tick wrap.
	if not goal.initialized or ((state.tick-1)&65535)==0: _bind(spec,state)
	if not String(goal.error).is_empty(): return
	# MPC callbacks that search each update can observe newly spawned objects.
	# Most objectives deliberately retain their tick-zero references instead.
	for name in spec.selectors:
		var selector: Dictionary = spec.selectors[name]
		if selector.get("live",false):
			var ordinal:=0
			goal.bindings[name]=-1
			for id in state.query_chains.get(int(selector.get("mask",4096)),[]):
				if id<0 or id>=state.parts.size() or state.parts[id].part_type!=int(selector.type): continue
				ordinal+=1
				if ordinal==int(selector.get("nth",1)):
					goal.bindings[name]=int(id)
					break
	for rule in spec.get("rules",[]):
		if _truth(_eval(rule.when,state)):
			goal.vars[String(rule.set)] = _eval(rule.get("value",1),state)
	if _truth(_eval(spec.condition,state)):
		goal.countdown = int(spec.delay)
		goal.trigger_tick = state.tick

static func _spec(puzzle: PuzzleDefinition) -> Dictionary:
	if puzzle.authored_goals.has("original"):
		return original_spec(puzzle.authored_goals.original)
	if not puzzle.head_to_head_goal.is_empty(): return puzzle.head_to_head_goal
	return dos_spec(puzzle.campaign_goal_index)

static func _bind(spec: Dictionary, state: SimulationState) -> void:
	state.goal.initialized = true
	state.goal.error = ""
	state.goal.callback = String(spec.get("address",spec.get("callback","")))
	state.goal.vars = spec.get("vars",{}).duplicate(true)
	state.goal.null_fields=spec.get("null_fields",{}).duplicate()
	state.goal.null_target_fields=spec.get("null_target_fields",{}).duplicate()
	state.goal.null_bindings=[]
	for name in spec.selectors:
		var selector: Dictionary = spec.selectors[name]
		var ordered: Array = state.query_chains.get(int(selector.get("mask",4096)),[])
		var ids: Array[int] = []
		for id in ordered:
			if id>=0 and id<state.parts.size() and state.parts[id].part_type==int(selector.type): ids.append(int(id))
		var selected: Variant = -1
		if selector.get("kind","")=="all": selected=ids
		elif selector.get("kind","")=="rope_balloon":
			# 0241 starts with nth0 (head only), then visits typed ordinals.
			if not ordered.is_empty() and state.parts[int(ordered[0])].part_type==23:
				for id in ids:
					if _has_rope(state,id): selected=id; break
		else:
			var ordinal:=int(selector.get("nth",1))
			if ordinal==0:
				if not ordered.is_empty() and state.parts[int(ordered[0])].part_type==int(selector.type): selected=int(ordered[0])
			elif ordinal<=ids.size(): selected=ids[ordinal-1]
		state.goal.bindings[name]=selected
		if selected is int and selected<0:
			if selector.get("allow_null",false): state.goal.null_bindings.append(name)
			else: state.goal.error="Goal target is missing: "+String(name)

static func _has_rope(state: SimulationState, id: int) -> bool:
	# Native +6F is the primary endpoint attachment, not arbitrary membership
	# in a routed rope or the secondary endpoint slot at +71.
	return RopePhysics.has_primary_connection(state,state.parts[id])

static func _eval(expression: Variant, state: SimulationState, current: int=-1) -> Variant:
	if not expression is Array: return expression
	if expression.is_empty(): return null
	var op:=String(expression[0])
	if op=="tick": return (state.tick-1)&65535
	if op=="var": return state.goal.vars.get(String(expression[1]),0)
	if op=="missing": return int(state.goal.bindings.get(String(expression[1]),-1))<0
	if op=="field":
		var key: Variant=expression[1]
		var id: Variant
		if key is Array:
			id=_eval(key,state,current)
			# BRAN16/LOON1 inspect Al's +B1 target type during knockout,
			# before its ghost is born. Native null near0 reads DS:0004=6F42
			# ("Bo"), which is not type36. Preserve only that proven read;
			# missing required selectors, other fields and invalid IDs still
			# have no value. In particular, do not convert all nulls to false.
			if id is int and id==-1 and key.size()==3 and key[0]=="field" and key[2]=="target" and String(expression[2])=="type" and NULL_GHOST_TARGET_CALLBACKS.has(state.goal.callback):
				var null_type: Variant=state.goal.get("null_target_fields",{}).get("type")
				if null_type is int or null_type is float:
					if int(null_type)==0x6f42: return 0x6f42
		elif key is String:
			id=current if key=="$" else state.goal.bindings.get(key,-1)
			# LOON18's original six-Fish predicate has only four real targets.
			# Its two null reads see DS:0008=6E61 (the Borland signature), not0.
			# Preserve that verified quirk only for explicitly exported slots.
			if id is int and id<0 and state.goal.get("null_bindings",[]).has(key):
				return state.goal.get("null_fields",{}).get(String(expression[2]))
		else: id=key
		if id==null or not (id is int or id is float) or int(id)<0 or int(id)>=state.parts.size(): return null
		return _field(state.parts[int(id)],String(expression[2]),state)
	if op=="every":
		for id in state.goal.bindings.get(String(expression[1]),[]):
			if not _truth(_eval(expression[2],state,int(id))): return false
		return true
	if op=="all":
		for item in expression.slice(1):
			if not _truth(_eval(item,state,current)): return false
		return true
	if op=="any":
		for item in expression.slice(1):
			if _truth(_eval(item,state,current)): return true
		return false
	var a: Variant=_eval(expression[1],state,current)
	if a==null: return null
	if op=="not": return not bool(a)
	var b: Variant=_eval(expression[2],state,current)
	if b==null: return null
	match op:
		"eq": return a==b
		"ne": return a!=b
		"lt": return a<b
		"le": return a<=b
		"gt": return a>b
		"ge": return a>=b
		"bit": return (int(a)&int(b))!=0
		"and": return int(a)&int(b)
		"add": return int(a)+int(b)
		"sub": return int(a)-int(b)
	return null

static func _truth(value: Variant) -> bool:
	return value!=null and bool(value)

static func _field(p: SimulationState.SimPart, key: String, state: SimulationState) -> Variant:
	if key == "rope": return int(_has_rope(state,p.index))
	return p.goal_value(key)
