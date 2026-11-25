class_name NativeStateContract
extends RefCounted

## Typed projection of the native object WORD +0C, independent of rendering.
## The caller supplies the saved +99 selector from the construction path.
## Do not infer it from an animated appearance or a factory default.
## Source evidence and integration contract: docs/NATIVE_SELECTOR_CONTRACT.md.
const SAVED_SELECTOR_KEY := "native_saved_selector_99"
const LATCHED_STATE_KEY := "native_latched_state_0c"
const SAVED_SOURCE_KEY := "native_saved_selector_source"
const LATCHED_SOURCE_KEY := "native_latched_state_source"
const PREPARED_KEY := "native_run_reset_prepared"
const SELECTOR_KEY := SAVED_SELECTOR_KEY
const PROVENANCE_KEY := SAVED_SOURCE_KEY
const SELECTOR_TYPES := [0, 2, 3, 17, 38, 47, 48, 49, 50, 51, 59, 60, 61, 63, 84]
const LIVE_COUNTER_TYPES := [41]

static func signed_word(value: int) -> int:
	var word := value & 0xffff
	return word - 0x10000 if word >= 0x8000 else word

static func supported(type_id: int) -> bool:
	return type_id in SELECTOR_TYPES or type_id in LIVE_COUNTER_TYPES

static func seed_selector(p: SimulationState.SimPart, selector: int, source: String) -> bool:
	# Explicit provenance is mandatory: a missing constructor translation must
	# remain visible, rather than being hidden by current-frame equality.
	if not supported(p.part_type) or source.is_empty(): return false
	var value := signed_word(selector)
	p.reaction_data[SELECTOR_KEY] = value
	p.reaction_data[PROVENANCE_KEY] = source
	p.reaction_data[LATCHED_STATE_KEY] = value
	p.reaction_data[LATCHED_SOURCE_KEY] = source
	if p.part_type in LIVE_COUNTER_TYPES:
		# 5D96:0117 clears this on activation; 017A increments it to3.
		# Keep the production counter authoritative for every later update.
		p.state = value
	return true

static func write_saved_selector(p: SimulationState.SimPart, selector: int, source: String, also_latch: bool=false) -> bool:
	if not supported(p.part_type) or source.is_empty(): return false
	if not p.reaction_data.has(LATCHED_STATE_KEY): return seed_selector(p,selector,source)
	var value:=signed_word(selector)
	p.reaction_data[SAVED_SELECTOR_KEY]=value
	p.reaction_data[SAVED_SOURCE_KEY]=source
	if also_latch:
		p.reaction_data[LATCHED_STATE_KEY]=value
		p.reaction_data[LATCHED_SOURCE_KEY]=source
		if p.part_type in LIVE_COUNTER_TYPES: p.state=value
	p.reaction_data.erase(PREPARED_KEY)
	return true

static func begin_reset(p: SimulationState.SimPart) -> bool:
	if not supported(p.part_type) or not p.reaction_data.has(SAVED_SELECTOR_KEY): return false
	var value:=signed_word(int(p.reaction_data[SAVED_SELECTOR_KEY]))
	if int(p.reaction_data.get(LATCHED_STATE_KEY,value+1))!=value:
		p.reaction_data[LATCHED_SOURCE_KEY]="1000:8B22/8B2C latch: "+String(p.reaction_data.get(SAVED_SOURCE_KEY,""))
	p.reaction_data[LATCHED_STATE_KEY]=value
	if p.part_type in LIVE_COUNTER_TYPES: p.state=value
	return true

static func finish_reset(p: SimulationState.SimPart) -> void:
	#8BFA stores the constructor result for the NEXT reset; +0C stays latched.
	if not supported(p.part_type) or not p.reaction_data.has(LATCHED_STATE_KEY): return
	if int(p.reaction_data.get(SAVED_SELECTOR_KEY,p.appearance+1))!=signed_word(p.appearance):
		p.reaction_data[SAVED_SOURCE_KEY]="1000:8BF1/8BFA constructor result"
	p.reaction_data[SAVED_SELECTOR_KEY]=signed_word(p.appearance)
	p.reaction_data[PREPARED_KEY]=true

static func metadata(p: SimulationState.SimPart) -> Dictionary:
	var result: Dictionary={}
	for key in [SAVED_SELECTOR_KEY,LATCHED_STATE_KEY,SAVED_SOURCE_KEY,LATCHED_SOURCE_KEY]:
		if p.reaction_data.has(key): result[key]=p.reaction_data[key]
	return result

static func restore_metadata(p: SimulationState.SimPart, values: Dictionary) -> void:
	for key in values: p.reaction_data[key]=values[key]
	if p.part_type in LIVE_COUNTER_TYPES and values.has(LATCHED_STATE_KEY):
		p.state=signed_word(int(values[LATCHED_STATE_KEY]))

static func seed_runtime(runtime: SimulationState, selectors: Dictionary, source: String) -> bool:
	# A pause/resume at updateN is not a new construction/reset boundary.
	if runtime.tick != 0 or source.is_empty(): return false
	for identity in selectors:
		if not identity is int or identity < 0 or identity >= runtime.parts.size(): return false
		if not selectors[identity] is int or not supported(runtime.parts[identity].part_type): return false
	for identity in selectors:
		seed_selector(runtime.parts[identity],int(selectors[identity]),source)
	return true

static func projection(p: SimulationState.SimPart) -> Dictionary:
	var result := {
		"value": signed_word(p.state),
		"raw_state": p.state,
		"semantics": "runtime_state",
		"supported": supported(p.part_type),
		"initialized": false,
		"source": "",
	}
	if not result.supported: return result
	if not p.reaction_data.has(SAVED_SELECTOR_KEY) or not p.reaction_data.has(LATCHED_STATE_KEY):
		result.semantics = "unseeded_native_reset_selector"
		return result
	result.initialized = true
	result.source = String(p.reaction_data.get(LATCHED_SOURCE_KEY, ""))
	result.reset_selector = signed_word(int(p.reaction_data[LATCHED_STATE_KEY]))
	result.saved_selector = signed_word(int(p.reaction_data[SAVED_SELECTOR_KEY]))
	result.saved_source = String(p.reaction_data.get(SAVED_SOURCE_KEY, ""))
	if p.part_type in LIVE_COUNTER_TYPES:
		result.semantics = "native_live_transition_counter_0c"
	else:
		result.value = result.reset_selector
		result.semantics = "native_reset_selector_0c"
	return result
