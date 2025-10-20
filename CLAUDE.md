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
- **Observation Space**: 92-dimensional vector (position, HP, battle stats, nearby units, POIs)
- **Action Space**: Discrete(9) - 8 directional movements + stay
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
✅ Movement efficiency rewards (direction consistency)
✅ Base defense penalties (team-wide)
✅ Random base placement per episode
✅ Multiple unit types (Infantry, Sniper)
✅ Team-based combat with victory conditions
✅ Spawn side alternation for robust learning

### Potential Improvements
- **Replace absolute position with velocity in observations** ⚠️ IMPORTANT
  - Current: Observations include absolute (x, y) position which leaks map side
  - Problem: AI learns position-specific strategies ("go left" instead of "go to enemy")
  - Solution: Replace with velocity (actual achieved movement, collision-aware)
  - Benefit: Position-invariant learning, better generalization
  - Implementation: `game/scripts/core/Game.gd:441` change `"pos"` to `"velocity"`
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