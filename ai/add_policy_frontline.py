#!/usr/bin/env python3
"""
Add policy_frontline to existing 2-policy checkpoint by copying policy_LT50 weights.
This creates a 3-policy checkpoint: LT50 (trainable), GT50 (frozen), frontline (trainable).
"""

import os
import shutil
import pickle
from pathlib import Path

def add_frontline_policy(source_checkpoint: str, target_checkpoint: str):
    """
    Add policy_frontline to a checkpoint by copying policy_LT50.

    Args:
        source_checkpoint: Path to source checkpoint (e.g., "checkpoints/checkpoint_final")
        target_checkpoint: Path to target checkpoint (e.g., "checkpoints/checkpoint_3policy")
    """
    source_path = Path(source_checkpoint)
    target_path = Path(target_checkpoint)

    if not source_path.exists():
        raise FileNotFoundError(f"Source checkpoint not found: {source_path}")

    if target_path.exists():
        print(f"Warning: Target checkpoint already exists: {target_path}")
        response = input("Overwrite? (y/n): ")
        if response.lower() != 'y':
            print("Migration cancelled.")
            return
        shutil.rmtree(target_path)

    print(f"Adding policy_frontline to checkpoint...")
    print(f"Source: {source_path}")
    print(f"Target: {target_path}")

    # Step 1: Copy entire checkpoint structure
    print("\nStep 1: Copying checkpoint structure...")
    shutil.copytree(source_path, target_path)
    print(f"  [OK] Copied to {target_path}")

    # Step 2: Copy policy_LT50 to policy_frontline
    rl_module_path = target_path / "learner_group" / "learner" / "rl_module"
    policy_lt50_path = rl_module_path / "policy_LT50"
    policy_frontline_path = rl_module_path / "policy_frontline"

    if not policy_lt50_path.exists():
        raise FileNotFoundError(f"policy_LT50 not found at {policy_lt50_path}")

    print("\nStep 2: Creating policy_frontline from policy_LT50...")
    shutil.copytree(policy_lt50_path, policy_frontline_path)
    print(f"  [OK] Created policy_frontline at {policy_frontline_path}")

    # Step 3: Update module_state.pkl to include all three policies
    print("\nStep 3: Updating module state...")
    module_state_path = rl_module_path / "module_state.pkl"

    if module_state_path.exists():
        with open(module_state_path, 'rb') as f:
            module_state = pickle.load(f)

        print(f"  Current module_state keys: {list(module_state.keys()) if isinstance(module_state, dict) else type(module_state)}")

        # If module_state is a dict with policy names, add frontline
        if isinstance(module_state, dict):
            if 'policy_LT50' in module_state:
                # Copy LT50's state to frontline
                module_state['policy_frontline'] = module_state['policy_LT50']
                print(f"  [OK] Added policy_frontline to module_state (copied from LT50)")

            with open(module_state_path, 'wb') as f:
                pickle.dump(module_state, f)
            print(f"  [OK] Saved updated module_state.pkl")
            print(f"  Final policies: {list(module_state.keys())}")

    # Step 4: Summary
    print(f"\n[SUCCESS] Migration complete!")
    print(f"New checkpoint saved to: {target_path}")
    print(f"\nCheckpoint now contains 3 policies:")
    print(f"  - policy_LT50: trainable (original)")
    print(f"  - policy_GT50: frozen (original)")
    print(f"  - policy_frontline: trainable (copied from LT50)")
    print(f"\nNext steps:")
    print(f"  1. Update train_rllib_ppo_simple.py to define all 3 policies")
    print(f"  2. Update Godot to assign policy_frontline to units u76-u100")
    print(f"  3. Set skip_checkpoint_loading = False in train script")

if __name__ == "__main__":
    # Paths
    source = "checkpoints/checkpoint_final"
    target = "checkpoints/checkpoint_3policy"

    print("="*60)
    print("Add policy_frontline to Checkpoint")
    print("="*60)
    print(f"Source: {source}")
    print(f"Target: {target}")
    print()

    add_frontline_policy(source, target)
