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
func _process(_delta: float) -> void:
	#bar.value = currTime
	if currTime <= 0:
		ressourceMined()


func _on_mining_area_body_entered(body: Node2D) -> void:
	print("Body entered mining area: ", body.name, " | Type: ", body.get_class())
	print("Groups: ", body.get_groups())

	# Only detect CharacterBody2D (units), not StaticBody2D (resources)
	if body is CharacterBody2D and body.is_in_group("units"):
		units += 1
		startMining()
		print("Unit started mining: ", body.unit_id, " (total miners: ", units, ")")
	else:
		print("Body is NOT a unit or not in units group")

func _on_mining_area_body_exited(body: Node2D) -> void:
	# Only process CharacterBody2D units leaving
	if body is CharacterBody2D and body.is_in_group("units"):
		units -= 1
		if units <= 0:
			timer.stop()
			print("All units left mining area, stopping timer")
		print("Unit left mining: ", body.unit_id, " (remaining miners: ", units, ")")


func _on_timer_timeout() -> void:
	var miningSpeed = 1*units
	currTime -= miningSpeed
	var tween = get_tree().create_tween()
	tween.tween_property(bar, "value", currTime, 0.5).set_trans(Tween.TRANS_LINEAR)
	
func startMining():
	timer.start()
	
func ressourceMined():
	Global.Uranium += 1
	queue_free()
