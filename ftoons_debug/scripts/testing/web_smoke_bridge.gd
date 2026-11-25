extends Node
## Diagnostics for the local_web_test export only. No changes to simulation steps.
var puzzles: Control
var game: Control
var tabs: TabContainer
var elapsed:=0.0
var frame_ms: Array[float]=[]
var last_result: Dictionary={}

func _process(delta: float) -> void:
	frame_ms.append(delta*1000.0)
	if frame_ms.size()>120: frame_ms.pop_front()
	elapsed+=delta
	if elapsed<0.5: return
	elapsed=0.0
	var raw=JavaScriptBridge.eval("JSON.stringify(window.__toonsCommand || null)",true)
	if raw is String:
		var command=JSON.parse_string(raw)
		if command is Dictionary:
			JavaScriptBridge.eval("window.__toonsCommand=null",true)
			_execute(command)
	var runner=puzzles.construction.runner
	var sorted=frame_ms.duplicate()
	sorted.sort()
	var snapshot: Dictionary={
		"ready":runner!=null,"tab":tabs.current_tab,
		"fps":Engine.get_frames_per_second(),
		"frame_ms_p95":sorted[int((sorted.size()-1)*0.95)] if not sorted.is_empty() else 0,
		"process_ms":Performance.get_monitor(Performance.TIME_PROCESS)*1000.0,
		"static_memory_bytes":Performance.get_monitor(Performance.MEMORY_STATIC),
		"level":runner.puzzle.source_name if runner!=null else "",
		"tick":runner.state.tick if runner!=null else -1,
		"running":runner.state.running if runner!=null else false,
		"completed":puzzles.construction.is_completed(),
		"campaign_levels":puzzles.levels.size(),
		"head_to_head_levels":tabs.get_child(4).construction.library.levels.size(),
		"cd_pack_present":FileAccess.file_exists("res://dlc_win_data/audio/audio_index.json"),
		"cd_button_disabled":game.music_pack_button.disabled,
		"music_enabled":MusicPlayer.music_enabled,"music_playing":MusicPlayer.player.playing,
		"music_error":MusicPlayer.last_error,"shared_opl_enabled":AudioEffects.shared_opl.enabled,
		"windows_graphics":game.sprite_graphics.alternate_enabled,
		"save_folder":preload("res://scripts/io/home_toons_document.gd").default_folder(),
		"grab_active":puzzles.construction.grab_active,
		"placed_count":runner.state.parts.filter(func(p): return p.active and p.placed).size() if runner!=null else 0,
		"match_awaiting_turn":tabs.get_child(4).construction.awaiting_turn,
		"match_player":tabs.get_child(4).construction.player,
		"match_splash":tabs.get_child(4).game.turn_splash.visible,
		"last_result":last_result
	}
	var generator = tabs.get_node_or_null("Random Level Generator")
	if generator != null and tabs.get_current_tab_control() == generator:
		var generated_runner: SimulationRunner = generator.construction.runner
		snapshot.generator = {"count":generator.levels.size(), "busy":generator.generating,
			"selected":generator.selected_level, "tier":generator.difficulty.get_selected_id(),
			"title":generator.title_label.text, "status":generator.status_label.text,
			"won":generated_runner != null and generated_runner.state.goal.completed}
		var actions := {}
		for button: Button in [generator.generate_button, generator.solution_button, generator.play_button,
				generator.json_button, generator.lev_button]:
			var center := button.get_global_rect().get_center()
			actions[button.text] = [center.x, center.y]
		snapshot.generator.actions = actions
	JavaScriptBridge.eval("window.__toonsTest="+JSON.stringify(snapshot),true)

func _execute(command: Dictionary) -> void:
	last_result={"id":command.get("id",0),"ok":true}
	match String(command.get("op","")):
		"load":
			var source:=String(command.get("level",""))
			if not puzzles.levels.has(source): last_result.ok=false
			else: puzzles._load_source(source)
		"dismiss":
			game.goal_pending=false
			game.right_dialog.close()
		"solution": puzzles.construction.reset(true)
		"play":
			game.goal_pending=false
			game.right_dialog.close()
			puzzles.construction.play()
		"stop": puzzles.construction.stop()
		"tab": tabs.current_tab=clampi(int(command.get("index",3)),0,tabs.get_tab_count()-1)
		"graphics": game.graphics_button.button_pressed=bool(command.get("enabled",false))
		"music": MusicPlayer.set_music_enabled(bool(command.get("enabled",false)))
		"sound": last_result.ok=AudioEffects.play_sample(int(command.get("sound_id",3040)))
		"intro":
			game.goal_pending=false
			game.right_dialog.close()
			last_result.ok=game.intro_player.begin(puzzles.construction.runner.puzzle.source_name)
		"editor_save":
			var doc=preload("res://scripts/io/home_toons_document.gd").new()
			var path:="user://web_export_editor_probe.json"
			last_result.ok=doc.save_file(path,doc.capture(puzzles.construction.runner,true),true)
			var loaded=doc.load_file(path)
			last_result.ok=last_result.ok and loaded!=null and loaded.parts.size()==puzzles.construction.runner.puzzle.parts.size()
			last_result.error=doc.error
			last_result.path=path
		"storage":
			var path:="user://web_export_probe.txt"
			if command.has("value"):
				var file:=FileAccess.open(path,FileAccess.WRITE)
				if file!=null: file.store_string(String(command.value));file.close()
				else: last_result.ok=false
			last_result.value=FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
		_: last_result.ok=false
