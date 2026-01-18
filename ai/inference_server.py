# inference_server.py - Lean inference-only server for Godot RTS
#
# Loads trained model checkpoints and runs inference without any training.
# This eliminates the lag caused by training between episodes.
#
# Usage:
#   python inference_server.py                              # Uses production checkpoint
#   python inference_server.py --checkpoint production_v01  # Specific version
#   python inference_server.py --checkpoint checkpoint_050  # Training checkpoint

import argparse
import os
import sys
import numpy as np
import ray
from ray.rllib.algorithms.ppo import PPOConfig
from ray.rllib.policy.policy import PolicySpec

from godot_multi_env import GodotRTSMultiAgentEnv
from policy_manager import PolicyManager
from rts_config import (
    OBSERVATION_SPACE,
    ACTION_SPACE,
    DEFAULT_HOST,
    DEFAULT_PORT,
    DEFAULT_TIMEOUT,
    FCNET_WEIGHTS_INITIALIZER,
    FCNET_BIAS_INITIALIZER,
)


def find_checkpoint(checkpoint_name: str = None) -> str:
    """
    Find checkpoint to load.

    Args:
        checkpoint_name: Optional specific checkpoint name (e.g., "production_v01")
                        If None, uses the "production" checkpoint.

    Returns:
        Absolute path to checkpoint directory

    Raises:
        FileNotFoundError: If no checkpoint found
    """
    checkpoint_dir = os.path.abspath("./checkpoints")

    if checkpoint_name:
        # Use specific checkpoint
        checkpoint_path = os.path.join(checkpoint_dir, checkpoint_name)
        if os.path.exists(checkpoint_path):
            return checkpoint_path
        raise FileNotFoundError(f"Checkpoint not found: {checkpoint_path}")

    # Default: use production checkpoint
    production_path = os.path.join(checkpoint_dir, "production")
    if os.path.exists(production_path):
        return production_path

    # Fallback: find latest numbered checkpoint
    if not os.path.exists(checkpoint_dir):
        raise FileNotFoundError(f"Checkpoint directory not found: {checkpoint_dir}")

    checkpoints = [d for d in os.listdir(checkpoint_dir) if d.startswith("checkpoint_")]
    if not checkpoints:
        raise FileNotFoundError("No checkpoints found in checkpoints/")

    # Sort by creation time
    checkpoints.sort(key=lambda x: os.path.getctime(os.path.join(checkpoint_dir, x)))
    latest = os.path.join(checkpoint_dir, checkpoints[-1])
    print(f"Warning: No 'production' checkpoint found, falling back to {latest}")
    return latest


def build_policies(policy_manager: PolicyManager) -> dict:
    """Build policy specifications from JSON config."""
    policies = {}
    for policy_id in policy_manager.get_policy_ids():
        network_config = policy_manager.get_network_config(policy_id)
        model_config = {
            "fcnet_hiddens": network_config.get("fcnet_hiddens", [128, 256, 128]),
            "fcnet_activation": network_config.get("fcnet_activation", "tanh"),
            "fcnet_weights_initializer": FCNET_WEIGHTS_INITIALIZER,
            "fcnet_bias_initializer": FCNET_BIAS_INITIALIZER,
        }
        policies[policy_id] = PolicySpec(
            policy_class=None,
            observation_space=OBSERVATION_SPACE,
            action_space=ACTION_SPACE,
            config={"model": model_config}
        )
    return policies


def create_policy_mapping_fn(policy_manager: PolicyManager, policies: dict):
    """Create a simple policy mapping function for inference."""

    def policy_mapping_fn(agent_id, episode=None, worker=None, **kwargs):
        """Map agent to policy based on Godot's assignment."""
        # Try global mapping first (updated by environment)
        try:
            agent_to_policy = GodotRTSMultiAgentEnv._agent_to_policy_global
            if agent_id in agent_to_policy:
                policy_id = agent_to_policy[agent_id]
                if policy_id in policies:
                    return policy_id
        except (AttributeError, KeyError):
            pass

        # Fallback to default
        return policy_manager.default_policy

    return policy_mapping_fn


def run_inference_loop(algo, env, policy_manager):
    """
    Run continuous inference loop without training.

    This is the lean alternative to algo.train() - it just:
    1. Gets observations from Godot
    2. Computes actions using loaded policies
    3. Sends actions back
    4. Handles episode resets immediately (no training delay)
    """
    import torch

    print("\n" + "=" * 50)
    print("Starting inference loop (no training)")
    print("Press Ctrl+C to stop")
    print("=" * 50 + "\n")

    # Get the RLModule for computing actions (new API)
    # The learner group contains trained modules for each policy
    rl_modules = {}
    try:
        # Access modules from the learner group
        learner_group = algo.learner_group
        if hasattr(learner_group, '_learner'):
            learner = learner_group._learner
            if hasattr(learner, 'module'):
                # Multi-agent module contains sub-modules per policy
                marl_module = learner.module
                for policy_id in policy_manager.get_policy_ids():
                    if hasattr(marl_module, policy_id):
                        rl_modules[policy_id] = getattr(marl_module, policy_id)
                    elif hasattr(marl_module, '_rl_modules') and policy_id in marl_module._rl_modules:
                        rl_modules[policy_id] = marl_module._rl_modules[policy_id]
        print(f"Loaded {len(rl_modules)} policy modules for inference")
    except Exception as e:
        print(f"Warning: Could not access RLModules directly: {e}")
        print("Falling back to algorithm's compute methods")

    episode_count = 0
    step_count = 0

    # Initial reset
    obs, info = env.reset()
    print(f"Episode {episode_count + 1} started with {len(obs)} agents")

    while True:
        # Compute actions for all agents
        actions = {}
        for agent_id, agent_obs in obs.items():
            # Get policy for this agent
            policy_id = env.agent_to_policy.get(agent_id, policy_manager.default_policy)

            # Convert observation to tensor
            obs_tensor = torch.tensor(agent_obs, dtype=torch.float32).unsqueeze(0)

            # Compute action using the RLModule
            if policy_id in rl_modules:
                module = rl_modules[policy_id]
                with torch.no_grad():
                    # Forward pass through the module
                    input_dict = {"obs": obs_tensor}
                    output = module.forward_inference(input_dict)
                    # Extract action from output (deterministic = use mean)
                    if "action_dist_inputs" in output:
                        # For continuous actions, first half is mean, second half is log_std
                        action_dist_inputs = output["action_dist_inputs"]
                        action = action_dist_inputs[0, :2].numpy()  # Take mean (first 2 values)
                    elif "actions" in output:
                        action = output["actions"][0].numpy()
                    else:
                        # Fallback: sample from distribution
                        action = np.zeros(2, dtype=np.float32)
            else:
                # Fallback: random action
                action = np.zeros(2, dtype=np.float32)

            actions[agent_id] = action

        # Step environment
        obs, rewards, terminateds, truncateds, infos = env.step(actions)
        step_count += 1

        # Check for episode end
        if terminateds.get("__all__", False) or truncateds.get("__all__", False):
            episode_count += 1

            # Determine reset type
            if env._soft_reset_pending:
                print(f"Episode {episode_count} ended (soft reset - policy change)")
            else:
                total_reward = sum(rewards.values()) if rewards else 0
                print(f"Episode {episode_count} ended after {step_count} steps, total reward: {total_reward:.1f}")

            step_count = 0

            # Reset immediately (no training delay!)
            obs, info = env.reset()
            print(f"Episode {episode_count + 1} started with {len(obs)} agents")


def detect_gpu_available() -> bool:
    """Check if CUDA GPU is available for PyTorch."""
    try:
        import torch
        return torch.cuda.is_available()
    except ImportError:
        return False


def main():
    # Parse command line args
    parser = argparse.ArgumentParser(
        description="Inference-only server for Godot RTS AI"
    )
    parser.add_argument(
        "--checkpoint", "-c",
        type=str,
        default=None,
        help="Checkpoint name to load (e.g., checkpoint_050). Uses latest if not specified."
    )
    parser.add_argument(
        "--gpu",
        action="store_true",
        help="Force GPU inference"
    )
    parser.add_argument(
        "--cpu",
        action="store_true",
        help="Force CPU inference"
    )
    args = parser.parse_args()

    # Determine GPU usage: explicit flag > auto-detect
    if args.cpu and args.gpu:
        print("Error: Cannot specify both --cpu and --gpu")
        sys.exit(1)

    if args.cpu:
        use_gpu = False
        print("Forcing CPU inference (--cpu flag)")
    elif args.gpu:
        use_gpu = True
        print("Forcing GPU inference (--gpu flag)")
    else:
        # Auto-detect: try GPU first, fallback to CPU
        use_gpu = detect_gpu_available()
        if use_gpu:
            print("GPU detected, using GPU inference")
        else:
            print("No GPU available, using CPU inference")

    # Find checkpoint
    try:
        checkpoint_path = find_checkpoint(args.checkpoint)
        print(f"Using checkpoint: {checkpoint_path}")
    except FileNotFoundError as e:
        print(f"Error: {e}")
        sys.exit(1)

    # Load policy configuration
    policy_manager = PolicyManager()
    print(f"\nLoaded {len(policy_manager.get_policy_ids())} policies from config")

    # Build policies
    policies = build_policies(policy_manager)
    policy_mapping_fn = create_policy_mapping_fn(policy_manager, policies)

    # Initialize Ray with minimal resources
    ray.shutdown()
    ray.init(
        include_dashboard=False,
        num_cpus=2,  # Minimal CPU allocation for inference
        log_to_driver=False,  # Reduce log noise
    )

    # Build minimal PPO config for inference only
    cfg = (
        PPOConfig()
        .api_stack(
            enable_rl_module_and_learner=True,
            enable_env_runner_and_connector_v2=True
        )
        .framework("torch")
        .environment(
            env=GodotRTSMultiAgentEnv,
            env_config={
                "host": DEFAULT_HOST,
                "port": DEFAULT_PORT,
                "timeout": DEFAULT_TIMEOUT,
            },
            disable_env_checking=True,
        )
        .env_runners(
            num_env_runners=0,  # Local only
            num_envs_per_env_runner=1,
        )
        .multi_agent(
            policies=policies,
            policy_mapping_fn=policy_mapping_fn,
            policies_to_train=[],  # No training!
        )
        .resources(
            num_gpus=1 if use_gpu else 0,
            num_cpus_for_main_process=2,
        )
        .evaluation(
            evaluation_interval=None,  # No automatic evaluation
        )
    )

    print("\nBuilding algorithm...")
    algo = cfg.build()

    # Restore checkpoint
    print(f"Restoring from: {checkpoint_path}")
    try:
        algo.restore(checkpoint_path)
        print("Checkpoint restored successfully!")
    except Exception as e:
        print(f"Error restoring checkpoint: {e}")
        ray.shutdown()
        sys.exit(1)

    # Create environment for direct interaction
    env = GodotRTSMultiAgentEnv({
        "host": DEFAULT_HOST,
        "port": DEFAULT_PORT,
        "timeout": DEFAULT_TIMEOUT,
        "inference_mode": True,  # Suppress debug reward logs
    })

    try:
        run_inference_loop(algo, env, policy_manager)
    except KeyboardInterrupt:
        print("\n\nInference stopped by user")
    except Exception as e:
        print(f"\nError during inference: {e}")
        import traceback
        traceback.print_exc()
    finally:
        print("\nCleaning up...")
        env.close()
        algo.stop()
        ray.shutdown()
        print("Done.")


if __name__ == "__main__":
    main()
