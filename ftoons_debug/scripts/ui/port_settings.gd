extends Node
## Player preferences shared by every presentation of the port.
var path := preload("res://scripts/io/portable_paths.gd").profile().path_join("port_settings.cfg")
var show_goal_on_level_start := true
var play_intro_videos := false

func _ready() -> void:
	var config := ConfigFile.new()
	if config.load(path)==OK:
		show_goal_on_level_start=bool(config.get_value("gameplay","show_goal_on_level_start",true))
		play_intro_videos=bool(config.get_value("presentation","play_intro_videos",false))

func set_play_intro_videos(enabled: bool) -> void:
	play_intro_videos = enabled
	var config := ConfigFile.new()
	config.load(path)
	config.set_value("presentation","play_intro_videos",enabled)
	var error := config.save(path)
	if error != OK: push_warning("Unable to save intro preference: %s" % error)

func set_show_goal_on_level_start(enabled: bool) -> void:
	show_goal_on_level_start=enabled
	var config := ConfigFile.new()
	config.load(path)
	config.set_value("gameplay","show_goal_on_level_start",enabled)
	var error:=config.save(path)
	if error!=OK: push_warning("Unable to save port settings: %s"%error)
