# Reward Tracking Dashboard - TensorBoard Implementation Plan

## Overview
Implement live reward tracking using TensorBoard (already integrated with Ray RLlib) to visualize reward component distributions during training.

## Goals
1. Track individual reward components per policy per step
2. Visualize reward distributions in real-time
3. Compare reward balance across policies
4. Identify dominant reward components
5. Monitor training progress beyond just total reward

## Tech Stack
- **TensorBoard**: Built-in with Ray RLlib (no additional installation)
- **Ray RLlib Callbacks**: Custom callback to log reward breakdowns
- **Python logging**: Structured reward data extraction

## Implementation Steps

### Step 1: Create Custom Callback (30 minutes)

**File**: `ai/reward_tracking_callback.py` (new file)

```python
from ray.rllib.algorithms.callbacks import DefaultCallbacks
from ray.rllib.env import BaseEnv
from ray.rllib.evaluation import Episode, RolloutWorker
from typing import Dict

class RewardTrackingCallback(DefaultCallbacks):
    """
    Custom callback to track and log detailed reward breakdowns to TensorBoard.

    Extracts per-agent reward components from episode info and logs them
    as separate scalars for visualization and analysis.
    """

    def on_episode_step(
        self,
        *,
        worker: RolloutWorker,
        base_env: BaseEnv,
        policies: Dict[str, any],
        episode: Episode,
        **kwargs
    ) -> None:
        """
        Called on each environment step after rewards are collected.

        We'll extract reward component data from the info dict that Godot
        sends via godot_multi_env.py.
        """
        # Get the last info for all agents
        # Info structure from godot_multi_env.py includes policy_id, hp, velocity, etc.

        # We need to modify godot_multi_env.py to also pass reward breakdowns in info
        # For now, we can track aggregate metrics per episode
        pass

    def on_episode_end(
        self,
        *,
        worker: RolloutWorker,
        base_env: BaseEnv,
        policies: Dict[str, any],
        episode: Episode,
        **kwargs
    ) -> None:
        """
        Called when an episode ends.

        Log aggregated reward statistics per policy.
        """
        # Example: Log mean reward per policy
        # episode.custom_metrics["policy_LT50/mean_reward"] = ...
        # episode.custom_metrics["policy_GT50/mean_reward"] = ...
        pass
```

**What to implement**:
- Extract reward components from episode data
- Calculate per-policy aggregates
- Log to `episode.custom_metrics` (auto-logged to TensorBoard)

### Step 2: Modify Godot to Send Reward Breakdowns (45 minutes)

**File**: `game/scripts/core/Game.gd`

**Current reward calculation** (lines 287-335):
```gdscript
var reward: float = 0.0

# Combat-based rewards
reward += u.damage_dealt_this_step * reward_damage_to_unit
reward += u.damage_to_base_this_step * reward_damage_to_base
# ... etc

rewards[u.unit_id] = reward  # Currently just sends total
```

**Modify to send breakdown**:
```gdscript
# Instead of just total reward, send breakdown dictionary
var reward_breakdown = {
    "total": reward,
    "combat": {
        "damage_to_unit": u.damage_dealt_this_step * reward_damage_to_unit,
        "damage_to_base": u.damage_to_base_this_step * reward_damage_to_base,
        "unit_kills": u.kills_this_step * reward_unit_kill,
        "base_kills": u.base_kills_this_step * reward_base_kill,
        "damage_received": -u.damage_received_this_step * penalty_damage_received,
        "death": -penalty_death if u.died_this_step else 0.0
    },
    "objectives": {
        "team_outcome": team_outcome_reward,  # calculated based on game_won/lost
        "positional": position_reward,
        "survival": reward_alive_per_step if not u.died_this_step else 0.0
    },
    "movement": {
        "direction_efficiency": u.direction_change_reward,
        "base_damage_penalty": -base_damage_penalty
    }
}

# Send to Python (modify AiServer protocol)
rewards[u.unit_id] = reward_breakdown
```

**Changes needed**:
1. Restructure reward data as nested dictionary
2. Ensure JSON serialization works (already handled by AiServer)

### Step 3: Modify Python Environment to Store Breakdowns (30 minutes)

**File**: `ai/godot_multi_env.py`

**Modify `step()` method** (around line 447):
```python
# Current code extracts just total reward:
reward = float(agent_rewards.get(agent_id, 0.0))
rewards[agent_id] = reward

# New code stores breakdown in info:
reward_data = agent_rewards.get(agent_id, 0.0)

if isinstance(reward_data, dict):
    # Breakdown received from Godot
    rewards[agent_id] = reward_data.get("total", 0.0)
    infos[agent_id]["reward_breakdown"] = reward_data
else:
    # Fallback for old format (just total)
    rewards[agent_id] = float(reward_data)
    infos[agent_id]["reward_breakdown"] = {"total": float(reward_data)}
```

**What this enables**:
- Reward breakdown available in `infos` dict
- Callback can access and log individual components
- Backward compatible with simple float rewards

### Step 4: Implement Callback Logging Logic (45 minutes)

**File**: `ai/reward_tracking_callback.py`

```python
from ray.rllib.algorithms.callbacks import DefaultCallbacks
from ray.rllib.env import BaseEnv
from ray.rllib.evaluation import Episode, RolloutWorker
from typing import Dict
import numpy as np

class RewardTrackingCallback(DefaultCallbacks):

    def __init__(self):
        super().__init__()
        # Track cumulative rewards per policy per episode
        self.episode_rewards = {}

    def on_episode_start(self, *, worker, base_env, policies, episode, **kwargs):
        """Reset tracking at episode start"""
        episode.user_data["reward_components"] = {
            "policy_LT50": [],
            "policy_GT50": [],
            "policy_frontline": []
        }

    def on_episode_step(self, *, worker, base_env, policies, episode, **kwargs):
        """Collect reward breakdowns each step"""
        # Get infos from last step
        infos = episode.last_info_for()

        for agent_id, info in infos.items():
            if "reward_breakdown" in info and "policy_id" in info:
                policy_id = info["policy_id"]
                breakdown = info["reward_breakdown"]

                # Store for aggregation at episode end
                episode.user_data["reward_components"][policy_id].append(breakdown)

    def on_episode_end(self, *, worker, base_env, policies, episode, **kwargs):
        """Aggregate and log metrics at episode end"""

        for policy_id, breakdowns in episode.user_data["reward_components"].items():
            if len(breakdowns) == 0:
                continue

            # Aggregate all components
            totals = {
                "combat_damage_to_unit": [],
                "combat_damage_to_base": [],
                "combat_unit_kills": [],
                "combat_base_kills": [],
                "combat_damage_received": [],
                "combat_death": [],
                "objectives_team_outcome": [],
                "objectives_positional": [],
                "objectives_survival": [],
                "movement_direction_efficiency": [],
                "movement_base_damage_penalty": [],
                "total": []
            }

            # Extract values from each step
            for breakdown in breakdowns:
                if isinstance(breakdown, dict):
                    totals["total"].append(breakdown.get("total", 0.0))

                    combat = breakdown.get("combat", {})
                    totals["combat_damage_to_unit"].append(combat.get("damage_to_unit", 0.0))
                    totals["combat_damage_to_base"].append(combat.get("damage_to_base", 0.0))
                    totals["combat_unit_kills"].append(combat.get("unit_kills", 0.0))
                    totals["combat_base_kills"].append(combat.get("base_kills", 0.0))
                    totals["combat_damage_received"].append(combat.get("damage_received", 0.0))
                    totals["combat_death"].append(combat.get("death", 0.0))

                    objectives = breakdown.get("objectives", {})
                    totals["objectives_team_outcome"].append(objectives.get("team_outcome", 0.0))
                    totals["objectives_positional"].append(objectives.get("positional", 0.0))
                    totals["objectives_survival"].append(objectives.get("survival", 0.0))

                    movement = breakdown.get("movement", {})
                    totals["movement_direction_efficiency"].append(movement.get("direction_efficiency", 0.0))
                    totals["movement_base_damage_penalty"].append(movement.get("base_damage_penalty", 0.0))

            # Log statistics to TensorBoard
            for component, values in totals.items():
                if len(values) > 0:
                    episode.custom_metrics[f"{policy_id}/{component}/mean"] = np.mean(values)
                    episode.custom_metrics[f"{policy_id}/{component}/sum"] = np.sum(values)
                    episode.custom_metrics[f"{policy_id}/{component}/std"] = np.std(values)
                    episode.custom_metrics[f"{policy_id}/{component}/max"] = np.max(values)
                    episode.custom_metrics[f"{policy_id}/{component}/min"] = np.min(values)
```

### Step 5: Integrate Callback into Training Script (15 minutes)

**File**: `ai/training_server.py`

**Add import**:
```python
from reward_tracking_callback import RewardTrackingCallback
```

**Modify config** (around line 200):
```python
config = (
    PPOConfig()
    .environment(env=GodotRTSMultiAgentEnv, env_config=env_config)
    .api_stack(enable_rl_module_and_learner=True, enable_env_runner_and_connector_v2=True)
    .env_runners(num_env_runners=0)
    .callbacks(RewardTrackingCallback)  # Add this line
    # ... rest of config
)
```

### Step 6: Launch TensorBoard (5 minutes)

**Command**:
```bash
cd ai
tensorboard --logdir=~/ray_results --port=6006
```

**Or integrate into training script** (optional):
```python
import subprocess
import time

# Start TensorBoard in background
tensorboard_process = subprocess.Popen([
    "tensorboard",
    "--logdir", os.path.expanduser("~/ray_results"),
    "--port", "6006"
])

print("TensorBoard running at http://localhost:6006")

# Continue with training...
```

## Expected Output in TensorBoard

### Scalars Tab

**Per Policy Metrics** (organized by policy_id):
```
policy_LT50/
  ├── combat_damage_to_unit/mean
  ├── combat_damage_to_unit/sum
  ├── combat_damage_to_unit/std
  ├── combat_damage_to_base/mean
  ├── combat_unit_kills/mean
  ├── objectives_positional/mean
  ├── movement_direction_efficiency/mean
  ├── total/mean
  └── total/sum

policy_GT50/
  ├── (same structure)
  └── ...
```

### How to Use the Dashboard

1. **Compare Policies**: Select multiple policies in same chart to compare
2. **Identify Dominant Components**: Look at `/sum` metrics to see which rewards contribute most
3. **Monitor Balance**: Watch `/std` to see if rewards are consistent or spiky
4. **Track Learning**: `/mean` should show trends as AI learns

## Testing Plan

1. **Unit Test Callback** (10 min):
   - Create mock episode with reward_breakdown in info
   - Verify metrics are logged correctly

2. **Integration Test** (20 min):
   - Run 1 training episode
   - Check TensorBoard shows metrics
   - Verify all policies logged

3. **Full Run** (30 min):
   - Run 10-20 episodes
   - Verify charts update in real-time
   - Check data makes sense (no NaNs, reasonable ranges)

## Timeline

| Task | Estimated Time |
|------|----------------|
| Create callback structure | 30 min |
| Modify Godot reward sending | 45 min |
| Modify Python env to store breakdowns | 30 min |
| Implement callback logging logic | 45 min |
| Integrate into training script | 15 min |
| Launch and test TensorBoard | 20 min |
| **Total** | **3 hours** |

## Benefits

✅ **Zero additional dependencies** - TensorBoard already installed with Ray
✅ **Real-time feedback** - See reward distributions as training runs
✅ **Policy comparison** - Compare LT50 vs GT50 side-by-side
✅ **Component analysis** - Identify if combat/positional/movement rewards balanced
✅ **Debugging** - Catch reward bugs early (e.g., all zeros, unexpected spikes)

## Next Steps After Implementation

1. **Tune Rewards**: Use dashboard to identify dominant components and rebalance
2. **Monitor Training**: Watch for reward collapse or exploitation
3. **Compare Experiments**: TensorBoard can overlay multiple runs
4. **Export Data**: TensorBoard stores data in event files, can export to CSV if needed

## Alternative: Quick Start (No Godot Changes)

If you want to start even faster (1 hour implementation):

**Skip Godot changes**, instead calculate breakdowns in Python callback:
- Read unit combat stats from `infos`
- Reconstruct reward components using same formulas as Godot
- Less accurate (small floating point differences) but immediate

This gets you 80% of the value with 33% of the effort.
