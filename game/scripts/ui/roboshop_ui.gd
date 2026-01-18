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

@export var spawn_radius_min: float = 32.0
@export var spawn_radius_max: float = 96.0
var _rng: RandomNumberGenerator


# ---------------- Internals ----------------
var btn_inf: TextureButton
var btn_snp: TextureButton
var btn_hvy: TextureButton
var lbl_inf_cost: Label
var lbl_snp_cost: Label
var lbl_hvy_cost: Label

# Policy selection
var _policy_dropdown: OptionButton
var _available_policies: Array = []
var _policy_display_names: Dictionary = {}
var _selected_policy: String = ""

func _ready() -> void:
	_load_available_policies()
	_build_ui()
	_style_buttons()
	_connect_signals()
	_update_cost_labels()
	_assign_icons()
	_rng = RandomNumberGenerator.new()
	_rng.randomize()

func _load_available_policies() -> void:
	"""Load available policies from JSON configuration"""
	var config_path = "res://config/ai_policies.json"
	var file = FileAccess.open(config_path, FileAccess.READ)

	if not file:
		push_error("RoboshopUI: Failed to load ai_policies.json")
		return

	var json = JSON.new()
	var error = json.parse(file.get_as_text())
	file.close()

	if error != OK:
		push_error("RoboshopUI: Failed to parse ai_policies.json: " + json.get_error_message())
		return

	var data = json.data
	if not data.has("policies"):
		push_error("RoboshopUI: Invalid ai_policies.json: missing 'policies' key")
		return

	var policies = data["policies"]
	for policy_id in policies.keys():
		_available_policies.append(policy_id)
		_policy_display_names[policy_id] = policies[policy_id].get("display_name", policy_id)

	# Set default policy to first available
	if _available_policies.size() > 0:
		_selected_policy = _available_policies[0]

	print("RoboshopUI: Loaded ", _available_policies.size(), " policies")


func _process(_dt: float) -> void:
	if btn_inf: btn_inf.disabled = Global.Metal < cost_infantry
	if btn_snp: btn_snp.disabled = Global.Metal < cost_sniper
	if btn_hvy:
		btn_hvy.disabled = (Global.Metal < cost_heavy) or (Global.Uranium < uranium_heavy)

# ---------------- UI Construction ----------------
func _build_ui() -> void:
	anchor_left = 1.0; anchor_top = 1.0; anchor_right = 1.0; anchor_bottom = 1.0
	offset_left = -240; offset_top = -210; offset_right = -8; offset_bottom = -8
	mouse_filter = Control.MOUSE_FILTER_PASS

	var panel := Panel.new()
	panel.name = "Panel"
	panel.offset_right = 232
	panel.offset_bottom = 205
	add_child(panel)

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.1, 0.1, 0.88)
	sb.set_corner_radius_all(8)
	panel.add_theme_stylebox_override("panel", sb)

	# container that pads the panel and stacks content vertically
	var v := VBoxContainer.new()
	v.anchor_right = 1.0
	v.anchor_bottom = 1.0
	v.offset_left = 8
	v.offset_top = 8
	v.offset_right = -8
	v.offset_bottom = -8
	v.add_theme_constant_override("separation", 6)
	panel.add_child(v)

	# --- Title label at the top ---
	var title := Label.new()
	title.text = "Construction Shop"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color.WHITE)
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	title.add_theme_constant_override("outline_size", 2)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(title)


	var h := HBoxContainer.new()
	h.name = "HBox"
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	h.add_theme_constant_override("separation", 8)
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(h)


	var legend := Label.new()
	legend.text = "M = Metal  •  U = Uranium"
	legend.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	legend.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(legend)

	# --- Policy selection dropdown ---
	var policy_row := HBoxContainer.new()
	policy_row.alignment = BoxContainer.ALIGNMENT_CENTER
	policy_row.add_theme_constant_override("separation", 6)
	policy_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(policy_row)

	var policy_label := Label.new()
	policy_label.text = "Model:"
	policy_label.add_theme_font_size_override("font_size", 12)
	policy_row.add_child(policy_label)

	_policy_dropdown = OptionButton.new()
	_policy_dropdown.custom_minimum_size = Vector2(140, 0)
	_policy_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for policy_id in _available_policies:
		var display_name = _policy_display_names.get(policy_id, policy_id)
		_policy_dropdown.add_item(display_name)
	_policy_dropdown.item_selected.connect(_on_policy_selected)
	policy_row.add_child(_policy_dropdown)

	panel.custom_minimum_size = Vector2(232, 190)

	
	
	
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
	
	normal_box.content_margin_left = 2
	normal_box.content_margin_top = 2
	normal_box.content_margin_right = 2
	normal_box.content_margin_bottom = 2

	var hover_box := normal_box.duplicate() as StyleBoxFlat
	hover_box.border_color = Color(1.0, 1.0, 0.30, 1.0)
	hover_box.bg_color = Color(0.15, 0.15, 0.15, 0.85)

	var pressed_box := normal_box.duplicate() as StyleBoxFlat
	pressed_box.border_color = Color(1.0, 0.9, 0.2, 1.0)
	pressed_box.bg_color = Color(0.18, 0.18, 0.18, 0.92)
	
	normal_box.border_color = Color(0.8, 0.8, 0.1, 1)
	hover_box.border_color  = Color(1, 1, 0.4, 1)
	pressed_box.border_color = Color(1, 0.7, 0.2, 1)

	for b in [btn_inf, btn_snp, btn_hvy]:
		b.mouse_entered.connect(func(): b.scale = Vector2(1.1, 1.1))
		b.mouse_exited.connect(func(): b.scale = Vector2(1.0, 1.0))
		b.pressed.connect(func(): b.modulate = Color(0.8, 0.8, 0.8))
		b.button_up.connect(func(): b.modulate = Color(1, 1, 1))
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

func _on_policy_selected(index: int) -> void:
	"""Handle policy selection from dropdown"""
	if index >= 0 and index < _available_policies.size():
		_selected_policy = _available_policies[index]

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

	Global.spawnUnit(pos, false, unit_type, _selected_policy)


func _get_spawn_position() -> Vector2:
	# Find the player's shop by finding the shop closest to the ally base
	var center: Vector2 = Vector2.ZERO

	# First, find the ally base position
	var ally_bases = get_tree().get_nodes_in_group("ally_base")
	if ally_bases.is_empty():
		print("Warning: No ally base found, using screen center")
		return get_viewport().get_visible_rect().size / 2.0

	var ally_base_pos: Vector2 = (ally_bases[0] as Node2D).global_position
	print("Ally base at: ", ally_base_pos)

	# Find the shop closest to the ally base
	var all_shops = get_tree().get_nodes_in_group("Roboshop")
	print("Found ", all_shops.size(), " shops in Roboshop group")

	var closest_shop: Node2D = null
	var closest_dist: float = INF

	for n in all_shops:
		if n is Node2D:
			var shop_pos: Vector2 = (n as Node2D).global_position
			var dist: float = shop_pos.distance_to(ally_base_pos)
			print("  Shop: ", n.name, " pos=", shop_pos, " dist_to_ally_base=", dist)
			if dist < closest_dist:
				closest_dist = dist
				closest_shop = n as Node2D

	if closest_shop:
		center = closest_shop.global_position
		print("  -> Using closest shop at ", center)
	else:
		print("Warning: No shops found, using screen center")
		return get_viewport().get_visible_rect().size / 2.0

	# try a few random spots in an annulus around the shop
	var min_r: float = spawn_radius_min
	var max_r: float = max(spawn_radius_max, min_r + 1.0)
	var min_separation: float = 24.0

	for _i in 8:
		var angle := _rng.randf_range(-PI, PI)
		var radius := _rng.randf_range(min_r, max_r)
		var candidate := center + Vector2.from_angle(angle) * radius

		# simple separation check vs existing friendly units
		var ok := true
		var units_root := get_tree().get_root().get_node_or_null("World/Units2")
		if units_root:
			for u in units_root.get_children():
				if u is Node2D and (u as Node2D).global_position.distance_to(candidate) < min_separation:
					ok = false
					break
		if ok:
			return candidate

	# fallback if all attempts failed
	return center + Vector2(spawn_radius_min, 0)
