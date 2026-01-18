extends StaticBody2D

var totalTime = 5
var currTime
var ally_units := 0
var enemy_units := 0
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
	# Only detect CharacterBody2D (units), not StaticBody2D (resources)
	if body is CharacterBody2D and body.is_in_group("units"):
		# Your units have is_enemy (used in bases), so use that here too
		if body.is_enemy:
			enemy_units += 1
		else:
			ally_units += 1

		startMining()
		print("Unit started mining: ", body.unit_id, " | ally=", ally_units, " enemy=", enemy_units)


func _on_mining_area_body_exited(body: Node2D) -> void:
	if body is CharacterBody2D and body.is_in_group("units"):
		if body.is_enemy:
			enemy_units -= 1
		else:
			ally_units -= 1

		if ally_units + enemy_units <= 0:
			timer.stop()
			print("All units left mining area, stopping timer")

		print("Unit left mining: ", body.unit_id, " | ally=", ally_units, " enemy=", enemy_units)



func _on_timer_timeout() -> void:
	var miningSpeed = (ally_units + enemy_units)
	currTime -= miningSpeed
	var tween = get_tree().create_tween()
	tween.tween_property(bar, "value", currTime, 0.5).set_trans(Tween.TRANS_LINEAR)
	
func startMining():
	timer.start()
	
func ressourceMined():
	# Only the player/ally side increases Global.Uranium
	# (Enemy mining should NOT give the player uranium.)
	if ally_units > 0 and enemy_units == 0:
		Global.Uranium += 1
		print("Uranium mined by ALLY. Global.Uranium =", Global.Uranium)
	else:
		print("Uranium mined by ENEMY or contested. No uranium awarded to player.")

	queue_free()
