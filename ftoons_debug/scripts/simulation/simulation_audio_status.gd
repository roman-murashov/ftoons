extends RefCounted

## Compatibility view for existing simulation/native diagnostics. All decisions
## use AudioPlaybackState; digital_sound is a derived display, never a clock.
const Playback = preload("res://scripts/audio/audio_playback_state.gd")
const UPDATES_PER_SECOND := Playback.SIMULATION_HZ

static func playing(state: SimulationState, sound_id: int) -> bool:
	state.audio.advance_to_tick(state.tick)
	sync(state)
	return state.audio.dos_is_playing(sound_id)

static func play(state: SimulationState, sound_id: int, source: String) -> void:
	state.audio.advance_to_tick(state.tick)
	state.audio.handle_event({"sound_id": sound_id, "dos_source": source, "action": "play"})
	sync(state)

static func stop(state: SimulationState, sound_id: int) -> void:
	state.audio.stop(sound_id)
	sync(state)

static func sync(state: SimulationState) -> void:
	var digital: Dictionary = state.audio.voices[0]
	if digital.is_empty():
		state.digital_sound.clear()
		return
	var units_per_update: int = Playback.CLOCK_HZ / UPDATES_PER_SECOND
	state.digital_sound = {"id": int(digital.id), "priority": state.audio.priority,
		"until": (int(digital.end) + units_per_update - 1) / units_per_update}
