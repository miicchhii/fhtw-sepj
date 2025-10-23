---
editor_options: 
  markdown: 
    wrap: 72
---

# Observation and Action Spaces

This document describes the observation and action spaces used in the
multi-agent RTS training system.

## Observation Space

Each unit receives a **92-dimensional observation vector** normalized to
the range `[-1.0, 10.0]`.

### Structure (92 dimensions total)

#### 1. Base Information (4 dimensions)

-   **norm_x** (1D): Normalized x-position on map, range [-1, 1]
-   **norm_y** (1D): Normalized y-position on map, range [-1, 1]
-   **hp_ratio** (1D): Current HP / Max HP, range [0, 1]
-   **dist_to_center** (1D): Normalized distance to map center, range
    [0, \~1.4]

#### 2. Battle Statistics (5 dimensions)

-   **attack_range** (1D): Maximum attack range in pixels
-   **attack_damage** (1D): Damage dealt per attack
-   **attack_cooldown** (1D): Time between attacks in seconds
-   **attack_cooldown_remaining** (1D): Current cooldown timer
-   **speed** (1D): Movement speed in pixels/second

#### 3. Closest Allies (40 dimensions = 10 units × 4 values)

For each of the 10 closest allied units: - **direction_x** (1D): X
component of normalized direction vector - **direction_y** (1D): Y
component of normalized direction vector - **distance** (1D): Euclidean
distance in pixels - **hp_ratio** (1D): Ally's current HP / max HP

If fewer than 10 allies exist, remaining slots are zero-padded.

#### 4. Closest Enemies (40 dimensions = 10 units × 4 values)

For each of the 10 closest enemy units: - **direction_x** (1D): X
component of normalized direction vector - **direction_y** (1D): Y
component of normalized direction vector - **distance** (1D): Euclidean
distance in pixels - **hp_ratio** (1D): Enemy's current HP / max HP

If fewer than 10 enemies exist, remaining slots are zero-padded.

#### 5. Points of Interest (3 dimensions = 1 POI × 3 values)

For each point of interest (currently map center): - **direction_x**
(1D): X component of normalized direction vector to POI -
**direction_y** (1D): Y component of normalized direction vector to
POI - **distance** (1D): Euclidean distance to POI in pixels
(normalized)

**Current POIs:** - Map center (reward zone): Units gain positional
rewards for being near center

**Future POIs** (can be added to observation space): - Control points -
Resource locations - Strategic positions - Objectives

### Implementation Details

**Godot Side (`Game.gd`):** - Built in `_build_observation()` function -
Raw unit data sent as JSON via TCP socket - Includes metadata: unit_id,
policy_id, type_id, is_enemy - POI data calculated in `_get_poi_data()`
function

**Python Side (`godot_multi_env.py`):** - Converted in
`_extract_obs_and_agents()` function - Normalization applied to fit
observation space bounds - Map dimensions: Dynamically received from
Godot (currently 2560×1440 pixels) - POI distances normalized by map
diagonal

------------------------------------------------------------------------

## Action Space

Each unit has a **discrete action space with 9 possible actions**.

### Action Definitions

| Action | Direction        | Movement Offset (x, y) |
|--------|------------------|------------------------|
| 0      | Stay             | (0, 0)                 |
| 1      | Up-Left          | (-30, -30)             |
| 2      | Up               | (0, -30)               |
| 3      | Up-Right         | (30, -30)              |
| 4      | Left             | (-30, 0)               |
| 5      | Stay (duplicate) | (0, 0)                 |
| 6      | Right            | (30, 0)                |
| 7      | Down-Left        | (-30, 30)              |
| 8      | Down             | (0, 30)                |
| 9      | Down-Right       | (30, 30)               |

### Step Size

-   Default step size: **30 pixels** per AI step
-   Configurable in `godot_multi_env.py` (variable: `stepsize`)

### Action Frequency

-   AI actions executed every **15 physics ticks** (\~4 times per
    second)
-   Physics runs at 60 FPS
-   Action interval configurable via `ai_tick_interval` in `Game.gd`

### Implementation Details

**Python Side (`godot_multi_env.py`):** - Actions selected by policy
network (PPO) - Converted to movement targets in `step()` function -
Sent to Godot as `{"move": [x, y]}` commands via TCP

**Godot Side (`Game.gd`):** - Received in `_apply_actions()` function -
Applied via `unit.set_move_target(Vector2(x, y))` - Units move toward
target in `_physics_process()` at their speed

------------------------------------------------------------------------

## Multi-Policy Support

### Policy Assignment

Each unit is assigned to one of three policies:

| Policy             | Unit IDs | Status    | Description |
|--------------------|----------|-----------|-------------|
| `policy_LT50`      | u1-u50   | Trainable |             |
| `policy_GT50`      | u51-u75  | Frozen    |             |
| `policy_frontline` | u76-u100 | Trainable |             |

### Dynamic Policy Switching

-   Policy assignment sent in observations via `policy_id` field
-   Can be changed at runtime with `unit.set_policy("policy_name")` in
    Godot
-   Policy mapping handled by `policy_mapping_fn()` in
    `train_rllib_ppo_simple.py`

------------------------------------------------------------------------

## Episode Management

### Episode Length

-   Maximum: **200 AI steps** per episode
-   Real-time duration: \~50 seconds at 4 steps/second

### Termination Conditions

Episode ends when: 1. AI steps reach `max_episode_steps` (200), OR 2.
All ally units eliminated (defeat), OR 3. All enemy units eliminated
(victory)

### Reset Behavior

-   All units despawned and respawned
-   Spawn sides alternate each episode for position-invariant learning
-   Unit IDs reset to u1-u100
-   AI step counter reset to 0

------------------------------------------------------------------------

## Training Configuration

### Network Architecture

-   **Type**: Multi-layer perceptron (MLP)
-   **Layers**: [64, 64, 64] hidden units (3-layer MLP)
-   **Activation**: Tanh
-   **Weight Init**: Xavier uniform
-   **Bias Init**: Zeros

### PPO Hyperparameters

-   **Learning rate**: 3e-4 (0.0003 - standard PPO)
-   **Discount factor (gamma)**: 0.99 (values rewards \~200 steps ahead)
-   **GAE lambda**: 0.9 (uses \~10 steps of real rewards)
-   **Clip parameter**: 0.2
-   **Entropy coefficient**: 0.01 (increased for exploration)
-   **Train batch size**: 2000 timesteps
-   **Minibatch size**: 500 timesteps
-   **Epochs per iteration**: 10

### Reward Structure

-   **Damage dealt**: +0.1 per damage point
-   **Kill**: +15.0 per enemy killed
-   **Damage received**: -0.1 per damage point
-   **Death**: -5.0
-   **Position (center proximity)**: +0.1 at center, -0.1 at edges
    (reduced influence)
-   **Survival**: +0.01 per step alive

------------------------------------------------------------------------

## File References

### Godot (GDScript)

-   **Observation building**: `game/scripts/core/Game.gd` →
    `_build_observation()`
-   **Action application**: `game/scripts/core/Game.gd` →
    `_apply_actions()`
-   **Policy assignment**: `game/scripts/units/RTSUnit.gd` →
    `_assign_policy()`

### Python (Ray RLlib)

-   **Environment wrapper**: `ai/godot_multi_env.py` →
    `GodotRTSMultiAgentEnv`
-   **Training script**: `ai/train_rllib_ppo_simple.py`
-   **Policy mapping**: `ai/train_rllib_ppo_simple.py` →
    `policy_mapping_fn()`
