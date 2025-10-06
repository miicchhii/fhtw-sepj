#!/usr/bin/env python3
"""Test if checkpoint_3policy can be restored properly"""

import gymnasium as gym
import numpy as np
from ray.rllib.algorithms.ppo import PPOConfig
import os

# Match the main training script configuration
OBS_SPACE = gym.spaces.Box(low=-1.0, high=1.0, shape=(4,), dtype=np.float32)
ACT_SPACE = gym.spaces.Discrete(9)

POLICIES = {
    "policy_LT50": (None, OBS_SPACE, ACT_SPACE, {}),
    "policy_GT50": (None, OBS_SPACE, ACT_SPACE, {}),
    "policy_frontline": (None, OBS_SPACE, ACT_SPACE, {}),
}

def policy_mapping_fn(agent_id, episode=None, worker=None, **kwargs):
    if agent_id.startswith("u"):
        unit_num = int(agent_id[1:])
        if unit_num < 50:
            return "policy_LT50"
        elif unit_num < 76:
            return "policy_GT50"
        else:
            return "policy_frontline"
    return "policy_LT50"

print("Testing checkpoint restore...")
print("="*60)

# Build config matching train script
cfg = (
    PPOConfig()
    .api_stack(
        enable_rl_module_and_learner=True,
        enable_env_runner_and_connector_v2=True
    )
    .framework("torch")
    .environment(
        disable_env_checking=True,
    )
    .multi_agent(
        policies={"policy_LT50", "policy_GT50", "policy_frontline"},
        policy_mapping_fn=policy_mapping_fn,
        policies_to_train=["policy_LT50", "policy_frontline"],
        count_steps_by="agent_steps",
    )
    .rl_module(
        model_config={
            "fcnet_hiddens": [64, 64, 64],
            "fcnet_activation": "tanh",
            "fcnet_weights_initializer": "xavier_uniform_",
            "fcnet_bias_initializer": "zeros_",
        }
    )
)

checkpoint_path = "checkpoints/checkpoint_3policy"

print(f"Building algorithm...")
algo = cfg.build()
print(f"Algorithm built successfully\n")

print(f"Attempting to restore from: {checkpoint_path}")
try:
    algo.restore(checkpoint_path)
    print("✓ Checkpoint restored successfully!")

    # Try to get weights to verify they loaded
    print("\nChecking if weights were loaded...")
    workers = algo.env_runner_group
    if workers:
        print(f"  Found env_runner_group")

    # Check learner weights
    learner_group = algo.learner_group
    if learner_group:
        print(f"  Found learner_group")

    print("\n✓ Checkpoint appears valid!")

except Exception as e:
    print(f"✗ ERROR: Failed to restore checkpoint")
    print(f"  Error: {e}")
    import traceback
    traceback.print_exc()

finally:
    algo.stop()
    print("\nTest complete.")
