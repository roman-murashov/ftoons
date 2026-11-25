extends Node
## Original DOS scores rendered with ADL.DRV. Music follows the audio device,
## independently of simulation Run/Pause/Step and deterministic effect state.
signal playback_changed
signal playback_failed(message: String)

const INDEX_PATH := "res://assets/original/music_index.json"
const BUS_NAME := "Music"

var music_enabled := true
var current_song_id := 0
var volume_step := 7
var start_generation := 0
var last_error := ""
var songs: Dictionary = {}
var playlist: Array[int] = []
var player: AudioStreamPlayer
var cd_enabled := false
var active_cd_track := 0
var cd_library = preload("res://scripts/audio/cd_music_library.gd").new()
var cd_status := ""

func _ready() -> void:
	if ImportedResources.dos_ready:
		initialize_audio()
	else:
		ImportedResources.dos_mounted.connect(initialize_audio, CONNECT_ONE_SHOT)

func initialize_audio() -> void:
	music_enabled = not bool(ProjectSettings.get_setting("audio/launch_with_music_muted", true))
	var manifest = JSON.parse_string(FileAccess.get_file_as_string(INDEX_PATH))
	if not manifest is Dictionary:
		_fail("Music catalog is missing or invalid: %s" % INDEX_PATH)
		return
	for song: Dictionary in manifest.get("songs", []):
		songs[int(song.id)] = song
	for song_id in manifest.get("toonbox_playlist", []):
		playlist.append(int(song_id))
	if AudioServer.get_bus_index(BUS_NAME) < 0:
		AudioServer.add_bus()
		var index := AudioServer.bus_count-1
		AudioServer.set_bus_name(index, BUS_NAME)
		AudioServer.set_bus_send(index, "Master")
	player = AudioStreamPlayer.new()
	# Match the Web effects backend, retaining Godot bus volume and loop mixing.
	if OS.has_feature("web"): player.playback_type=AudioServer.PLAYBACK_TYPE_STREAM
	player.name = "BackgroundMusic"
	player.bus = BUS_NAME
	add_child(player)
	set_volume_step(volume_step)

func select_song(song_id: int, restart := false) -> bool:
	if song_id != 0 and not songs.has(song_id):
		return _fail("Unknown DOS music ID: %d" % song_id)
	if player == null:
		return _fail("Music player is unavailable")
	# DOS 298D:5C6F retains an unchanged level song. SOUND 3BEA:3A9A
	# also retains an active duplicate unless the wrapper requests retrigger.
	if current_song_id == song_id and not restart:
		var active_shared=get_node("/root/AudioEffects").shared_opl
		if song_id == 0 or not music_enabled or player.playing or (active_cd_track == 0 and active_shared!=null and active_shared.enabled):
			return true
	player.stop()
	player.stream = null
	var shared=get_node("/root/AudioEffects").shared_opl
	# Always stop the prior native score before switching to a CD recording;
	# keep the shared chip available for sound effects and unmatched DOS songs.
	if shared!=null and shared.enabled and current_song_id!=0:
		shared.request({"op":"stop","id":current_song_id})
	active_cd_track = 0
	cd_status = ""
	if cd_enabled and cd_library.songs.has(song_id):
		var cd_stream: AudioStreamWAV = cd_library.load_song(song_id) if music_enabled else null
		if not music_enabled or cd_stream != null:
			current_song_id = song_id
			last_error = ""
			active_cd_track = int(cd_library.songs[song_id].number)
			if music_enabled:
				player.stream = cd_stream
				player.play()
				start_generation += 1
			playback_changed.emit()
			return true
		cd_status = cd_library.load_error + " Using DOS music."
	if shared!=null and shared.enabled:
		current_song_id=song_id
		last_error=""
		if music_enabled and song_id!=0:
			shared.request({"op":"play","id":song_id,"retrigger":restart})
			shared.request({"op":"music_volume","value":floori(float(volume_step)*127.0/7.0)})
			start_generation+=1
		playback_changed.emit()
		return true
	current_song_id = song_id
	last_error = ""
	if music_enabled and song_id != 0:
		var stream := _load_song(songs[song_id])
		if stream == null:
			playback_changed.emit()
			return _fail("Cannot load DOS music %d" % song_id)
		player.stream = stream
		player.play()
		start_generation += 1
	playback_changed.emit()
	return true

func _load_song(song: Dictionary) -> AudioStreamWAV:
	if song.has("pcm_path") or song.has("lossless_asset_path"):
		var bytes: PackedByteArray
		if song.has("pcm_path"):
			bytes = FileAccess.get_file_as_bytes(String(song.pcm_path))
		else:
			var compressed := FileAccess.get_file_as_bytes(String(song.lossless_asset_path))
			bytes = compressed.decompress(int(song.lossless_bytes), FileAccess.COMPRESSION_GZIP)
		if bytes.size()!=int(song.lossless_bytes): return null
		var digest:=HashingContext.new()
		digest.start(HashingContext.HASH_SHA256);digest.update(bytes)
		if digest.finish().hex_encode()!=String(song.pcm_sha256): return null
		var stream:=AudioStreamWAV.new()
		stream.format=AudioStreamWAV.FORMAT_16_BITS
		stream.mix_rate=int(song.sample_rate_hz)
		stream.stereo=false
		stream.data=bytes
		stream.loop_mode=AudioStreamWAV.LOOP_FORWARD
		stream.loop_begin=int(song.loop_begin_frame)
		stream.loop_end=int(song.loop_end_frame)
		return stream
	return ResourceLoader.load(String(song.asset_path)) as AudioStreamWAV

func set_level_music(song_id: int) -> bool:
	return select_song(song_id)

func set_cd_enabled(enabled: bool) -> bool:
	if enabled and OS.has_feature("web"):
		cd_status = "CD music is not included in this Web build."
		playback_changed.emit()
		return false
	if enabled and not cd_library.refresh():
		cd_status = cd_library.load_error
		playback_changed.emit()
		return false
	if cd_enabled == enabled: return true
	cd_enabled = enabled
	# Switching the source preserves mute/volume and the logical DOS song ID.
	return select_song(current_song_id, true)

func get_music_source_status() -> String:
	if not cd_status.is_empty(): return cd_status
	if current_song_id == 0: return "No music selected"
	if cd_enabled and active_cd_track != 0:
		return "CD track %02d — %s" % [active_cd_track, get_song_name(current_song_id)]
	if cd_enabled: return "DOS fallback — no CD match for %s" % get_song_name(current_song_id)
	return "DOS MIDI — %s" % get_song_name(current_song_id)

func set_music_enabled(enabled: bool) -> void:
	if music_enabled == enabled:
		return
	music_enabled = enabled
	if player != null:
		if enabled:
			# DOS 1DD9:078B replays current music after 0766 stopped it.
			select_song(current_song_id, true)
		else:
			player.stop()
			var shared=get_node("/root/AudioEffects").shared_opl
			if shared!=null and shared.enabled and current_song_id!=0: shared.request({"op":"stop","id":current_song_id})
	playback_changed.emit()

func set_volume_step(value: int) -> void:
	volume_step = clampi(value, 0, 7)
	var shared=get_node("/root/AudioEffects").shared_opl
	if shared!=null and shared.enabled: shared.request({"op":"music_volume","value":floori(float(volume_step)*127.0/7.0)})
	var bus := AudioServer.get_bus_index(BUS_NAME)
	if bus >= 0:
		# Toonbox uses eight settings, floor(step*100/7). Zero volume keeps
		# the score running, while Music Off stops and restarts on re-enable.
		var percent := floori(float(volume_step)*100.0/7.0)
		AudioServer.set_bus_mute(bus, percent == 0)
		AudioServer.set_bus_volume_db(bus, linear_to_db(float(percent)/100.0) if percent else 0.0)
	playback_changed.emit()

func change_track(direction: int) -> bool:
	if playlist.is_empty():
		return false
	var index := playlist.find(current_song_id)
	if index < 0: index = 0
	return select_song(playlist[posmod(index+direction, playlist.size())])

func stop_music() -> void:
	select_song(0)

func get_song_name(song_id: int) -> String:
	return "No music" if song_id == 0 else String(songs.get(song_id, {}).get("name", str(song_id)))

func _fail(message: String) -> bool:
	last_error = message
	push_error(message)
	playback_failed.emit(message)
	return false
