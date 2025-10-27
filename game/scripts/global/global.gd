extends Node

var Uranium = 0
var Metal = 0
var next_unit_id = 1

func get_next_unit_id() -> String:
	var id = "u" + str(next_unit_id)
	next_unit_id += 1
	return id

enum UnitType {
	INFANTRY,
	SNIPER,
	HEAVY
}

func spawnUnit(pos, is_enemy: bool = false, unit_type: UnitType = UnitType.INFANTRY):
	var unit_scene
	var unit_type_name = ""

	match unit_type:
		UnitType.INFANTRY:
			unit_scene = preload("res://scenes/units/infantry.tscn")
			unit_type_name = "Infantry"
		UnitType.SNIPER:
			unit_scene = preload("res://scenes/units/sniper.tscn")
			unit_type_name = "Sniper"
		UnitType.HEAVY:
			unit_scene = preload("res://scenes/units/Heavy.tscn")
			unit_type_name = "Heavy"

	var unit = unit_scene.instantiate()

	unit.unit_id = get_next_unit_id()
	unit.is_enemy = is_enemy
	unit.position = pos

	var container_name = "Enemies" if is_enemy else "Units2"
	var container = get_tree().get_root().get_node("World/" + container_name)

	if container:
		container.add_child(unit)
		print("Spawned ", unit_type_name, ": ", unit.unit_id, " at position: ", unit.position, " enemy: ", is_enemy)
		# Refresh units array in Game
		var world = get_tree().get_root().get_node("World")
		if world and world.has_method("get_units"):
			world.get_units()
	else:
		print("Error: Could not find container: ", container_name)
	
