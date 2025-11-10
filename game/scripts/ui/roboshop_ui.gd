extends Control

# --- Costs in Metal ---
@export var cost_infantry: int = 50
@export var cost_sniper: int = 100
@export var cost_heavy: int = 150

# --- Optional icons (assign in Inspector) ---
@export var icon_infantry: Texture2D
@export var icon_sniper: Texture2D
@export var icon_heavy: Texture2D

# Offset from Roboshop to spawn new unit
@export var spawn_offset: Vector2 = Vector2(48, 0)

@onready var btn_inf: TextureButton = %InfantryBtn
@onready var btn_snp: TextureButton = %SniperBtn
@onready var btn_hvy: TextureButton = %HeavyBtn
@onready var cost_inf: Label = %InfantryCost
@onready var cost_snp: Label = %SniperCost
@onready var cost_hvy: Label = %HeavyCost

func _ready() -> void:
	if icon_infantry: btn_inf.texture_normal = icon_infantry
	if icon_sniper:   btn_snp.texture_normal = icon_sniper
	if icon_heavy:    btn_hvy.texture_normal = icon_heavy

	cost_inf.text = str(cost_infantry)
	cost_snp.text = str(cost_sniper)
	cost_hvy.text = str(cost_heavy)

	btn_inf.pressed.connect(_on_buy_infantry)
	btn_snp.pressed.connect(_on_buy_sniper)
	btn_hvy.pressed.connect(_on_buy_heavy)

func _process(_dt: float) -> void:
	btn_inf.disabled = Global.Metal < cost_infantry
	btn_snp.disabled = Global.Metal < cost_sniper
	btn_hvy.disabled = Global.Metal < cost_heavy

# --- Button handlers ---
func _on_buy_infantry() -> void:
	_buy(Global.UnitType.INFANTRY, cost_infantry)

func _on_buy_sniper() -> void:
	_buy(Global.UnitType.SNIPER, cost_sniper)

func _on_buy_heavy() -> void:
	_buy(Global.UnitType.HEAVY, cost_heavy)

# --- Purchase + spawn ---
func _buy(unit_type: int, cost: int) -> void:
	if Global.Metal < cost:
		return

	var pos := _get_spawn_position()
	if pos == null:
		push_warning("No Roboshop found in scene (group 'Roboshop').")
		return

	Global.Metal -= cost
	# Use your existing function: (pos, is_enemy, unit_type)
	Global.spawnUnit(pos, false, unit_type)

# --- Locate Roboshop ---
func _get_spawn_position() -> Vector2:
	var shops := get_tree().get_nodes_in_group("Roboshop")
	if shops.is_empty():
		return get_viewport().get_visible_rect().size / 2.0
	var shop := shops[0]
	var base_pos: Vector2 = shop.global_position if shop is Node2D else Vector2.ZERO
	return base_pos + spawn_offset
