extends Node2D

@onready var infantry_unit = preload("res://scenes/units/infantry.tscn")
@onready var sniper_unit = preload("res://scenes/units/sniper.tscn")
var housePos = Vector2(300,300)

func _on_yes_pressed() -> void:
	var unitCost = 10
	if Global.Coin < unitCost:
		return
	Global.Coin -= unitCost
	
	var rng = RandomNumberGenerator.new()
	rng.randomize()
	var randomPosX = rng.randi_range(-100,100)
	var randomPosY = rng.randi_range(-100,100)
	
	var unitPath = get_tree().get_root().get_node("World/Units2")
	var worldPath = get_tree().get_root().get_node("World")

	# Randomly choose between infantry and sniper (70% infantry, 30% sniper)
	var unit_scene = infantry_unit if randf() < 0.7 else sniper_unit
	var unit1 = unit_scene.instantiate()

	unit1.unit_id = Global.get_next_unit_id()
	unit1.is_enemy = false
	unit1.position = housePos + Vector2(randomPosX, randomPosY)

	unitPath.add_child(unit1)
	worldPath.get_units()

func _on_no_pressed() -> void:
	var housePath = get_tree().get_root().get_node("World/Houses")
	for i in housePath.get_child_count():
		if housePath.get_child(i).Selected == true:
			housePath.get_child(i).Selected = false
	queue_free()
