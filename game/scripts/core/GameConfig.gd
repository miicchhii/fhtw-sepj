# GameConfig.gd - Centralized game configuration constants
#
# This file contains all magic numbers and configuration values used across the game.
# By centralizing these values, we ensure:
# - No duplicate constants across GDScript and Python
# - Easy tuning without hunting through code
# - Clear documentation of what each value means
# - Single source of truth for game parameters

class_name GameConfig

# =============================================================================
# MAP DIMENSIONS
# =============================================================================

const MAP_WIDTH: int = 2560   # Map width in pixels (1280 * 2)
const MAP_HEIGHT: int = 1440  # Map height in pixels (720 * 2)

# =============================================================================
# AI TIMING
# =============================================================================

const AI_TICK_INTERVAL: int = 15  # Run AI logic every N physics ticks (~4 AI steps/second at 60 FPS)
const PHYSICS_FPS: int = 60        # Expected physics framerate
# Derived: AI steps per second = PHYSICS_FPS / AI_TICK_INTERVAL = 60 / 15 = 4

# =============================================================================
# EPISODE MANAGEMENT
# =============================================================================

const MAX_EPISODE_STEPS: int = 500  # Maximum AI steps before episode auto-terminates

# =============================================================================
# UNIT CONFIGURATION
# =============================================================================

const NUM_ALLY_UNITS: int = 50    # Number of ally units per episode
const NUM_ENEMY_UNITS: int = 50   # Number of enemy units per episode
const TOTAL_UNITS: int = NUM_ALLY_UNITS + NUM_ENEMY_UNITS  # 100 total units

# Unit composition (for spawn logic)
const SNIPER_SPAWN_INTERVAL: int = 3  # Spawn 1 sniper every N units (33% snipers, 67% infantry)

# =============================================================================
# SPAWN POSITIONING
# =============================================================================

# Base spawn margins (safe distance from map edges)
const BASE_SPAWN_MARGIN_X: float = 150.0  # Horizontal margin for base placement
const BASE_SPAWN_MARGIN_Y: float = 150.0  # Vertical margin for base placement

# Unit spawn box positions (where unit formations start)
const UNIT_SPAWNBOX_X_LEFT: float = 50.0    # X position for left-side spawn
const UNIT_SPAWNBOX_X_RIGHT: float = MAP_WIDTH / 2.0  # X position for right-side spawn (center)
const UNIT_SPAWNBOX_Y: float = 100.0        # Y position for both spawn boxes

# Unit spawn grid parameters
const UNIT_SPAWN_SPACING_X: float = 250.0  # Horizontal spacing between units in formation
const UNIT_SPAWN_SPACING_Y: float = 133.0  # Vertical spacing between units in formation
const UNIT_SPAWN_COLUMNS: int = 5          # Number of columns in spawn formation

# =============================================================================
# MOVEMENT PARAMETERS
# =============================================================================

const AI_ACTION_STEPSIZE: float = 200.0  # Maximum movement distance per AI step (pixels)
# This is the distance a unit can move when AI outputs action magnitude = 1.0
# Smaller magnitudes result in proportionally smaller movements

# Movement magnitude interpretation:
# - magnitude = 1.0 → full step (200 pixels)
# - magnitude = 0.5 → half step (100 pixels)
# - magnitude = 0.0 → no movement

# =============================================================================
# REWARD CONFIGURATION
# =============================================================================
# Note: These are default values. Game.gd may override them for tuning.
# Consider making these non-const if you want runtime modification.

# Combat rewards
const REWARD_DAMAGE_TO_UNIT: float = 0.2    # Reward per damage point to enemy units
const REWARD_DAMAGE_TO_BASE: float = 1.0    # Reward per damage point to enemy base
const REWARD_UNIT_KILL: float = 15.0        # Reward for killing an enemy unit
const REWARD_BASE_KILL: float = 200.0       # Reward for destroying enemy base
const PENALTY_DAMAGE_RECEIVED: float = 0.1  # Penalty per damage point received
const PENALTY_DEATH: float = 5.0            # Penalty for dying

# Team outcome rewards
const REWARD_TEAM_VICTORY: float = 50.0     # Bonus when your team wins
const PENALTY_TEAM_DEFEAT: float = 25.0     # Penalty when your team loses

# Positional rewards
const REWARD_POSITION_MULTIPLIER: float = 1.5  # Multiplier for proximity to enemy base

# Survival reward
const REWARD_ALIVE_PER_STEP: float = 0.01   # Small reward for staying alive each step

# Movement efficiency
const REWARD_CONTINUE_STRAIGHT: float = 0.5    # Reward for maintaining direction
const PENALTY_REVERSE_DIRECTION: float = 1.0   # Penalty for reversing direction

# Base damage penalty
const PENALTY_BASE_DAMAGE_PER_UNIT: float = 0.5  # Penalty per damage to your base (divided among units)

# Tactical spacing (anti-clustering)
const REWARD_TACTICAL_SPACING: float = 0.1        # Penalty per nearby ally
const TACTICAL_SPACING_THRESHOLD: float = 100.0   # Minimum desired spacing (pixels)

# =============================================================================
# OBSERVATION SPACE CONFIGURATION
# =============================================================================

const OBS_DIM_BASE: int = 3          # vel_x, vel_y, hp_ratio
const OBS_DIM_BATTLE_STATS: int = 5  # attack_range, attack_damage, attack_cooldown, remaining_cooldown, speed
const OBS_DIM_ALLIES: int = 40       # 10 closest allies × (dir_x, dir_y, distance, hp_ratio)
const OBS_DIM_ENEMIES: int = 40      # 10 closest enemies × (dir_x, dir_y, distance, hp_ratio)
const OBS_DIM_POIS: int = 6          # 2 POIs × (dir_x, dir_y, distance)

const OBS_DIM_TOTAL: int = OBS_DIM_BASE + OBS_DIM_BATTLE_STATS + OBS_DIM_ALLIES + OBS_DIM_ENEMIES + OBS_DIM_POIS  # 94

const MAX_ALLIES_IN_OBS: int = 10    # Track 10 closest allies
const MAX_ENEMIES_IN_OBS: int = 10   # Track 10 closest enemies
const NUM_POIS: int = 2              # 2 points of interest (ally base, enemy base)

# =============================================================================
# NORMALIZATION CONSTANTS (for Python environment)
# =============================================================================
# These should match values in godot_multi_env.py

const MAX_EXPECTED_SPEED: float = 100.0       # For velocity normalization
const MAX_EXPECTED_ATTACK_RANGE: float = 200.0  # For attack range normalization

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

static func get_half_map_width() -> float:
	"""Returns the X coordinate of the map center."""
	return MAP_WIDTH / 2.0

static func get_map_center() -> Vector2:
	"""Returns the center position of the map."""
	return Vector2(MAP_WIDTH * 0.5, MAP_HEIGHT * 0.5)

static func is_position_in_bounds(pos: Vector2) -> bool:
	"""Check if a position is within map boundaries."""
	return pos.x >= 0 and pos.x <= MAP_WIDTH and pos.y >= 0 and pos.y <= MAP_HEIGHT

static func clamp_to_map(pos: Vector2) -> Vector2:
	"""Clamp a position to map boundaries."""
	return Vector2(
		clamp(pos.x, 0, MAP_WIDTH),
		clamp(pos.y, 0, MAP_HEIGHT)
	)
