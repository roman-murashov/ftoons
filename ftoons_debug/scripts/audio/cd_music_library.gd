extends RefCounted
## Optional, user-confirmed replacements. Read original WAV bytes on demand,
## so playback does not depend on Godot's imported .wav cache.
const ROOT := "res://dlc_win_data/audio/"
var songs: Dictionary = {}
var load_error := ""

func refresh() -> bool:
	songs.clear()
	load_error = ""
	for file in ["audio_index.json", "music_matches.json"]:
		if not FileAccess.file_exists(ROOT + file):
			load_error = "Optional CD music pack is missing: " + file
			return false
	var index = JSON.parse_string(FileAccess.get_file_as_string(ROOT + "audio_index.json"))
	var mapping = JSON.parse_string(FileAccess.get_file_as_string(ROOT + "music_matches.json"))
	if not index is Dictionary or not mapping is Dictionary:
		load_error = "Invalid CD music index or matches."
		return false
	var tracks := {}
	for track: Dictionary in index.get("cd_tracks", []):
		tracks[int(track.number)] = track
	for match_row: Dictionary in mapping.get("matches", []):
		var number := int(match_row.cd_track)
		if not tracks.has(number): continue
		var track: Dictionary = tracks[number].duplicate()
		track.path = match_row.get("path",track.path)
		# Allow the user's matched subfolder, but never paths outside the pack.
		var relative := String(track.path)
		if not relative.begins_with("cd/") or ".." in relative or relative.get_file() != "track_%02d.wav" % number: continue
		if FileAccess.file_exists(ROOT + String(track.path)):
			songs[int(match_row.dos_song_id)] = track
	if songs.is_empty(): load_error = "No confirmed CD music files are available."
	return not songs.is_empty()

func load_song(song_id: int) -> AudioStreamWAV:
	load_error = ""
	if not songs.has(song_id): return null
	var track: Dictionary = songs[song_id]
	var bytes := FileAccess.get_file_as_bytes(ROOT + String(track.path))
	# import_cd_audio.py writes canonical, lossless 44-byte PCM WAV headers.
	if bytes.size() != int(track.pcm_bytes) + 44 or bytes.slice(0,4).get_string_from_ascii() != "RIFF" or bytes.slice(8,16).get_string_from_ascii() != "WAVEfmt " or bytes.slice(36,40).get_string_from_ascii() != "data":
		load_error = "CD track %02d has an invalid WAV header." % int(track.number)
		return null
	if bytes.decode_u16(20) != 1 or bytes.decode_u16(22) != 2 or bytes.decode_u32(24) != 44100 or bytes.decode_u16(34) != 16 or bytes.decode_u32(40) != int(track.pcm_bytes):
		load_error = "CD track %02d is not the extracted stereo PCM file." % int(track.number)
		return null
	var pcm := bytes.slice(44)
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(pcm)
	if digest.finish().hex_encode() != String(track.pcm_sha256):
		load_error = "CD track %02d failed its audio hash check." % int(track.number)
		return null
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = 44100
	stream.stereo = true
	stream.data = pcm
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = int(track.frames)
	return stream
