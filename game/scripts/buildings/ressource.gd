extends StaticBody2D

var totalTime = 5
var currTime
var units = 0
@onready var bar = $ProgressBar
@onready var timer = $Timer


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	currTime = totalTime
	bar.max_value = totalTime

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	#bar.value = currTime
	if currTime <= 0:
		ressourceMined()


func _on_mining_area_body_entered(body: Node2D) -> void:
	if "Unit" in body.name:
		units += 1
		startMining()

func _on_mining_area_body_exited(body: Node2D) -> void:
	if "Unit" in body.name:
		units -= 1
		if units <= 0:
			timer.stop()


func _on_timer_timeout() -> void:
	var miningSpeed = 1*units
	currTime -= miningSpeed
	var tween = get_tree().create_tween()
	tween.tween_property(bar, "value", currTime, 0.5).set_trans(Tween.TRANS_LINEAR)
	
func startMining():
	timer.start()
	
func ressourceMined():
	Global.Steel += 1
	queue_free()
