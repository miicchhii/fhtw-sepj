# Claude Code Configuration

This file contains configuration and instructions for Claude Code to help with development of this multi-agent RTS training project.

## Project Overview

This project implements a multi-agent reinforcement learning system where AI agents learn to control RTS (Real-Time Strategy) units in a Godot game environment. The system uses Ray RLlib with PPO (Proximal Policy Optimization) to train 20 individual agents that share a single policy.

## Architecture

### Components
- **Godot Game** (`game/`): RTS game built in Godot 4.x that hosts 20 controllable units
- **AI Training** (`ai/`): Python-based training system using Ray RLlib
- **Communication**: TCP socket connection between Godot and Python training

### Key Files
- `ai/train_rllib_ppo_simple.py`: Main training script with PPO configuration
- `ai/godot_multi_env.py`: Multi-agent environment wrapper for Godot communication
- `game/AiServer.gd`: Godot script handling TCP communication with training system
- `game/world.tscn`: Main game scene with RTS units and environment

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
- **Agents**: 20 RTS units sharing one "infantry" policy
- **Batch Size**: 400 timesteps per training iteration
- **Architecture**: Stable single-instance configuration prioritizing reliability over speed

### Training Parameters
- **Algorithm**: PPO with new Ray RLlib API stack
- **Observation Space**: Box(-1.0, 1.0, (4,)) - normalized position, health, distance
- **Action Space**: Discrete(9) - 8 directional movements + stay
- **Network**: 3-layer MLP with 64 hidden units, tanh activation

## Troubleshooting

### Common Issues
1. **"Not connected to Godot"**: Ensure Godot instance is running and shows "AiServer listening"
2. **Connection timeout**: Verify port 5555 is not blocked and Godot scene is active
3. **Training crashes**: Check Godot console for errors, restart both components if needed

### Development Notes
- Use headed Godot instances (console version) for stability over headless mode
- Training checkpoints saved to `ai/checkpoints/` directory
- Ray logs available for debugging connection and training issues

## Future Enhancements

### Potential Improvements
- Multi-worker configuration for faster training (requires reliable port assignment)
- Advanced reward shaping for more complex RTS behaviors
- Hierarchical policies for different unit types
- Integration with more sophisticated RTS mechanics

### Scaling Considerations
- Current single-worker setup prioritizes stability
- Multi-worker scaling requires solving dynamic port assignment challenges
- Performance can be improved with GPU acceleration when available

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
**Phase 2**: ✅ Completed - 3 policies with dynamic assignment
- `policy_LT50`: Trainable policy (u1-u49, 49 units)
- `policy_GT50`: Frozen policy for evaluation (u50-u75, 26 units)
- `policy_frontline`: Trainable frontline policy (u76-u100, 25 units) - copied from LT50
- Unit IDs remain `u1`-`u100` (stable identifiers)
- **Dynamic policy switching**: Call `unit.set_policy("policy_name")` to change at runtime
- **Checkpoint**: `checkpoint_3policy` contains all 3 policies migrated from `checkpoint_final`

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