extends "res://scripts/ui/dos_inventory_art.gd"
## Toonbox, original overlay 076 (6122). Parent owns modal input and lifetime.
var effects_mode := false
var effect_index := 0
var song_index := 0
var flash := ""
var flash_time := 0.0
var clock_time := 0.0
var meter := 0
var meter_target := 0
var meter_time := 0.0
var construction: RefCounted
var digit_cases := Vector2i(23,23)
var digit_target := Vector2i(23,23)
var digit_direction := 1
var digit_time := 0.0
var digit_interval := 0.0
var queued_action:=""
var held_action:=""
var digit_pending:=false
var digit_active:=false
const TIMER_SECONDS:=5041.0/1193182.0
# The native outer loop presents once per refresh (observed 3/4 PIT counts).
const PRESENT_SECONDS:=1.0/60.0
const BUTTONS := {
	"preview":Rect2(306,256,61,33), "mode":Rect2(100,147,87,191),
	"power":Rect2(368,148,103,95), "power_top":Rect2(261,11,196,128),
	"previous":Rect2(303,284,82,57), "next":Rect2(376,284,78,54),
	"down":Rect2(312,199,53,56), "up":Rect2(311,144,53,56),
	"close":Rect2(192,215,57,46)}

func _init(catalog: ResourceCatalog, graphics: SpriteGraphicsPack = null) -> void:
	super(catalog, graphics)
	layout=JSON.parse_string(FileAccess.get_file_as_string("res://assets/original/dos_tunes.json"))
	_load_sheets(layout.tables.values())
	mouse_filter=Control.MOUSE_FILTER_IGNORE
	visible=false

func begin() -> void:
	effects_mode=false
	effect_index=0
	song_index=maxi(0,MusicPlayer.playlist.find(MusicPlayer.current_song_id))
	flash=""
	digit_cases=Vector2i(23+3*(song_index%10),23+3*(song_index/10))
	digit_target=digit_cases
	queued_action=""
	held_action=""
	digit_pending=false
	digit_active=false
	digit_time=0.0
	flash_time=0.0
	meter_time=0.0
	advance_meter()
	clock_time=0
	visible=true
	queue_redraw()

func finish() -> void:
	AudioEffects.stop_sample(int(layout.effects[effect_index]))
	visible=false

func advance(delta: float) -> void:
	clock_time+=delta
	# Delay(15) and the synchronous digit routine block the original menu;
	# its meter/RNG do not continue running behind those operations.
	if flash_time>0:
		var held:=minf(delta,flash_time)
		flash_time-=held
		delta-=held
		if flash_time>0: queue_redraw();return
		var action:=queued_action
		queued_action=""
		_execute(action)
		if action=="close": queue_redraw();return
	if digit_pending:
		digit_pending=false
		digit_active=true
		# 6122:09E6 advances only the ones wheel before the first draw.
		_step_digit(0)
		digit_time=0.0
	if digit_active:
		digit_time+=delta
		while digit_time>=digit_interval and digit_active:
			digit_time-=digit_interval
			_step_digit(0)
			_step_digit(1)
			if digit_cases==digit_target: digit_active=false
		if digit_active: queue_redraw();return
		delta=digit_time
		digit_time=0.0
	if held_action.is_empty(): flash=""
	meter_time+=delta
	while meter_time>=PRESENT_SECONDS:
		meter_time-=PRESENT_SECONDS
		advance_meter()
	queue_redraw()

func _step_digit(wheel: int) -> void:
	if digit_cases[wheel]!=digit_target[wheel]: digit_cases[wheel]=23+posmod(digit_cases[wheel]-23+digit_direction,30)

func busy() -> bool:
	return flash_time>0 or digit_pending or digit_active

func advance_meter() -> void:
	# 6122:064A..06DA: move one position until the target is reached, then
	# consume two process-global draws (offset, sign). A set low bit negates.
	if not MusicPlayer.music_enabled or construction==null or construction.runner==null: return
	if meter!=meter_target:
		meter+=signi(meter_target-meter)
		return
	var state: SimulationState=construction.runner.state
	var offset:=int(layout.meter_offsets[state.next_random()%7])
	if state.next_random()&1: offset=-offset
	meter_target=MusicPlayer.volume_step+offset
	if meter_target<0: meter=0;meter_target=0
	elif meter_target>7: meter_target=7

func activate(action: String, repeated: bool=false) -> void:
	if busy(): return
	flash=action
	meter_time=0.0
	if repeated:
		# 6122:041B..0428 loops while the native button remains held;
		# BP-2 is nonzero, so02B9 skips the first-press flash/Delay15.
		_execute(action)
	else:
		queued_action=action
		# Present02F0 precedes Delay15 at0315. Commit the action afterwards.
		flash_time=PRESENT_SECONDS+15.0*TIMER_SECONDS
	queue_redraw()

func _execute(action: String) -> void:
	var before:=effect_index+1 if effects_mode else song_index
	match action:
		"up","down":
			if MusicPlayer.music_enabled: MusicPlayer.set_volume_step(MusicPlayer.volume_step+(1 if action=="up" else -1))
		"power","power_top":
			MusicPlayer.set_music_enabled(not MusicPlayer.music_enabled)
			if MusicPlayer.music_enabled: AudioEffects.play_sample(3001)
		"mode": effects_mode=not effects_mode
		"previous","next":
			AudioEffects.play_sample(1 if action=="next" else 3024)
			MusicPlayer.set_music_enabled(true)
			var direction:=1 if action=="next" else -1
			if effects_mode:
				AudioEffects.stop_sample(int(layout.effects[effect_index]))
				effect_index=posmod(effect_index+direction,99)
				preview()
			else:
				song_index=posmod(song_index+direction,MusicPlayer.playlist.size())
				MusicPlayer.select_song(MusicPlayer.playlist[song_index])
		"preview":
			if effects_mode: preview()
	var after:=effect_index+1 if effects_mode else song_index
	if after!=before:
		digit_direction=signi(after-before)
		digit_target=Vector2i(23+3*(after%10),23+3*(after/10))
		# 0A37 presents BEFORE Delay(25); the old model omitted that refresh.
		digit_interval=PRESENT_SECONDS+(25.0*TIMER_SECONDS if absi(after-before)==1 else 0.0)
		digit_time=0
		digit_pending=true
	queue_redraw()

func preview() -> void:
	AudioEffects.play_sample(int(layout.effects[effect_index]),-1,0.0,1.0,9999,true)

func _draw() -> void:
	if not visible: return
	commands("0")
	# Original 064A random walk uses DS:0664 weights and298D:31F6.
	commands(str(1+meter if MusicPlayer.music_enabled else 1))
	commands("9")
	commands(str(digit_cases.x))
	commands(str(digit_cases.y),Vector2(-29,0))
	commands("12" if flash=="up" else "11")
	commands("14" if flash=="down" else "13")
	commands("15" if MusicPlayer.music_enabled else "16")
	commands("18" if flash=="previous" else "17")
	commands("20" if flash=="next" else "19")
	commands("22" if flash=="close" else "21")
	commands("57" if effects_mode else "56")
	if effects_mode: commands("59" if flash=="preview" else "58")
