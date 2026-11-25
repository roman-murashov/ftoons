extends Control

const ResourceCatalog = preload("res://scripts/io/resource_catalog.gd")
const ResourceBrowser = preload("res://scripts/ui/resource_browser.gd")
const GraphicsBrowser = preload("res://scripts/ui/graphics_browser.gd")
const PuzzleBrowser = preload("res://scripts/ui/puzzle_browser.gd")

func _ready() -> void:
	var catalog := ResourceCatalog.new()
	var tabs := TabContainer.new()
	tabs.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(tabs)
	var browser := ResourceBrowser.new(catalog)
	browser.name = "Resources"
	tabs.add_child(browser)
	var graphics := GraphicsBrowser.new(catalog)
	graphics.name = "Graphics"
	tabs.add_child(graphics)
	var puzzles := PuzzleBrowser.new(catalog)
	puzzles.name = "Puzzles"
	tabs.add_child(puzzles)
	var game := preload("res://scripts/ui/game_emulation.gd").new(catalog, puzzles.construction)
	game.name = "Game emulation"
	tabs.add_child(game)
	var head_to_head:=preload("res://scripts/ui/head_to_head_tab.gd").new(catalog)
	head_to_head.name="Head-2-head mode"
	tabs.add_child(head_to_head)
	var generator := preload("res://scripts/ui/random_level_tab.gd").new(catalog, puzzles.type_names)
	generator.name = "Random Level Generator"
	tabs.add_child(generator)
	# Constructing the optional MPC tab prepares its first match. Restore the
	# campaign's score until the player actually opens that tab.
	if puzzles.construction.runner != null:
		MusicPlayer.set_level_music(puzzles.construction.runner.puzzle.music)
	tabs.tab_changed.connect(func(index: int):
		var shared_session := index < tabs.get_tab_idx_from_control(head_to_head)
		puzzles.set_process(shared_session)
		puzzles.set_process_input(shared_session)
		if shared_session and puzzles.construction.runner!=null:
			AudioEffects.sync_simulation_audio(puzzles.construction.runner.state.audio.snapshot())
			MusicPlayer.set_level_music(puzzles.construction.runner.puzzle.music))
	if OS.has_feature("web"):
		tabs.current_tab=3
		if OS.has_feature("local_web_test"):
			var probe:=preload("res://scripts/testing/web_smoke_bridge.gd").new()
			probe.puzzles=puzzles
			probe.game=game
			probe.tabs=tabs
			add_child(probe)
