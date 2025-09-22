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