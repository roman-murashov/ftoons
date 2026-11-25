extends Node
## One chip for original music and bank effects. RAW speech remains digital.
## Optional shared-chip playback uses the same bundled native decoder as import.
var enabled:=false
var connected_ready:=false
var failed:=false
var last_error:=""
var rendered_frames:=0
var received_frames:=0
var command_history: Array[Dictionary]=[]
var server: TCPServer
var peer: StreamPeerTCP
var player: AudioStreamPlayer
var playback: AudioStreamGeneratorPlayback
var buffer:=PackedByteArray()
var pending: Array[Dictionary]=[]
var inflight:=0
var sequence:=0
var process_id:=-1
var token:=""
var started:=0
var buffer_capacity:=0
const RATE:=48000
const BLOCK:=480

func _ready() -> void:
	if OS.has_feature("web"): return
	# Logical/headless simulations do not require an audio-device worker.
	if OS.get_environment("TOONS_AUDIO_BACKEND")=="captured": return
	if DisplayServer.get_name()=="headless": return
	# Register parity is verified; full DOSBox output filtering/timing is still
	# a separate gate. Keep the established captured profile as the default.
	if bool(ProjectSettings.get_setting("audio/shared_opl_enabled",false)) or OS.get_environment("TOONS_AUDIO_BACKEND")=="shared_opl" or OS.get_cmdline_user_args().has("--shared-opl"): start()

func start() -> bool:
	if OS.has_feature("web"):
		last_error="Shared OPL uses a desktop worker; the Web build uses captured DOS audio."
		return false
	if enabled: return not failed
	var root_dir := preload("res://scripts/io/portable_paths.gd").root_dir()
	var decoder := root_dir.path_join("native_audio/ftoons_audio.exe")
	if not FileAccess.file_exists(decoder):
		_fail("The bundled native audio decoder is missing.")
		return false
	server=TCPServer.new()
	if server.listen(0,"127.0.0.1")!=OK:
		_fail("Cannot bind the owned shared-OPL audio connection")
		return false
	token=Crypto.new().generate_random_bytes(16).hex_encode()
	process_id = OS.create_process(decoder, ["serve", root_dir, str(server.get_local_port()), token], false)
	if process_id<0:
		_fail("Cannot start the bundled audio decoder.")
		return false
	var stream:=AudioStreamGenerator.new()
	stream.mix_rate=RATE;stream.buffer_length=0.12
	player=AudioStreamPlayer.new();player.name="OriginalSharedOPL";player.stream=stream
	add_child(player);player.play();player.stream_paused=true;playback=player.get_stream_playback()
	buffer_capacity=playback.get_frames_available()
	enabled=true;started=Time.get_ticks_msec()
	return true

func request(command: Dictionary) -> void:
	if not enabled or failed: return
	if command_history.size()<256: command_history.append(command.duplicate())
	if connected_ready: _send(command)
	else: pending.append(command.duplicate())

func _send(command: Dictionary) -> void:
	var bytes:=JSON.stringify(command).to_utf8_buffer()
	var header:=PackedByteArray();header.resize(4);header.encode_u32(0,bytes.size())
	if peer.put_data(header+bytes)!=OK: _fail("Shared-OPL command transport failed")

func _process(_delta: float) -> void:
	if not enabled or failed: return
	if peer==null and server.is_connection_available():
		peer=server.take_connection();peer.set_no_delay(true)
	if peer!=null:
		peer.poll()
		if peer.get_status()==StreamPeerTCP.STATUS_NONE:
			_fail("Shared-OPL worker disconnected");return
		var size:=peer.get_available_bytes()
		if size>0:
			var data:=peer.get_data(size)
			if data[0]!=OK: _fail("Shared-OPL PCM transport failed");return
			buffer.append_array(data[1])
		while buffer.size()>=8:
			var json_size:=buffer.decode_u32(0);var pcm_size:=buffer.decode_u32(4)
			if json_size>65536 or pcm_size>19200: _fail("Invalid shared-OPL reply size");return
			if buffer.size()<8+json_size+pcm_size: break
			var message=JSON.parse_string(buffer.slice(8,8+json_size).get_string_from_utf8())
			if not message is Dictionary: _fail("Invalid shared-OPL reply");return
			if message.has("error"): _fail(String(message.error));return
			if message.get("ready",false):
				if String(message.get("token",""))!=token: _fail("Wrong shared-OPL worker identity");return
				connected_ready=true
				for command in pending: _send(command)
				pending.clear()
			else:
				if int(message.get("sequence",-1))!=sequence-inflight: _fail("Out-of-order shared-OPL PCM");return
				inflight-=1
				var pcm:=buffer.slice(8+json_size,8+json_size+pcm_size)
				var frames: int=int(message.frames)
				if pcm_size!=frames*2: _fail("Shared-OPL PCM length mismatch");return
				var samples:=PackedVector2Array();samples.resize(frames)
				for i in frames:
					var sample:=float(pcm.decode_s16(i*2))/32768.0
					samples[i]=Vector2(sample,sample)
				if not playback.push_buffer(samples): _fail("Shared-OPL playback buffer overflow");return
				received_frames+=frames
				if player.stream_paused and received_frames>=BLOCK*3: player.stream_paused=false
			buffer=buffer.slice(8+json_size+pcm_size)
	if not connected_ready:
		if Time.get_ticks_msec()-started>10000: _fail("Shared-OPL worker did not initialize")
		return
	# Generator rings round their capacity to a power of two. The requested
	# duration is not the actual capacity; subtracting it added~50ms of queue.
	var queued:=buffer_capacity-playback.get_frames_available()
	while inflight<3 and queued+inflight*BLOCK<BLOCK*3:
		_send({"op":"render","frames":BLOCK,"sequence":sequence})
		sequence+=1;inflight+=1;rendered_frames+=BLOCK

func _fail(message: String) -> void:
	last_error=message;failed=true
	push_warning(message+"; exact shared-OPL playback is unavailable.")
	close()

func close() -> void:
	if peer!=null:
		if connected_ready and not failed: _send({"op":"close"})
		peer.disconnect_from_host();peer=null
	if server!=null: server.stop()
	if process_id>0 and OS.is_process_running(process_id): OS.kill(process_id)
	process_id=-1;connected_ready=false;enabled=false
	if player!=null: player.stop()
	pending.clear()

func _exit_tree() -> void: close()
