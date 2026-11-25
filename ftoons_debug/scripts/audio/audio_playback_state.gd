class_name AudioPlaybackState
extends RefCounted

## Logical playback; no AudioServer, node, wall clock, or finished-signal inputs.
## Sample-exact clock with rational PIT conversion for gameplay time.
const CLOCK_HZ := 77616000
const PIT_HZ := 1193182
const PIT_DIVISOR := 5041
const UPDATE_INTERRUPTS := 8 # 1000:24BF..24D6; longer CPU updates remain profile dependent.
const SIMULATION_HZ := float(PIT_HZ)/(PIT_DIVISOR*UPDATE_INTERRUPTS)
const VOICE_COUNT := 8
const DOS_RAW_RATE_HZ := 11025
const RAW_DMA_HALF_BYTES := 5120 # 1E53:0036/3FAC=2801; AUDBLAST:133F halves it.
static var samples: Dictionary = {}
static var rules: Dictionary = {}
var clock: int = 0
var enabled := true
var voices: Array[Dictionary] = []
var loops: Dictionary = {}
var priority := 0
var misc_id := -1
var raw_id := -1 # Class-3000 owner; missing RAW resources use a synth slot.
var microsecond_remainder := 0
var pit_remainder := 0
var update_origin := 0
var external_clock := false

func begin_update_epoch() -> void:
	update_origin=clock

func advance_elapsed_pit(interrupts: int) -> void:
	assert(external_clock and interrupts>=0,"Explicit PIT clock requires external-clock mode")
	advance_elapsed_cycles(interrupts*PIT_DIVISOR)

func advance_elapsed_cycles(cycles: int) -> void:
	assert(external_clock and cycles>=0,"Explicit PIT clock requires external-clock mode")
	var numerator:=cycles*CLOCK_HZ
	advance_to(update_origin+numerator/PIT_HZ)

func _init() -> void:
	if samples.is_empty():
		for path in ["res://assets/original/sound_effect_index.json", "res://assets/original/synth_effect_index.json"]:
			var index = JSON.parse_string(FileAccess.get_file_as_string(path))
			for row in index.get("samples", []): samples[int(row.id)] = row
		rules = JSON.parse_string(FileAccess.get_file_as_string("res://assets/original/audio_dispatch_rules.json")).get("source_handlers", {})
	for i in VOICE_COUNT: voices.append({})

static func dispatch_arguments(source: String, sound_id: int) -> Dictionary:
	if source.contains(" -> "): source = source.left(5) + source.get_slice(" -> ", 1)
	var handler: Dictionary = rules.get(source, {})
	var row = handler.get("sounds", {}).get(str(sound_id), handler.get("default"))
	return {"priority": int(row.get("priority", 0)), "retrigger": bool(row.get("retrigger", false))} if row is Dictionary else {"priority": 0, "retrigger": false}

static func sample_rate(row: Dictionary) -> int:
	# Native AUDBLAST streaming RAW uses its initialized11025 rate, confirmed
	# at3047's accepted return (driver+9F, direct-rate flag+62). The manifest's
	#11000 rates came from Windows WAVE headers, not DOS RAW headers.
	return DOS_RAW_RATE_HZ if String(row.get("resource","")).begins_with("SX_") else int(row.get("sample_rate_hz",11000))

static func raw_source_frames(row: Dictionary) -> int:
	# AUDBLAST:15A3/164C aligns the SOL/WAVE data count to four bytes.
	return int(row.get("frames",row.get("size_bytes",0))) & ~3

static func raw_dma_frames(row: Dictionary) -> int:
	var frames:=raw_source_frames(row)
	# The first short buffer uses its actual DMA length. Streaming through the
	# second half retains a complete final5120-byte block. 17DE..17F5 and1A62
	# fill its unused bytes with80h;1AB9 retires at the hardware block boundary.
	return frames if frames<=RAW_DMA_HALF_BYTES else ((frames+RAW_DMA_HALF_BYTES-1)/RAW_DMA_HALF_BYTES)*RAW_DMA_HALF_BYTES

func advance_to(value: int) -> void:
	assert(value >= clock, "Audio time cannot move backwards; restore a saved state to rewind")
	clock = value
	for i in voices.size():
		if not voices[i].is_empty() and int(voices[i].end) > 0 and int(voices[i].end) <= clock:
			voices[i] = {}
	_cleanup_priority()

func advance_updates(count: int = 1) -> void:
	assert(count >= 0)
	var numerator:=count*CLOCK_HZ*PIT_DIVISOR*UPDATE_INTERRUPTS+pit_remainder
	pit_remainder=numerator%PIT_HZ
	advance_to(clock+numerator/PIT_HZ)

func advance_microseconds(elapsed: int) -> void:
	assert(elapsed >= 0)
	var numerator := elapsed * CLOCK_HZ + microsecond_remainder
	microsecond_remainder = numerator % 1000000
	advance_to(clock + numerator / 1000000)

func advance_to_tick(tick: int) -> void:
	if not external_clock: advance_to(maxi(clock, update_origin+update_time(tick)))

static func update_time(tick: int) -> int:
	return tick*CLOCK_HZ*PIT_DIVISOR*UPDATE_INTERRUPTS/PIT_HZ

static func bank_end_time(now: int, track_ticks: int) -> int:
	# The original server runs once per four PIT interrupts. EOF retires on
	# the following service; all finite bank effects were checked in the VM.
	var period:=CLOCK_HZ*PIT_DIVISOR*4
	var server: int=(now/period)*PIT_HZ+((now%period)*PIT_HZ)/period
	var last:=server+track_ticks+1
	return (last/PIT_HZ)*period+((last%PIT_HZ)*period+PIT_HZ-1)/PIT_HZ

func is_playing(sound_id: int) -> bool:
	if sound_id < 0 or not enabled: return false
	for voice in voices:
		if int(voice.get("id", -1)) == sound_id: return true
	for loop in loops.values():
		if int(loop.id) == sound_id: return true
	return false

func dos_is_playing(sound_id: int) -> bool:
	# 1DD9:072B..073D: with AUDBLAST present, every class-3000 query
	# returns the global RAW cursor (1E53:04C1), without comparing the ID.
	if sound_id >= 3000 and sound_id < 4000:
		if not enabled: return false
		if not voices[0].is_empty():
			var row: Dictionary = samples.get(int(voices[0].id), {})
			if String(row.get("resource", "")).begins_with("SX_"): return true
		# 1DD9:0741 falls back to the requested bank ID if no RAW cursor
		# is active (for example 3095/3106, whose DOS RAW files are absent).
	return is_playing(sound_id)

func duration_units(sound_id: int, pitch_q16: int = 65536) -> int:
	var row: Dictionary = samples.get(sound_id, {})
	if row.is_empty(): return 0
	var duration: int
	# Synth status ends at track completion, before its rendered release tail.
	if row.has("track_ticks") and int(row.id) != 2011:
		var ticks := 0
		for value in row.track_ticks: ticks = maxi(ticks, int(value))
		duration = bank_end_time(clock,ticks)-clock
	else:
		var bytes_per_frame := int(row.get("channels", 1)) * (2 if row.get("encoding", "") == "signed_16_le" else 1)
		var frames: int = int(row.get("frames", int(row.size_bytes) / bytes_per_frame))
		if String(row.get("resource","")).begins_with("SX_"): frames=raw_dma_frames(row)
		var rate := sample_rate(row)
		assert(CLOCK_HZ % rate == 0, "Unsupported audio clock sample rate")
		duration = frames * (CLOCK_HZ / rate)
	return (duration * 65536 + pitch_q16 - 1) / pitch_q16

func play(sound_id: int, owner: int = -1, requested_priority: int = 0, retrigger: bool = false, pitch_q16: int = 65536) -> Dictionary:
	if not enabled: return {"accepted": false, "reason": "effects_disabled"}
	if not samples.has(sound_id): return {"accepted": false, "reason": "missing_pcm"}
	var managed_raw := sound_id >= 3000 and sound_id < 4000
	var digital := managed_raw and String(samples[sound_id].get("resource", "")).begins_with("SX_")
	var misc := sound_id >= 2000 and sound_id < 3000
	if managed_raw or misc:
		var same_id := raw_id == sound_id if managed_raw else misc_id == sound_id
		if not same_id and requested_priority < priority and (is_playing(raw_id) or is_playing(misc_id)):
			return {"accepted": false, "reason": "priority_blocked"}
	if managed_raw and raw_id == sound_id and is_playing(sound_id) and not retrigger:
		priority = 0 # 1DD9:03E5, retained class-3000 path.
		for i in VOICE_COUNT:
			if int(voices[i].get("id", -1)) == sound_id:
				return {"accepted": true, "reason": "already_playing", "voice_index": i}
	var slot := 0 if digital else -1
	if not digital:
		for i in range(1, VOICE_COUNT):
			if int(voices[i].get("id", -1)) == sound_id:
				slot = i
				break
		if slot >= 0 and not retrigger:
			if misc:
				stop(raw_id) if raw_id >= 0 else null
				priority = requested_priority
				misc_id = sound_id
			return {"accepted": true, "reason": "already_playing", "voice_index": slot}
		if slot < 0:
			for i in range(1, VOICE_COUNT):
				if voices[i].is_empty() or ((managed_raw or misc) and int(voices[i].get("id", -1)) == raw_id):
					slot = i
					break
		if slot < 0: return {"accepted": false, "reason": "bank_capacity_blocked"}
	if (managed_raw or misc) and raw_id >= 0: stop(raw_id)
	if managed_raw and misc_id >= 0: stop(misc_id)
	var duration := duration_units(sound_id, pitch_q16)
	voices[slot] = {"id": sound_id, "owner": owner, "start": clock, "end": 0 if bool(samples[sound_id].get("loop", false)) else clock + duration, "pitch_q16": pitch_q16}
	if managed_raw or misc: priority = requested_priority
	if managed_raw: raw_id = sound_id
	if misc: misc_id = sound_id
	return {"accepted": true, "reason": "started", "voice_index": slot}

func stop(sound_id: int = -1, owner: int = -1) -> void:
	for i in voices.size():
		if (sound_id < 0 or int(voices[i].get("id", -1)) == sound_id) and (owner < 0 or int(voices[i].get("owner", -1)) == owner): voices[i] = {}
	_cleanup_priority()

func stop_bank_effects() -> void:
	# 1DD9:0477(-3)->3BEA:3421(-2). RAW has its separate -6 branch.
	for i in range(1,voices.size()): voices[i]={}
	for key in loops.keys():
		var row:Dictionary=samples.get(int(loops[key].id),{})
		if not String(row.get("resource","")).begins_with("SX_"): loops.erase(key)
	_cleanup_priority()

func _cleanup_priority() -> void:
	if not is_playing(misc_id): misc_id = -1
	if not is_playing(raw_id): raw_id = -1
	if raw_id < 0 and misc_id < 0: priority = 0

func set_enabled(value: bool) -> void:
	enabled = value
	if not value:
		stop()
		# Generic loop requests survive mute, like the presentation API. Native
		# Timer is a voice with an explicit stop/restart, not a generic request.

func handle_event(event: Dictionary) -> Dictionary:
	var sound_id := int(event.get("sound_id", -1))
	match String(event.get("action", "play")):
		"play":
			var args := dispatch_arguments(String(event.get("dos_source", "")), sound_id)
			return play(sound_id, int(event.get("part_index", -1)), args.priority, args.retrigger)
		"stop":
			stop(sound_id)
			_stop_loops(sound_id)
		"stop_all":
			stop()
			loops.clear()
		"start":
			if samples.has(sound_id): loops["%d:%d" % [sound_id, int(event.get("part_index", -1))]] = {"id": sound_id, "owner": int(event.get("part_index", -1))}
		"stop_loop": _stop_loops(sound_id, int(event.get("part_index", -1)))
	return {"accepted": true, "reason": "stopped"}

func _stop_loops(sound_id: int, owner: int = -1) -> void:
	for key in loops.keys():
		if (sound_id < 0 or int(loops[key].id) == sound_id) and (owner < 0 or int(loops[key].owner) == owner): loops.erase(key)

func snapshot() -> Dictionary:
	return {"clock": clock, "enabled": enabled, "voices": voices.duplicate(true), "loops": loops.duplicate(true), "priority": priority, "misc_id": misc_id, "raw_id": raw_id, "microsecond_remainder": microsecond_remainder,"pit_remainder":pit_remainder,"update_origin":update_origin,"external_clock":external_clock}

func restore(value: Dictionary) -> void:
	clock = int(value.clock)
	enabled = bool(value.enabled)
	voices.assign(value.voices.duplicate(true))
	loops = value.loops.duplicate(true)
	priority = int(value.priority)
	misc_id = int(value.misc_id)
	raw_id = int(value.get("raw_id", voices[0].get("id", -1)))
	microsecond_remainder = int(value.get("microsecond_remainder", 0))
	pit_remainder = int(value.get("pit_remainder",0))
	update_origin=int(value.get("update_origin",0))
	external_clock=bool(value.get("external_clock",false))

func copy():
	var result = get_script().new()
	result.restore(snapshot())
	return result
