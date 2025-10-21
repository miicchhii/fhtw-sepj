# Claude Code Configuration

This file contains configuration and instructions for Claude Code to help with development of this multi-agent RTS training project.

## Project Overview

This project implements a multi-agent reinforcement learning system where AI agents learn to control RTS (Real-Time Strategy) units in a Godot game environment. The system uses Ray RLlib with PPO (Proximal Policy Optimization) to train multiple agents across multiple policies with configurable reward shaping.

## Architecture

### Components
- **Godot Game** (`game/`): RTS game built in Godot 4.x that hosts many controllable units in team-based combat
- **AI Training** (`ai/`): Python-based training system using Ray RLlib
- **Communication**: TCP socket connection between Godot and Python training

### Key Files
- `ai/train_rllib_ppo_simple.py`: Main training script with PPO configuration and policy management
- `ai/godot_multi_env.py`: Multi-agent environment wrapper for Godot communication
- `game/scripts/core/Game.gd`: Main game controller with reward calculation and episode management
- `game/scripts/units/RTSUnit.gd`: Base unit class with combat, movement, and tracking
- `game/scripts/buildings/Base.gd`: Team base with health system and damage tracking
- `game/AiServer.gd`: Godot script handling TCP communication with training system

## Development Setup

### Prerequisites
- Godot 4.4.1+ (executable at `../Godot_v4.4.1-stable_win64_console.exe`)
- Python 3.10+ with virtual environment in `ai/.venv/`

### Running Training
1. Start Godot game instance:
   ```bash
   cd game
   "../Godot_v4.4.1-stable_win64_console.exe"
   ```
   Click "Play" to start the game scene.

2. Start training:
   ```bash
   cd ai
   .venv/Scripts/python.exe train_rllib_ppo_simple.py
   ```

### Development Commands
- **Install dependencies**: `cd ai && .venv/Scripts/pip install -r requirements.txt`
- **Run training with timeout**: `cd ai && timeout 60 .venv/Scripts/python.exe train_rllib_ppo_simple.py`
- **Check Godot connection**: Verify console shows "AiServer listening on 127.0.0.1:5555"

## Current Configuration

### Single-Worker Setup
- **Workers**: 1 Ray environment runner for stability
- **Connection**: Single Godot instance on port 5555
- **Agents**: Multiple RTS units across multiple trainable policies
- **Batch Size**: 2000 timesteps per training iteration
- **Architecture**: Stable single-instance configuration prioritizing reliability over speed

### Training Parameters
- **Algorithm**: PPO with new Ray RLlib API stack
- **Observation Space**: 94-dimensional vector (velocity, HP, battle stats, nearby units, 2 POIs)
  - Base (3): vel_x, vel_y, hp_ratio
  - Battle stats (5): attack_range, attack_damage, attack_cooldown, cooldown_remaining, speed
  - Closest allies (40): 10 × (direction_x, direction_y, distance, hp_ratio)
  - Closest enemies (40): 10 × (direction_x, direction_y, distance, hp_ratio)
  - Points of interest (6): 2 POIs × (direction_x, direction_y, distance) - enemy base and own base
- **Action Space**: Box(2) - Continuous 2D movement vectors [dx, dy] in range [-1, 1]
- **Network**: 3-layer MLP [128, 256, 128] with tanh activation
- **Episode Length**: 500 AI steps max (configurable in `Game.gd`)

### Game Configuration
- **Map Size**: 2560×1440 pixels (configurable in `Game.gd`)
- **Unit Types**: Infantry (balanced), Sniper (long-range)
- **Bases**: Randomly placed within team halves each episode
- **Victory Conditions**: Destroy enemy base or eliminate all enemy units

### Reward Configuration

All rewards and penalties are configurable in `game/scripts/core/Game.gd` (lines 46-70):

**Combat Rewards:**
- Damage to units: +0.1 per damage point
- Damage to base: +0.5 per damage point
- Unit kill: +15.0
- Base kill: +200.0
- Damage received: -0.1 per damage point
- Death: -5.0

**Team Outcome:**
- Team victory: +50.0
- Team defeat: -25.0

**Positional:**
- Proximity to enemy base: 0.0 to +0.5 (multiplier: 1.5)

**Movement Efficiency:**
- Continue straight (0°): +0.1
- Reverse direction (180°): -0.2
- Scales linearly with angle

**Base Defense:**
- Base damage penalty: -0.05 per damage point to your team's base (shared by all units)

**Survival:**
- Alive per step: +0.01

To tune AI behavior, adjust these variables in `Game.gd` and restart training.

## Troubleshooting

### Common Issues
1. **"Not connected to Godot"**: Ensure Godot instance is running and shows "AiServer listening"
2. **Connection timeout**: Verify port 5555 is not blocked and Godot scene is active
3. **Training crashes**: Check Godot console for errors, restart both components if needed

### Development Notes
- Use headed Godot instances (console version) for stability over headless mode
- Training checkpoints saved to `ai/checkpoints/` directory
- Ray logs available for debugging connection and training issues

## Features

### Implemented
✅ Multi-policy training system with dynamic assignment
✅ Configurable reward shaping for behavior tuning
✅ Continuous 2D action space for smooth movement control
✅ Movement efficiency rewards (direction consistency)
✅ Base defense penalties (team-wide)
✅ Random base placement per episode
✅ Multiple unit types (Infantry, Sniper)
✅ Team-based combat with victory conditions
✅ Spawn side alternation for robust learning

**Recent Changes:**
- **Continuous Action Space**: Changed from Discrete(9) to Box(2) for smoother, more precise movement
  - Benefits: Eliminates discrete jittering, enables nuanced positioning, natural for 2D environments
  - Action format: [dx, dy] vectors in range [-1, 1] sent to Godot, which handles target calculation
  - Direction change penalties now reward truly smooth trajectories instead of discrete angle changes
- **Velocity-Based Observations**: Replaced absolute position with velocity in observation space
  - Benefits: Position-invariant learning (fixes "always go left" problem), enables direction consistency learning
  - AI can now see and learn from its own movement direction
  - Velocity reflects actual achieved movement after collisions (from Godot's move_and_slide)
  - Observation space changed from 92 to 94 dimensions (removed dist_to_center, added 2nd POI)

### Potential Improvements
- **CSV reward tracking per policy**
  - Track detailed reward/penalty breakdown for each AI step
  - CSV format: columns = reward types, rows = AI steps
  - Separate CSV file per policy for comparison
  - Columns: damage_to_unit, damage_to_base, unit_kills, base_kills, damage_received, death_penalty, team_outcome, positional, survival, movement_efficiency, base_damage_penalty, total
  - Benefit: Analyze reward distributions, identify dominant components, tune reward balance
  - Implementation: Add FileAccess in `Game.gd`, write per-step breakdown during reward calculation
- Multi-worker configuration for faster training (requires reliable port assignment)
- Curriculum learning with progressive difficulty
- Hierarchical policies with squad-based coordination
- Additional unit types and abilities

### Scaling Considerations
- Current single-worker setup prioritizes stability
- Multi-worker scaling requires solving dynamic port assignment challenges
- GPU acceleration available via `num_gpus` parameter in training config

---

## Multi-Policy System Design (Planned)

### Protocol: Separate Unit ID from Policy Assignment

**Key Principle**: Unit IDs remain stable identifiers (`u1`-`u100`), while policy assignments are dynamic metadata sent in observations.

### Observation Protocol
Godot sends `policy_id` field in unit observations:
```gdscript
{
  "ai_step": 42,
  "units": [
    {
      "id": "u1",
      "policy_id": "aggressive_sniper",  // Dynamic policy assignment
      "hp": 100,
      "pos": [300, 200],
      // ... other fields
    }
  ]
}
```

### Python Side
- Track `agent_to_policy` mapping in `godot_multi_env.py`
- Policy mapping function uses dynamic lookups from observations
- Support runtime policy changes mid-game

### Implementation Files
- **Godot**: `game/scripts/units/RTSUnit.gd` - add `policy_id: String` field
- **Godot**: `game/scripts/core/Game.gd:173-188` - include `policy_id` in observations
- **Python**: `ai/godot_multi_env.py` - track `self.agent_to_policy` mapping
- **Python**: `ai/train_rllib_ppo_simple.py` - define multiple policies, dynamic `policy_mapping_fn()`

### Advantages
- ✅ Stable unit IDs throughout lifetime
- ✅ Per-unit policy granularity (e.g., "5 selected snipers" can use different policies)
- ✅ Runtime policy switching via Godot UI
- ✅ Explicit communication from Godot to Python
- ✅ Backward compatible with existing code

### Current Implementation Status
**✅ Implemented** - Multi-policy system with dynamic assignment
- Multiple policies can be defined and trained simultaneously
- Unit IDs remain stable identifiers throughout lifetime
- **Dynamic policy switching**: Call `unit.set_policy("policy_name")` to change at runtime
- Configure trainable vs frozen policies in `train_rllib_ppo_simple.py`
- Policy assignment defaults to team-based (allies vs enemies use different policies)

### How It Works
1. **Godot** sends `policy_id` field in each unit's observation
2. **Python** `policy_mapping_fn` reads `policy_id` from episode info
3. **Fallback** to unit ID-based assignment if episode data unavailable
4. **Runtime switching**: Change unit policy via `set_policy()` method, takes effect next step

### Example: Changing Policies at Runtime
```gdscript
# In Godot - change selected units to aggressive policy
for unit in get_selected_units():
    unit.set_policy("policy_aggressive")

# Next AI step will use the new policy for these units
```