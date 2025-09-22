# RTSUnit.gd
extends CharacterBody2D
class_name RTSUnit

@export var unit_id: String = "u1"
@export var type_id: int = 0
@export var max_hp: int = 100
var hp: int = max_hp

var target: Vector2

func _ready() -> void:
	hp = max_hp
	add_to_group("units")
	target = global_position

func set_move_target(p: Vector2) -> void:
	target = p

func step(delta: float) -> void:
	var dir := (target - global_position)
	if dir.length() > 1.0:
		dir = dir.normalized()
		velocity = dir * 1000.0
	else:
		velocity = Vector2.ZERO
	move_and_slide()
