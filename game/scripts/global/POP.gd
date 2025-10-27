extends Label

var travel = Vector2(0, -50)
var duration = 1
var spread = PI/2


func show_value(value, crit):
	var tween = create_tween()
	text = "+ " + str(value) + "m"
	pivot_offset = size / 4
	
	var movement = travel.rotated(randi_range(-spread/2, spread/2))
	
	tween.tween_property(self, "position", position + movement/3, duration)
	
	tween.tween_property(self, "modulate:a", 0.0, duration)
	
	#not really used rn but let's see
	if crit == true:
		modulate = Color(1,0,0)
		scale= scale * 2
		tween.tween_property(self, "scale", scale, 0.4)
	
	tween.play()
	tween.tween_callback(self.queue_free)
