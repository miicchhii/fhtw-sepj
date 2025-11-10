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
	["AI Model"],  # Special handling for policy_id
]

# Available AI policies (loaded dynamically from JSON)
var available_policies: Array = []
var policy_display_names: Dictionary = {}


var _icon_container: HBoxContainer  # Container for one or more icons
var _name: Label
var _grid: GridContainer
var _value_labels: Dictionary = {}  # "HP" -> Label
var _policy_dropdown: OptionButton  # Dropdown for policy selection
var _selected_cached: Node = null
var _refresh_accum: float = 0.0


func _ready() -> void:
	load_available_policies()
	_build_ui()
	_try_connect_global_signal()
	if Global.has_signal("selected_unit_changed"):
		Global.selected_unit_changed.connect(func(u: Node):
			_selected_cached = u
			_update(u)
		)

func load_available_policies() -> void:
	"""Load available policies from JSON configuration"""
	var config_path = "res://config/ai_policies.json"
	var file = FileAccess.open(config_path, FileAccess.READ)

	if not file:
		push_error("Failed to load ai_policies.json")
		return

	var json = JSON.new()
	var error = json.parse(file.get_as_text())
	file.close()

	if error != OK:
		push_error("Failed to parse ai_policies.json: " + json.get_error_message())
		return

	var data = json.data
	if not data.has("policies"):
		push_error("Invalid ai_policies.json: missing 'policies' key")
		return

	var policies = data["policies"]
	for policy_id in policies.keys():
		available_policies.append(policy_id)
		policy_display_names[policy_id] = policies[policy_id].get("display_name", policy_id)

	print("UnitInfoUI: Loaded ", available_policies.size(), " policies")

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

# -------- Selection Helpers ----------
func get_all_selected_units() -> Array:
	"""Get all units with selected=true from ally group"""
	if not is_inside_tree():
		return []
	return get_tree().get_nodes_in_group("ally").filter(
		func(u): return u != null and is_instance_valid(u) and u.get("selected") == true
	)

func count_units_by_type(units: Array) -> Dictionary:
	"""
	Count units grouped by type.
	Returns: {"Infantry": 3, "Sniper": 2, "Heavy": 1}
	"""
	var counts := {}
	for unit in units:
		var type_name = _pretty_unit_name(unit)
		counts[type_name] = counts.get(type_name, 0) + 1
	return counts

func get_unique_policies(units: Array) -> Array:
	"""Get list of unique policy_ids from selected units"""
	var policies := []
	for unit in units:
		var pid = unit.get("policy_id")
		if pid != null and pid != "" and not policies.has(pid):
			policies.append(pid)
	return policies

# -------- UI ----------
func _build_ui() -> void:
	# bottom-left, like a HUD card
	anchor_left = 0.0; anchor_top = 1.0; anchor_right = 0.0; anchor_bottom = 1.0
	offset_left = 8; offset_top = -280; offset_right = 260; offset_bottom = -8

	var panel := Panel.new()
	panel.size = Vector2(252, 272)   # Increased height to accommodate dropdown
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

	# Icon container - will hold one or more unit type icons
	_icon_container = HBoxContainer.new()
	_icon_container.add_theme_constant_override("separation", 4)
	_icon_container.custom_minimum_size = Vector2(40, 40)
	top.add_child(_icon_container)

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

	# Add policy selection dropdown
	var policy_label := Label.new()
	policy_label.text = "Change AI Model:"
	root.add_child(policy_label)

	_policy_dropdown = OptionButton.new()
	for policy_id in available_policies:
		var display_name = policy_display_names.get(policy_id, policy_id)
		_policy_dropdown.add_item(display_name)
	_policy_dropdown.item_selected.connect(_on_policy_selected)
	root.add_child(_policy_dropdown)

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

	# Get all selected units for multi-selection support
	var all_selected = get_all_selected_units()

	# Update icon display based on selection
	_update_icon_display(all_selected)

	# Update name display
	var type_counts = count_units_by_type(all_selected)
	if all_selected.size() > 1:
		if type_counts.size() == 1:
			# All same type
			_name.text = "%s (%d units)" % [_pretty_unit_name(u), all_selected.size()]
		else:
			# Multiple types - just show total count
			_name.text = "%d units selected" % all_selected.size()
	else:
		_name.text = _pretty_unit_name(u)

	# Fill stats if present
	# Hide individual stats for mixed type selection (stats vary by type)
	var show_individual_stats = type_counts.size() == 1

	for key_group in STAT_KEYS:
		var nice: String = key_group[0]
		var shown: String = "-"

		if nice == "AI Model":
			# Always show policy for all selection types
			shown = _get_policy_display(all_selected)
		elif not show_individual_stats:
			# Mixed types - don't show unit-specific stats
			shown = "-"
		elif nice == "Attack Speed":
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
	return _get_icon_by_name(n)

func _get_icon_by_name(type_name: String) -> Texture2D:
	"""Get icon texture for a unit type name"""
	if type_name == "Heavy": return icon_heavy
	if type_name == "Sniper": return icon_sniper
	if type_name == "Infantry": return icon_infantry
	return icon_infantry

func _update_icon_display(units: Array) -> void:
	"""Update icon display based on selected units"""
	# Clear existing icons
	for child in _icon_container.get_children():
		child.queue_free()

	if units.is_empty():
		return

	var type_counts = count_units_by_type(units)

	if type_counts.size() == 1:
		# Single type: show large icon
		var icon = TextureRect.new()
		icon.custom_minimum_size = Vector2(40, 40)
		icon.expand_mode = TextureRect.EXPAND_FIT_HEIGHT
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture = _pick_icon_for(units[0])
		_icon_container.add_child(icon)
	else:
		# Multiple types: show small icons with counts
		# Total height must match single icon (40px) to prevent layout shift
		for type_name in type_counts.keys():
			var vbox = VBoxContainer.new()
			vbox.add_theme_constant_override("separation", 0)
			vbox.custom_minimum_size = Vector2(28, 40)
			vbox.size = Vector2(28, 40)  # Force exact size to prevent layout shift
			vbox.size_flags_vertical = Control.SIZE_SHRINK_BEGIN

			# Small icon - takes remaining space after label
			var icon = TextureRect.new()
			icon.custom_minimum_size = Vector2(26, 26)
			icon.expand_mode = TextureRect.EXPAND_FIT_HEIGHT
			icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			icon.texture = _get_icon_by_name(type_name)
			icon.size_flags_vertical = Control.SIZE_EXPAND_FILL
			vbox.add_child(icon)

			# Count label below
			var count_label = Label.new()
			count_label.text = str(type_counts[type_name])
			count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			count_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
			count_label.add_theme_font_size_override("font_size", 12)
			count_label.size_flags_vertical = Control.SIZE_SHRINK_END
			vbox.add_child(count_label)

			_icon_container.add_child(vbox)

func _get_policy_display(units: Array) -> String:
	"""Get policy display string for selected units"""
	var policies = get_unique_policies(units)

	if policies.is_empty():
		return "None"
	elif policies.size() == 1:
		return _format_policy_name(policies[0])
	else:
		return "Mixed"

func _format_policy_name(policy_id: String) -> String:
	"""Format policy_id for display (e.g., 'policy_LT50' -> 'LT50')"""
	if policy_id.begins_with("policy_"):
		return policy_id.substr(7)  # Remove "policy_" prefix
	return policy_id

func _on_policy_selected(index: int) -> void:
	"""Handle policy selection from dropdown - applies to ALL selected units"""
	if index < 0 or index >= available_policies.size():
		return

	var selected_policy = available_policies[index]
	var units = get_all_selected_units()

	if units.is_empty():
		return

	# Apply policy to all selected units
	for unit in units:
		if unit.has_method("set_policy"):
			unit.set_policy(selected_policy)

	# Show feedback in console
	print("Applied policy '%s' to %d unit(s)" % [_format_policy_name(selected_policy), units.size()])

	# Refresh display to show updated policy
	if _selected_cached != null:
		_update(_selected_cached)

# -------- Selection hook ----------
func _try_connect_global_signal() -> void:
	if Global.has_signal("selected_unit_changed"):
		Global.selected_unit_changed.connect(
			func (u): 
				_selected_cached = u
				_update(u)
		)
