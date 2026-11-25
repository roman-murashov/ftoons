extends RefCounted
## Original640x400 checker transition,298D:2A33..2CB3/1DBF:0009.
## Timing profiles are observations at fixed20000 cycles, not native Delay calls.
const TIMER_SECONDS:=5041.0/1193182.0
var variant:=0
var elapsed:=0.0
var duration:=0.0
var operations: Array=[]

static func rectangles(which: int) -> Array[Rect2i]:
	var result: Array[Rect2i]=[]
	match which:
		0: result.append(Rect2i(0,0,640,400))
		1:
			for y in range(0,200,10):
				result.append(Rect2i(0,y,640,10))
				result.append(Rect2i(0,390-y,640,10))
		2:
			for x in range(0,320,10):
				result.append(Rect2i(x,0,10,400))
				result.append(Rect2i(630-x,0,10,400))
	return result

static func raster_rectangle(box: Rect2i) -> Rect2i:
	#0009 increments height and rounds horizontally to VGA bytes, including
	#an extra byte when width is already divisible by8. Then clips to screen.
	var x:=box.position.x-box.position.x%8
	var width:=box.size.x+box.position.x%8+8-box.size.x%8
	var clipped:=Rect2i(x,box.position.y,width,box.size.y+1).intersection(Rect2i(0,0,640,400))
	clipped.size.x=((clipped.size.x+7)/8)*8 #0124..0130 writes whole bytes.
	return clipped.intersection(Rect2i(0,0,640,400))

func begin(which: int) -> void:
	variant=posmod(which,3)
	elapsed=0.0
	var profiles: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://assets/original/dos_wipe_timing.json"))
	var profile: Dictionary=profiles.variants[str(variant)]
	duration=float(profile.duration_counts)*TIMER_SECONDS
	operations.clear()
	var boxes:=rectangles(variant)
	for i in boxes.size():
		operations.append({"rectangle":raster_rectangle(boxes[i]),"time":float(profile.rectangle_counts[i])*TIMER_SECONDS})

func advance(delta: float) -> float:
	# Return unused time, so the reward's240-count hold starts after the wipe.
	var consumed:=minf(maxf(0.0,delta),maxf(0.0,duration-elapsed))
	elapsed+=consumed
	return delta-consumed

func finished() -> bool: return elapsed>=duration

func visible_rectangles() -> Array[Rect2i]:
	var result: Array[Rect2i]=[]
	for operation in operations:
		if elapsed>=float(operation.time): result.append(operation.rectangle)
	return result
