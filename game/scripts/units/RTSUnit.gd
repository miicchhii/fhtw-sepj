# RTSUnit.gd
extends CharacterBody2D
class_name RTSUnit

@export var unit_id: String = "u1"
@export var type_id: int = 0
@export var max_hp: int = 100
var hp: int = max_hp

@export var selected = false
@onready var box = get_node("Box")
@onready var anim = get_node("AnimationPlayer")
@onready var target_click = position

var follow_cursor = false
var Speed = 50

var target: Vector2

func _ready() -> void:
	set_selected(selected)
	add_to_group("units", true)
	hp = max_hp
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

#new code - lukas
func set_selected(value):
	selected = value
	box.visible = value

func _input(event):
	if event.is_action_pressed("RightClick"):
		follow_cursor = true
	if event.is_action_released("RightClick"):
		follow_cursor = false
		
func _physics_process(delta):
	if follow_cursor == true:
		if selected:
			target_click = get_global_mouse_position()
			anim.play("Walk")
	velocity = position.direction_to(target_click) *Speed
	
	if position.distance_to(target_click) > 10:
		move_and_slide()
	else:
		anim.stop()
