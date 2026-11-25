extends "res://scripts/ui/construction_controls.gd"
## A separate shared-board match, using the same construction/simulation paths.
signal round_finished(winner: int)
signal turn_expired
const Library = preload("res://scripts/io/head_to_head_library.gd")
var library:=Library.new()
var active_match:=false
var solo:=false
var awaiting_turn:=true
var round_complete:=false
var player:=0
var player_names: Array[String]=["Sid","Al"]
var seconds_per_turn: Array[int]=[45,45]
var remaining:=45.0
var scores: Array[int]=[0,0]
var schedule: Array[int]=[]
var round_index:=0
var turn_item:=-1
var turn_partner:=-1
var stage_item:=-1
var stage_partner:=-1
var item_before_grab:=-1
var partner_before_grab:=-1
var stage_before_grab:=-1
var stage_partner_before_grab:=-1
var winner:=-1
var random:=RandomNumberGenerator.new()

func start_match(number: int, tournament: bool, rounds: int, times: Array[int], names: Array[String], solo_play: bool=false) -> bool:
	if library.levels.is_empty(): status=library.error; changed.emit(); return false
	_cancel_grab()
	stop()
	solo=solo_play
	seconds_per_turn=[clampi(times[0],10,599),clampi(times[1],10,599)]
	player_names=[names[0].strip_edges(),names[1].strip_edges()]
	if player_names[0].is_empty(): player_names[0]="Sid"
	if player_names[1].is_empty(): player_names[1]="Al"
	scores=[0,0]
	schedule.clear()
	if tournament and not solo:
		var available: Array[int]=[]
		for n in range(1,51): available.append(n)
		for i in clampi(rounds,1,9):
			var pick:=random.randi_range(0,available.size()-1)
			schedule.append(available[pick])
			available.remove_at(pick)
	else: schedule.append(clampi(number,1,50))
	round_index=0
	active_match=true
	return _load_round()

func _load_round() -> bool:
	var puzzle:=library.load_puzzle(schedule[round_index])
	if puzzle==null: active_match=false; status=library.error; changed.emit(); return false
	player=0
	round_complete=false
	winner=-1
	turn_item=-1
	turn_partner=-1
	stage_item=-1
	stage_partner=-1
	awaiting_turn=true
	set_runner(SimulationRunner.new(puzzle))
	remaining=float(seconds_per_turn[player])
	status="Solo practice: place any number of gadgets, then Play." if solo else "%s goes first. Read the goal, then press Begin turn."%player_names[player]
	if solo: awaiting_turn=false
	changed.emit()
	return true

func begin_turn() -> void:
	if not active_match or round_complete or not awaiting_turn: return
	awaiting_turn=false
	remaining=float(seconds_per_turn[player])
	status="%s: one inventory gadget AND one stage gadget; test with Play, then ring the bell."%player_names[player]
	changed.emit()

func end_turn() -> void:
	if solo or not active_match or awaiting_turn or round_complete or play_backup!=null: return
	# An unfinished drag, Rope, Belt or Tunnel pair rolls back atomically.
	_cancel_grab()
	turn_item=-1
	turn_partner=-1
	stage_item=-1
	stage_partner=-1
	selected_index=-1
	player=1-player
	awaiting_turn=true
	remaining=float(seconds_per_turn[player])
	status="Pass to %s, then press Begin turn."%player_names[player]
	changed.emit()

func next_round() -> bool:
	if not round_complete or round_index+1>=schedule.size(): return false
	stop()
	round_index+=1
	return _load_round()

func replay_round() -> void:
	if not round_complete: return
	if not solo and winner>=0: scores[winner]-=1
	stop()
	_load_round()

func leave_match() -> void:
	_cancel_grab()
	stop()
	active_match=false
	awaiting_turn=true
	status="Match ended. Choose settings and Start new match, or return to Game emulation."
	changed.emit()

func can_edit_part(index: int) -> bool:
	if not active_match or awaiting_turn or round_complete or play_backup!=null or runner==null: return false
	if index<0 or index>=runner.state.parts.size(): return false
	if solo or index in [turn_item,turn_partner,stage_item,stage_partner]: return true
	return stage_item<0 if runner.state.parts[index].placed else turn_item<0

func can_take_inventory(index: int) -> bool:
	if not active_match or round_complete or play_backup!=null or runner==null: return false
	if index<0 or index>=runner.state.parts.size() or runner.state.parts[index].placed: return false
	return awaiting_turn or can_edit_part(index)

func _claim(index: int, from_inventory: bool=false) -> void:
	if probing_transform or solo or index in [turn_item,turn_partner,stage_item,stage_partner]: return
	if from_inventory:
		turn_item=index
		turn_partner=_tunnel_partner(index)
	else:
		stage_item=index
		stage_partner=_tunnel_partner(index)

func _save_allowance() -> void:
	item_before_grab=turn_item
	partner_before_grab=turn_partner
	stage_before_grab=stage_item
	stage_partner_before_grab=stage_partner

func _begin_grab(index: int) -> void:
	if not can_edit_part(index): status="This turn already used that allowance. You may still adjust its chosen gadget."; changed.emit(); return
	var from_inventory:=not runner.state.parts[index].placed
	_save_allowance()
	super._begin_grab(index)
	if grab_active:
		_claim(index,from_inventory)

func _cancel_grab() -> void:
	var held:=grab_active
	super._cancel_grab()
	if held:
		turn_item=item_before_grab
		turn_partner=partner_before_grab
		stage_item=stage_before_grab
		stage_partner=stage_partner_before_grab

func _on_board_clicked(position: Vector2i) -> void:
	super._on_board_clicked(position)
	if tunnel_pair_first>=0: turn_partner=grab_index
	if not grab_active and turn_item>=0: turn_partner=_tunnel_partner(turn_item)
	if not grab_active and stage_item>=0: stage_partner=_tunnel_partner(stage_item)

func _take_rope_endpoint(owner: int, side: int) -> void:
	if not can_edit_part(owner): return
	_save_allowance()
	super._take_rope_endpoint(owner,side)
	if grab_active: _claim(owner)

func _take_belt_endpoint(owner: int, side: int) -> void:
	if not can_edit_part(owner): return
	_save_allowance()
	super._take_belt_endpoint(owner,side)
	if grab_active: _claim(owner)

func _commit_program(index: int, value: int) -> void:
	if not can_edit_part(index): return
	_claim(index)
	super._commit_program(index,value)

func _apply_transform(rotation: int, flip_x: bool, flip_y: bool) -> void:
	if not can_edit_part(selected_index): return
	_claim(selected_index)
	super._apply_transform(rotation,flip_x,flip_y)

func _flip_native_selected(axis: int) -> bool:
	if not can_edit_part(selected_index): return true
	var handled:=super._flip_native_selected(axis)
	if handled: _claim(selected_index)
	return handled

func _flush_part(index: int) -> void:
	if not can_edit_part(index): return
	_claim(index)
	super._flush_part(index)

func play() -> void:
	if not active_match or round_complete or grab_active: return
	begin_turn()
	super.play()

func stop() -> void:
	super.stop()
	if active_match and not solo and not awaiting_turn and not round_complete:
		status="%s: arrangement restored. Inventory allowance %s; stage allowance %s. Ring the gong to end your turn."%[
			player_names[player],"available" if turn_item<0 else "used","available" if stage_item<0 else "used"]
		changed.emit()

func _campaign_completed(_goal: Dictionary) -> void:
	if round_complete: return
	round_complete=true
	winner=player
	if not solo: scores[player]+=1
	tick_accumulator=0.0
	status="Puzzle completed in solo play." if solo else "%s solved the puzzle!"%player_names[player]
	round_finished.emit(player)
	changed.emit()

func advance(delta: float) -> void:
	var testing:=play_backup!=null
	super.advance(delta)
	if solo or not active_match or awaiting_turn or round_complete or testing: return
	remaining=maxf(0,remaining-delta)
	if remaining<=0:
		turn_expired.emit()
		end_turn()

func nuke() -> void:
	# Port extension: restart this puzzle, not the tournament. Native MPC's
	# Head-2-head input table has no active Nuke entry.
	if not active_match or round_complete or runner==null or play_backup!=null: return
	_cancel_grab()
	stop()
	_load_round()
	status="Puzzle reset. Scores are unchanged. "+("Solo practice is ready." if solo else "%s starts a fresh turn."%player_names[0])
	changed.emit()

func reset(solution: bool=false) -> void:
	if not solo: return
	round_complete=false
	winner=-1
	super.reset(solution)

func toggle_editor() -> void: pass
func request_level(_source_name: String) -> bool: return false
func authoring_available() -> bool:
	return active_match and not awaiting_turn and not round_complete and super.authoring_available()
