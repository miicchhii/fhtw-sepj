# fhtw-sepj
Software Engineering Project

A multi-agent reinforcement learning RTS game built with Godot 4 and Python (Ray RLlib).

---

## Deployment & Usage Guide

### Prerequisites

- **Godot 4.4.1+** - Download from [godotengine.org](https://godotengine.org/)
- **Python 3.10+** - With pip for package management

### Setup

1. **Clone the repository**
   ```bash
   git clone https://github.com/miicchhii/fhtw-sepj.git
   cd fhtw-sepj
   ```

2. **Install Python dependencies**
   ```bash
   cd ai
   python -m venv .venv
   .venv/Scripts/activate  # Windows
   # source .venv/bin/activate  # Linux/Mac
   pip install -r requirements.txt
   ```

3. **Open the Godot project**
   - Launch Godot
   - Click "Import" and select `game/project.godot`

---

### Running the Game (Manual Play)

1. Open the project in Godot
2. Press F5 or click "Play"
3. Use the Construction Shop UI to spawn units
4. Right-click to move selected units

---

### Running Inference Mode (AI Playing)

Inference mode lets trained AI models control the units.

1. **Start Godot**
   - Open project and press Play
   - The game will wait for the inference server connection

2. **Start the Inference Server**
   ```bash
   cd ai
   .venv/Scripts/python inference_server.py
   ```

   Optional flags:
   - `--checkpoint PATH` - Load specific checkpoint (default: `checkpoints/production`)
   - `-v` / `--verbose` - Enable debug output
   - `-q` / `--quiet` - Suppress most output

The AI will control enemy units using the trained policies.

---

### Running Training

Training uses PPO (Proximal Policy Optimization) via Ray RLlib.

1. **Start Godot**
   - Open project and press Play
   - Console should show: `AiServer listening on 127.0.0.1:5555`

2. **Start Training**
   ```bash
   cd ai
   .venv/Scripts/python training_server.py
   ```

   Optional flags:
   - `--checkpoint PATH` - Resume from checkpoint
   - `-v` / `--verbose` - Enable debug output
   - `-q` / `--quiet` - Suppress most output

3. **Monitor Training**
   - Checkpoints saved to `ai/checkpoints/checkpoint_XXX/`
   - Episode statistics logged to `ai/logs/episode_stats_*.csv`
   - Training metrics printed to console

4. **Stop Training**
   - Press `Ctrl+C` to gracefully stop
   - An interrupted checkpoint will be saved

---

### Model Locations

| Path | Description |
|------|-------------|
| `ai/checkpoints/production/` | Current production model (used by inference) |
| `ai/checkpoints/checkpoint_XXX/` | Training checkpoints (numbered) |
| `ai/checkpoints/checkpoint_final/` | Final checkpoint after clean training stop |
| `ai/checkpoints/checkpoint_interrupted/` | Auto-saved on Ctrl+C |

**Update production model:**
```bash
cd ai
.venv/Scripts/python update_production_checkpoint.py checkpoints/checkpoint_XXX
```

---

### Configuration Files

| File | Purpose |
|------|---------|
| `ai/rts_config.py` | Training hyperparameters (learning rate, batch size, etc.) |
| `game/config/ai_policies.json` | Policy definitions and team assignments |
| `game/scripts/core/Game.gd` | Reward shaping parameters (lines 46-74) |
| `game/scripts/core/GameConfig.gd` | Map dimensions, episode length |

---

### Project Structure

```
fhtw-sepj/
├── ai/                     # Python AI/ML code
│   ├── training_server.py  # Main training script
│   ├── inference_server.py # Run trained models
│   ├── godot_multi_env.py  # Godot environment wrapper
│   ├── rts_config.py       # Training configuration
│   └── checkpoints/        # Saved models
├── game/                   # Godot game project
│   ├── scripts/
│   │   ├── core/           # Game logic (Game.gd, EnemyMetaAI.gd)
│   │   ├── units/          # Unit classes (RTSUnit.gd, Infantry.gd, etc.)
│   │   ├── buildings/      # Base, shops, resource generators
│   │   └── ui/             # HUD and shop interface
│   ├── scenes/             # Godot scene files
│   └── config/             # JSON configuration
└── README.md
```
