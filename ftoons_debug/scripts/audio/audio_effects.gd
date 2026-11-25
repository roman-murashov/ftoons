extends Node

const PlaybackState = preload("res://scripts/audio/audio_playback_state.gd")
const ResourceCatalogType = preload("res://scripts/io/resource_catalog.gd")
const SOUND_INDEX_PATH := "res://assets/original/sound_effect_index.json"
const BANK_INDEX_PATH := "res://assets/original/synth_effect_index.json"
const DISPATCH_RULES_PATH := "res://assets/original/audio_dispatch_rules.json"
const VOICE_COUNT := 8 # One digital channel and seven native synth slots.

var effects_enabled := true
var effects_volume_db := 0.0

var _catalog
var _sample_entries: Dictionary = {}
var _sample_cache: Dictionary = {}
var _loop_stream_cache: Dictionary = {}
var _warned_missing: Dictionary = {}
var _voices: Array[AudioStreamPlayer] = []
var _loop_players: Dictionary = {}
var _desired_loops: Dictionary = {}
var _voice_sample_ids: Array[int] = []
var _voice_owner_ids: Array[int] = []
var _voice_volume_offsets: Array[float] = []
var _playback: PlaybackState
var _simulation_clock := false
var _simulation_snapshot: Dictionary = {}
var _preview_usec: int = 0
var last_play_result: Dictionary = {}
var shared_opl


func _ready() -> void:
	if ImportedResources.dos_ready:
		initialize_audio()
	else:
		set_process(false)
		ImportedResources.dos_mounted.connect(initialize_audio, CONNECT_ONE_SHOT)

func initialize_audio() -> void:
	_playback = PlaybackState.new()
	_catalog = ResourceCatalogType.new()
	_load_sample_index()
	_create_voices()
	shared_opl=preload("res://scripts/audio/shared_opl.gd").new()
	add_child(shared_opl)
	set_process(true)

func _uses_shared_opl(sound_id: int) -> bool:
	var row:Dictionary=_sample_entries.get(sound_id,{})
	return shared_opl!=null and shared_opl.enabled and not shared_opl.failed and (row.has("track_ticks") or String(row.get("resource","")).begins_with("SX_")) and sound_id!=2011


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	if not _simulation_clock and _preview_usec > 0:
		_playback.advance_microseconds(now - _preview_usec)
		_sync_players()
	_preview_usec = now


func sync_simulation_audio(playback: Dictionary) -> void:
	_simulation_clock = true
	_simulation_snapshot = playback.duplicate(true)
	_playback.restore(playback)
	_sync_players()

func playback_snapshot() -> Dictionary:
	return _playback.snapshot()


func play_sample(sound_id: int, source_part_index: int = -1, volume_db: float = 0.0, pitch_scale: float = 1.0, priority: int = 0, retrigger: bool = false) -> bool:
	# Direct UI previews use elapsed time; simulation requests carry their own
	# explicit clock. Neither path uses player.playing to decide acceptance.
	_simulation_clock = false
	_playback.set_enabled(effects_enabled)
	_preview_usec = Time.get_ticks_usec()
	return _play_sample(sound_id, source_part_index, volume_db, pitch_scale, priority, retrigger)


func _play_sample(sound_id: int, owner: int, volume_db: float, pitch_scale: float, priority: int, retrigger: bool) -> bool:
	var pitch := clampf(pitch_scale, 0.25, 4.0)
	var before := _playback.voices.duplicate(true)
	last_play_result = _playback.play(sound_id, owner, priority, retrigger, int(round(pitch * 65536.0)))
	_sync_players()
	if not last_play_result.accepted: return false
	# Mirror explicit dispatch preemption, including a RAW cue replaced by a
	# legacy PCM menu cue. Natural sequencer retirement keeps its release tail.
	for prior in before:
		var old_id := int(prior.get("id", -1))
		if old_id >= 0 and old_id != sound_id and not _playback.is_playing(old_id) and _uses_shared_opl(old_id):
			shared_opl.request({"op":"stop","id":old_id})
	if not effects_enabled: return true # Presentation mute cannot change a supplied simulation decision.
	if last_play_result.reason == "already_playing": return true
	if _uses_shared_opl(sound_id):
		shared_opl.request({"op":"play","id":sound_id,"retrigger":retrigger})
		return true
	var slot := int(last_play_result.voice_index)
	var stream := _get_sample(sound_id)
	if stream == null:
		_playback.stop(sound_id)
		_sync_players()
		last_play_result = {"accepted": false, "reason": "missing_pcm"}
		return false
	var voice := _voices[slot]
	voice.stop()
	voice.stream = stream
	voice.volume_db = clampf(effects_volume_db + volume_db, -80.0, 12.0)
	voice.pitch_scale = pitch
	_voice_volume_offsets[slot] = volume_db
	voice.play()
	return true


func _sync_players() -> void:
	for i in _voices.size():
		var logical: Dictionary = _playback.voices[i]
		var sound_id := int(logical.get("id", -1))
		var owner := int(logical.get("owner", -1))
		# The sequencer retires its track before the OPL carrier's release
		# envelope finishes. Keep the rendered tail until natural completion or
		# a new allocation of this hardware slot. RAW has no separate envelope.
		if sound_id<0 and _voices[i].playing:
			var previous: Dictionary=_sample_entries.get(_voice_sample_ids[i],{})
			if previous.has("track_ticks") and not bool(previous.get("loop",false)):
				continue
		if sound_id < 0 or _voice_sample_ids[i] != sound_id or _voice_owner_ids[i] != owner:
			_voices[i].stop()
			_voice_volume_offsets[i] = 0.0
		_voice_sample_ids[i] = sound_id
		_voice_owner_ids[i] = owner


func is_sample_playing(sound_id: int) -> bool:
	return _playback.is_playing(sound_id)


func stop_sample(sound_id: int = -1, source_part_index: int = -1) -> void:
	if shared_opl!=null and shared_opl.enabled:
		if sound_id<0:
			shared_opl.request({"op":"stop_effects"})
			shared_opl.request({"op":"stop_raw"})
		elif _uses_shared_opl(sound_id): shared_opl.request({"op":"stop","id":sound_id})
	_playback.stop(sound_id, source_part_index)
	# Explicit native key-off/Stop must also silence a retired track's tail.
	for i in _voices.size():
		if (sound_id<0 or _voice_sample_ids[i]==sound_id) and (source_part_index<0 or _voice_owner_ids[i]==source_part_index):
			_voices[i].stop()
	_sync_players()


func play_loop(sound_id: int, source_part_index: int = -1, volume_db: float = 0.0) -> bool:
	var key := _loop_key(sound_id, source_part_index)
	_desired_loops[key] = {"sound_id": sound_id, "part_index": source_part_index, "volume_db": volume_db}
	return _ensure_loop_player(key)


func _ensure_loop_player(key: String) -> bool:
	if not effects_enabled:
		return false
	if _desired_loops.has(key) and _uses_shared_opl(int(_desired_loops[key].sound_id)):
		shared_opl.request({"op":"play","id":int(_desired_loops[key].sound_id)})
		return true
	if _loop_players.has(key):
		var existing: AudioStreamPlayer = _loop_players[key]
		if existing.playing:
			return true
		_loop_players.erase(key)
	var request: Dictionary = _desired_loops.get(key, {})
	if request.is_empty():
		return false
	var sound_id := int(request.sound_id)
	var source_part_index := int(request.part_index)
	var stream := _get_loop_sample(sound_id)
	if stream == null:
		return false
	var player := AudioStreamPlayer.new()
	if OS.has_feature("web"): player.playback_type=AudioServer.PLAYBACK_TYPE_STREAM
	player.name = "Sustained_%d_%d" % [sound_id, source_part_index]
	player.bus = "Master"
	player.stream = stream
	player.volume_db = clampf(effects_volume_db + float(request.volume_db), -80.0, 12.0)
	player.finished.connect(_on_loop_finished.bind(key))
	add_child(player)
	_loop_players[key] = player
	_playback.loops[key] = {"id": sound_id, "owner": source_part_index}
	player.play()
	return true


func stop_loop(sound_id: int = -1, source_part_index: int = -1) -> void:
	if _uses_shared_opl(sound_id): shared_opl.request({"op":"stop","id":sound_id})
	_playback._stop_loops(sound_id, source_part_index)
	for key_value in _desired_loops.keys():
		var key := String(key_value)
		var matches_sample := sound_id < 0 or _loop_sample_id(key) == sound_id
		var matches_owner := source_part_index < 0 or _loop_owner_id(key) == source_part_index
		if matches_sample and matches_owner:
			if _loop_players.has(key):
				var player: AudioStreamPlayer = _loop_players[key]
				player.stop()
				player.queue_free()
			_loop_players.erase(key)
			_desired_loops.erase(key)


func stop_all_effects() -> void:
	_playback.loops.clear()
	stop_sample()
	_stop_loop_players(true)

func stop_bank_effects() -> void:
	_playback.stop_bank_effects()
	_simulation_clock=false
	_preview_usec=Time.get_ticks_usec()
	if shared_opl!=null and shared_opl.enabled: shared_opl.request({"op":"stop_effects"})
	for i in range(1,_voices.size()): _voices[i].stop()
	for key in _desired_loops.keys():
		if not String(_sample_entries.get(_loop_sample_id(key),{}).get("resource","")).begins_with("SX_"):
			stop_loop(_loop_sample_id(key),_loop_owner_id(key))
	_sync_players()


func set_effects_enabled(enabled: bool) -> void:
	effects_enabled = enabled
	_playback.set_enabled(enabled)
	if not effects_enabled:
		stop_sample()
		_stop_loop_players(false)
	else:
		for key in _desired_loops.keys():
			_ensure_loop_player(String(key))


func set_effects_volume_db(value: float) -> void:
	effects_volume_db = clampf(value, -80.0, 12.0)
	for index in _voices.size():
		if _voices[index].playing:
			_voices[index].volume_db = clampf(effects_volume_db + _voice_volume_offsets[index], -80.0, 12.0)
	for key in _loop_players:
		var player: AudioStreamPlayer = _loop_players[key]
		var request: Dictionary = _desired_loops.get(key, {})
		player.volume_db = clampf(effects_volume_db + float(request.get("volume_db", 0.0)), -80.0, 12.0)


func handle_event(event: Dictionary) -> void:
	if String(event.get("kind", "")) != "sound_effect":
		return
	if event.has("audio_clock"):
		if not _simulation_clock and not _simulation_snapshot.is_empty():
			# UI previews are outside the simulated game. Resume its saved clock
			# before applying the next ordered simulation request.
			_playback.restore(_simulation_snapshot)
		_simulation_clock = true
		_playback.set_enabled(bool(event.get("audio_enabled", effects_enabled)))
		_playback.advance_to(int(event.audio_clock))
		_sync_players()
	var sound_id := int(event.get("sound_id", -1))
	var source_part_index := int(event.get("part_index", -1))
	match String(event.get("action", "play")):
		"play":
			var arguments := dispatch_arguments(String(event.get("dos_source", "")),sound_id)
			_play_sample(sound_id, source_part_index, 0.0, 1.0, int(arguments.priority), bool(arguments.retrigger))
		"stop":
			# DOS stops a digital sound ID globally; the most recent requester
			# need not be the object that originally started the shared channel.
			stop_sample(sound_id)
			stop_loop(sound_id)
		"start":
			play_loop(sound_id, source_part_index, float(event.get("volume_db", 0.0)))
		"stop_all":
			stop_all_effects()
		"stop_loop":
			stop_loop(sound_id, source_part_index)


func dispatch_arguments(dos_source: String, sound_id: int) -> Dictionary:
	return PlaybackState.dispatch_arguments(dos_source, sound_id)


func _load_sample_index() -> void:
	for path in [SOUND_INDEX_PATH, BANK_INDEX_PATH]:
		_load_index(path)


func _load_index(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("Audio effects index is unavailable: %s" % path)
		return
	var parsed = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary) or not (parsed.get("samples") is Array):
		push_warning("Audio effects index has an invalid format: %s" % SOUND_INDEX_PATH)
		return
	for entry in parsed["samples"]:
		if entry is Dictionary and entry.has("id") and entry.has("resource"):
			_sample_entries[int(entry["id"])] = entry.duplicate(true)


func _create_voices() -> void:
	for index in VOICE_COUNT:
		var voice := AudioStreamPlayer.new()
		# Keep dynamically decoded effects in the Godot mixer on Web too.
		# Browser Sample playback has a separate lifetime/output path.
		if OS.has_feature("web"): voice.playback_type=AudioServer.PLAYBACK_TYPE_STREAM
		voice.name = "EffectVoice%02d" % index
		voice.bus = "Master"
		add_child(voice)
		_voices.append(voice)
		_voice_sample_ids.append(-1)
		_voice_owner_ids.append(-1)
		_voice_volume_offsets.append(0.0)


func _get_sample(sound_id: int) -> AudioStreamWAV:
	if _sample_cache.has(sound_id):
		return _sample_cache[sound_id]
	var resource_id := sound_id
	if not _sample_entries.has(resource_id):
		_warn_missing_sample(sound_id, "no decoded effect is indexed")
		_sample_cache[sound_id] = null
		return null
	var entry: Dictionary = _sample_entries[resource_id]
	var unsigned_pcm: PackedByteArray
	if entry.has("asset_path"):
		unsigned_pcm = FileAccess.get_file_as_bytes(String(entry["asset_path"]))
	else:
		unsigned_pcm = _catalog.read_asset(String(entry["resource"]))
	if unsigned_pcm.is_empty():
		_warn_missing_sample(sound_id, "the packaged PCM resource could not be read")
		_sample_cache[sound_id] = null
		return null
	var is_16_bit := String(entry.get("encoding", "")) == "signed_16_le"
	var signed_pcm := unsigned_pcm if is_16_bit else PackedByteArray()
	if not is_16_bit:
		signed_pcm.resize(unsigned_pcm.size())
		for index in unsigned_pcm.size():
			signed_pcm[index] = (int(unsigned_pcm[index]) - 128) & 0xff
		if String(entry.get("resource","")).begins_with("SX_"):
			signed_pcm.resize(PlaybackState.raw_source_frames(entry))
			# Native streaming pads its last DMA half with unsigned80h (signed0).
			# Preserve the busy/silent tail in the rendered stream as well.
			signed_pcm.resize(PlaybackState.raw_dma_frames(entry))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS if is_16_bit else AudioStreamWAV.FORMAT_8_BITS
	stream.mix_rate = AudioPlaybackState.sample_rate(entry)
	stream.stereo = int(entry.get("channels", 1)) == 2
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD if bool(entry.get("loop", false)) else AudioStreamWAV.LOOP_DISABLED
	stream.loop_begin = int(entry.get("loop_begin_frame", 0))
	stream.loop_end = int(entry.get("frames", signed_pcm.size()))
	stream.data = signed_pcm
	_sample_cache[sound_id] = stream
	return stream


func _get_loop_sample(sound_id: int) -> AudioStreamWAV:
	if _loop_stream_cache.has(sound_id):
		return _loop_stream_cache[sound_id]
	var source := _get_sample(sound_id)
	if source == null:
		_loop_stream_cache[sound_id] = null
		return null
	var stream := source.duplicate() as AudioStreamWAV
	if stream == null:
		_loop_stream_cache[sound_id] = null
		return null
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	var bytes_per_frame := (2 if stream.format == AudioStreamWAV.FORMAT_16_BITS else 1) * (2 if stream.stereo else 1)
	stream.loop_end = int(stream.data.size() / bytes_per_frame)
	_loop_stream_cache[sound_id] = stream
	return stream


func _loop_key(sound_id: int, source_part_index: int) -> String:
	return "%d:%d" % [sound_id, source_part_index]


func _loop_sample_id(key: String) -> int:
	return int(key.get_slice(":", 0))


func _loop_owner_id(key: String) -> int:
	return int(key.get_slice(":", 1))


func _stop_loop_players(clear_requests: bool) -> void:
	for key in _loop_players.keys():
		var player: AudioStreamPlayer = _loop_players[key]
		player.stop()
		player.queue_free()
	_loop_players.clear()
	if clear_requests:
		_desired_loops.clear()


func _on_loop_finished(key: String) -> void:
	if _loop_players.has(key):
		var player: AudioStreamPlayer = _loop_players[key]
		if not player.playing:
			_loop_players.erase(key)
			player.queue_free()


func _warn_missing_sample(sound_id: int, reason: String) -> void:
	if _warned_missing.has(sound_id):
		return
	_warned_missing[sound_id] = true
	push_warning("Cannot play DOS sound ID %d: %s" % [sound_id, reason])
