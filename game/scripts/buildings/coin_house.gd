extends StaticBody2D

var POP= preload("res://scenes/world/POP.tscn")

var totalTime = 50
var currTime

@onready var bar = $"ProgressBar"
@onready var timer = $Timer

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	currTime = totalTime
	bar.max_value = totalTime
	timer.start()

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta):
	if currTime <= 0:
		coinsCollected()


func _on_timer_timeout() -> void:
	currTime -= 1
	var tween = get_tree().create_tween()
	tween.tween_property(bar, "value", currTime, 0.1).set_trans(Tween.TRANS_LINEAR)
	
func coinsCollected():
	Global.Coin += 10
	_ready()
	var pop = POP.instantiate()
	add_child(pop)
	pop.show_value(str(10),false)
