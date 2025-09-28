extends Node2D

@onready var unit = preload("res://scenes/units/rts_unit.tscn")
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
	var unit1 = unit.instantiate()
	
	unit1.position = housePos + Vector2(randomPosX, randomPosY)
	
	unitPath.add_child(unit1)
	worldPath.get_units()

func _on_no_pressed() -> void:
	var housePath = get_tree().get_root().get_node("World/Houses")
	for i in housePath.get_child_count():
		if housePath.get_child(i).Selected == true:
			housePath.get_child(i).Selected = false
	queue_free()
