extends Control

# --- Icons (override in Inspector if you want)
@export var icon_infantry: Texture2D = preload("res://RTSAssets/ShopUI/InfIcon.png")
@export var icon_sniper:   Texture2D = preload("res://RTSAssets/ShopUI/SniperIcon.png")
@export var icon_heavy:    Texture2D = preload("res://RTSAssets/ShopUI/HeavyIcon.png")
@export var refresh_rate_hz: float = 10.0  # 10x per second

# Which properties to try to read from a unit (we'll show whatever exists)
const STAT_KEYS := [
	["HP", "Health", "health", "hp"],
	["Damage", "AttackDamage", "attack_damage", "damage"],
	["Range", "AttackRange", "attack_range", "range"],
	["Speed", "Speed", "speed"],
	# Display label "Attack Speed", read from any attack delay property names you use
	["Attack Speed", "AttackDelay", "attack_delay", "FireDelay", "fire_delay", "attack_cooldown"],
]


var _icon: TextureRect
var _name: Label
var _grid: GridContainer
var _value_labels: Dictionary = {}  # "HP" -> Label
var _selected_cached: Node = null
var _refresh_accum: float = 0.0


func _ready() -> void:
	_build_ui()
	_try_connect_global_signal()
	if Global.has_signal("selected_unit_changed"):
		Global.selected_unit_changed.connect(func(u: Node):
			_selected_cached = u
			_update(u)
		)

func _process(dt: float) -> void:
	var raw = Global.get("SelectedUnit")  # may be null or freed
	var u: Node = null
	if raw != null and is_instance_valid(raw):
		u = raw as Node


	# If selection changed
	if u != _selected_cached:
		if _selected_cached and is_instance_valid(_selected_cached):
			if _selected_cached.tree_exited.is_connected(_on_selected_freed):
				_selected_cached.tree_exited.disconnect(_on_selected_freed)

		_selected_cached = u

		# watch for this unit being freed (dies / removed from tree)
		if u:
			u.tree_exited.connect(_on_selected_freed, CONNECT_ONE_SHOT)

		_update(u)
		_refresh_accum = 0.0
	else:
		# same unit selected: refresh periodically
		_refresh_accum += dt
		if _refresh_accum >= 1.0 / max(1.0, refresh_rate_hz):
			_refresh_accum = 0.0
			if u != null:
				_update(u)



	if u != _selected_cached:
		_selected_cached = u
		_update(u)


func _on_selected_freed() -> void:
	_selected_cached = null
	_update(null)


# -------- UI ----------
func _build_ui() -> void:
	# bottom-left, like a HUD card
	anchor_left = 0.0; anchor_top = 1.0; anchor_right = 0.0; anchor_bottom = 1.0
	offset_left = 8; offset_top = -195; offset_right = 260; offset_bottom = -8

	var panel := Panel.new()
	panel.size = Vector2(252, 192)   # was ~212,132
	add_child(panel)

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1,0.1,0.1,0.88)
	sb.set_corner_radius_all(8)
	panel.add_theme_stylebox_override("panel", sb)

	var root := VBoxContainer.new()
	root.anchor_right = 1.0; root.anchor_bottom = 1.0
	root.offset_left = 8; root.offset_top = 8; root.offset_right = -8; root.offset_bottom = -8
	panel.add_child(root)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	root.add_child(top)

	_icon = TextureRect.new()
	_icon.custom_minimum_size = Vector2(40,40)
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	top.add_child(_icon)

	_name = Label.new()
	_name.text = "No unit selected"
	_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top.add_child(_name)
	top.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_grid = GridContainer.new()
	_grid.columns = 2
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 2)
	root.add_child(_grid)

	for key_group in STAT_KEYS:
		var nice := key_group[0] as String
		var klabel := Label.new(); klabel.text = nice + ":"
		var vlabel := Label.new(); vlabel.text = "-"
		_grid.add_child(klabel); _grid.add_child(vlabel)
		_value_labels[nice] = vlabel

	# start hidden until a unit is selected
	_set_visible(false)

func _set_visible(on: bool) -> void:
	visible = on

# -------- Data update ----------
func _update(u: Node) -> void:
	if u == null:
		_set_visible(false)
		return
	_set_visible(true)

	_name.text = _pretty_unit_name(u)
	_icon.texture = _pick_icon_for(u)

	# Fill stats if present
	for key_group in STAT_KEYS:
		var nice: String = key_group[0]
		var shown: String = "-"

		if nice == "Attack Speed":
			# derive from delay: attacks per second
			var delay: float = -1.0
			for real_key in key_group.slice(1): # skip the display label
				var v = u.get(real_key)
				if v != null:
					delay = float(v)
					break
			if delay > 0.0:
				var aps := 1.0 / delay
				# format to 2 decimals
				shown = "%s /s" % str(round(aps * 100.0) / 100.0)
		else:
			for real_key in key_group:
				var val = u.get(real_key)
				if val != null:
					shown = str(val)
					break
					
		(_value_labels[nice] as Label).text = shown


func _pretty_unit_name(u: Node) -> String:
	# Try unit_type or infer from script/path/name
	var t = u.get("unit_type")
	if t != null and typeof(t) in [TYPE_INT, TYPE_STRING]:
		return _enum_to_name(t)
	var rp: String = ""
	var scr: Variant = u.get("script")
	if scr is Script:
		rp = (scr as Script).resource_path
	var nm: String = str(u.name)

	if rp.findn("Heavy") != -1 or nm.findn("Heavy") != -1: return "Heavy"
	if rp.findn("Sniper") != -1 or nm.findn("Sniper") != -1: return "Sniper"
	if rp.findn("Infantry") != -1 or nm.findn("Infantry") != -1: return "Infantry"
	return nm

func _enum_to_name(t) -> String:
	# Works if you use Global.UnitType enum
	if typeof(t) == TYPE_INT:
		match t:
			Global.UnitType.HEAVY: return "Heavy"
			Global.UnitType.SNIPER: return "Sniper"
			Global.UnitType.INFANTRY: return "Infantry"
	return str(t)

func _pick_icon_for(u: Node) -> Texture2D:
	var n := _pretty_unit_name(u)
	if n == "Heavy": return icon_heavy
	if n == "Sniper": return icon_sniper
	if n == "Infantry": return icon_infantry
	return icon_infantry

# -------- Selection hook ----------
func _try_connect_global_signal() -> void:
	if Global.has_signal("selected_unit_changed"):
		Global.selected_unit_changed.connect(
			func (u): 
				_selected_cached = u
				_update(u)
		)
