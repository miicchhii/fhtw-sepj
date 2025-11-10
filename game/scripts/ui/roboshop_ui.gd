extends Control

# ---------------- Config ----------------
@export var cost_infantry: int = 30
@export var cost_sniper:   int = 40
@export var cost_heavy:    int = 70
@export var uranium_heavy: int = 1


@export var icon_infantry: Texture2D
@export var icon_sniper: Texture2D
@export var icon_heavy: Texture2D

@export var spawn_offset: Vector2 = Vector2(48, 0)

# ---------------- Internals ----------------
var btn_inf: TextureButton
var btn_snp: TextureButton
var btn_hvy: TextureButton
var lbl_inf_cost: Label
var lbl_snp_cost: Label
var lbl_hvy_cost: Label

func _ready() -> void:
	_build_ui()
	_style_buttons()
	_connect_signals()
	_update_cost_labels()
	_assign_icons()

func _process(_dt: float) -> void:
	if btn_inf: btn_inf.disabled = Global.Metal < cost_infantry
	if btn_snp: btn_snp.disabled = Global.Metal < cost_sniper
	if btn_hvy:
		btn_hvy.disabled = (Global.Metal < cost_heavy) or (Global.Uranium < uranium_heavy)

# ---------------- UI Construction ----------------
func _build_ui() -> void:
	anchor_left = 1.0; anchor_top = 1.0; anchor_right = 1.0; anchor_bottom = 1.0
	offset_left = -240; offset_top = -140; offset_right = -8; offset_bottom = -8
	mouse_filter = Control.MOUSE_FILTER_PASS

	var panel := Panel.new()
	panel.name = "Panel"
	panel.offset_right = 232
	panel.offset_bottom = 132
	add_child(panel)

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.1, 0.1, 0.88)
	sb.set_corner_radius_all(8)
	panel.add_theme_stylebox_override("panel", sb)

	var h := HBoxContainer.new()
	h.name = "HBox"
	h.offset_left = 8; h.offset_top = 8; h.offset_right = 224; h.offset_bottom = 124
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	h.add_theme_constant_override("separation", 8)
	panel.add_child(h)
	
	var legend := Label.new()
	legend.text = "M = Metal  •  U = Uranium"
	legend.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	legend.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	legend.position = Vector2(8, 124)  # below the HBox inside the panel
	legend.size = Vector2(224, 16)
	panel.add_child(legend)


	# build the 3 unit cards
	var inf = _make_card("Infantry")
	var snp = _make_card("Sniper")
	var hvy = _make_card("Heavy")
	h.add_child(inf.box)
	h.add_child(snp.box)
	h.add_child(hvy.box)

	btn_inf = inf.btn
	lbl_inf_cost = inf.cost
	btn_snp = snp.btn
	lbl_snp_cost = snp.cost
	btn_hvy = hvy.btn
	lbl_hvy_cost = hvy.cost

# --- helper to build one unit "card" ---
func _make_card(unit_name: String) -> Dictionary:
	var v := VBoxContainer.new()
	var btn := TextureButton.new()
	var name_lbl := Label.new()
	var cost_lbl := Label.new()

	btn.name = unit_name + "Btn"
	btn.set_unique_name_in_owner(true)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.size_flags_vertical = Control.SIZE_EXPAND_FILL
	btn.stretch_mode = TextureButton.STRETCH_KEEP_CENTERED

	name_lbl.text = unit_name
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	cost_lbl.name = unit_name + "Cost"
	cost_lbl.set_unique_name_in_owner(true)
	cost_lbl.text = "—"
	cost_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	v.add_child(btn)
	v.add_child(name_lbl)
	v.add_child(cost_lbl)

	return {"box": v, "btn": btn, "cost": cost_lbl}

# ---------------- Styling ----------------
func _style_buttons() -> void:
	var normal_box := StyleBoxFlat.new()
	normal_box.bg_color = Color(0.12, 0.12, 0.12, 0.75)
	normal_box.border_color = Color(0.85, 0.85, 0.10, 1.0)
	normal_box.set_border_width_all(2)
	normal_box.set_corner_radius_all(6)

	var hover_box := normal_box.duplicate() as StyleBoxFlat
	hover_box.border_color = Color(1.0, 1.0, 0.30, 1.0)
	hover_box.bg_color = Color(0.15, 0.15, 0.15, 0.85)

	var pressed_box := normal_box.duplicate() as StyleBoxFlat
	pressed_box.border_color = Color(1.0, 0.9, 0.2, 1.0)
	pressed_box.bg_color = Color(0.18, 0.18, 0.18, 0.92)

	for b in [btn_inf, btn_snp, btn_hvy]:
		b.add_theme_stylebox_override("normal", normal_box)
		b.add_theme_stylebox_override("hover", hover_box)
		b.add_theme_stylebox_override("pressed", pressed_box)
		b.add_theme_stylebox_override("focus", hover_box)

# ---------------- Connections ----------------
func _connect_signals() -> void:
	btn_inf.pressed.connect(_on_buy_infantry)
	btn_snp.pressed.connect(_on_buy_sniper)
	btn_hvy.pressed.connect(_on_buy_heavy)

func _update_cost_labels() -> void:
	lbl_inf_cost.text = "%d M" % cost_infantry
	lbl_snp_cost.text = "%d M" % cost_sniper
	lbl_hvy_cost.text = "%d M + %d U" % [cost_heavy, uranium_heavy]

func _assign_icons() -> void:
	if icon_infantry: btn_inf.texture_normal = icon_infantry
	if icon_sniper:   btn_snp.texture_normal = icon_sniper
	if icon_heavy:    btn_hvy.texture_normal = icon_heavy

# ---------------- Buy / Spawn ----------------
func _on_buy_infantry() -> void: _buy(Global.UnitType.INFANTRY, cost_infantry)
func _on_buy_sniper()   -> void: _buy(Global.UnitType.SNIPER, cost_sniper)
func _on_buy_heavy()    -> void: _buy(Global.UnitType.HEAVY,  cost_heavy)

func _buy(unit_type: int, cost: int) -> void:
	var need_u := (unit_type == Global.UnitType.HEAVY)
	var u_cost := uranium_heavy if need_u else 0

	if Global.Metal < cost:
		print("Shop: Not enough Metal (need %d, have %d)" % [cost, Global.Metal])
		return
	if need_u and Global.Uranium < u_cost:
		print("Shop: Not enough Uranium (need %d, have %d)" % [u_cost, Global.Uranium])
		return

	var pos := _get_spawn_position()
	if pos == null:
		push_warning("Shop: No Roboshop building (group 'Roboshop').")
		return

	Global.Metal -= cost
	if need_u:
		Global.Uranium -= u_cost
	print("Shop: Spent %d M%s  |  Metal=%d, Uranium=%d" %
	[cost, (" + %d U" % u_cost) if need_u else "", Global.Metal, Global.Uranium])
	
	Global.spawnUnit(pos, false, unit_type)


func _get_spawn_position() -> Vector2:
	for n in get_tree().get_nodes_in_group("Roboshop"):
		if n is Node2D:
			return (n as Node2D).global_position + spawn_offset
	return get_viewport().get_visible_rect().size / 2.0
