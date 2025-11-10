# train_rllib_ppo_simple.py - Multi-policy PPO training for Godot RTS units
#
# Loads policy configurations from JSON (single source of truth shared with Godot).
# Each policy can have:
# - Custom reward weights (handled by Godot RewardCalculator)
# - Custom neural network architecture
# - Trainable or frozen status
#
# The system supports dynamic policy assignment - units can switch policies at runtime
# via Godot's unit.set_policy() method.

import gymnasium as gym
import numpy as np
import ray
from ray.rllib.algorithms.ppo import PPOConfig
from ray.rllib.policy.policy import PolicySpec
from godot_multi_env import GodotRTSMultiAgentEnv
from policy_manager import PolicyManager
import os

# Import central configuration
from rts_config import (
    OBSERVATION_SPACE,
    ACTION_SPACE,
    LEARNING_RATE,
    ENTROPY_COEFF,
    GAMMA,
    CLIP_PARAM,
    TRAIN_BATCH_SIZE,
    MINIBATCH_SIZE,
    NUM_EPOCHS,
    USE_GAE,
    GAE_LAMBDA,
    VF_CLIP_PARAM,
    FCNET_WEIGHTS_INITIALIZER,
    FCNET_BIAS_INITIALIZER,
    DEFAULT_HOST,
    DEFAULT_PORT,
    DEFAULT_TIMEOUT
)

# Load policy configurations from JSON
policy_manager = PolicyManager()
policy_manager.print_summary()

# Observation and action spaces (shared across all policies)
OBS_SPACE = OBSERVATION_SPACE
ACT_SPACE = ACTION_SPACE

# Build policy configurations dynamically from JSON
POLICIES = {}
for policy_id in policy_manager.get_policy_ids():
    # Get network configuration for this policy
    network_config = policy_manager.get_network_config(policy_id)

    # Build model config with policy-specific network architecture
    model_config = {
        "fcnet_hiddens": network_config.get("fcnet_hiddens", [128, 256, 128]),
        "fcnet_activation": network_config.get("fcnet_activation", "tanh"),
        "fcnet_weights_initializer": FCNET_WEIGHTS_INITIALIZER,
        "fcnet_bias_initializer": FCNET_BIAS_INITIALIZER,
    }

    # Create PolicySpec with custom config
    POLICIES[policy_id] = PolicySpec(
        policy_class=None,  # Use default PPO policy
        observation_space=OBS_SPACE,
        action_space=ACT_SPACE,
        config={"model": model_config}
    )

print(f"\n=== Configured {len(POLICIES)} policies for training ===")
for policy_id in POLICIES.keys():
    net_config = policy_manager.get_network_config(policy_id)
    trainable = policy_manager.is_trainable(policy_id)
    print(f"  {policy_id}: {net_config.get('fcnet_hiddens')} [{'TRAIN' if trainable else 'FROZEN'}]")

def policy_mapping_fn(agent_id, episode=None, worker=None, **kwargs):
    """
    Map agents to policies dynamically based on policy_id from Godot observations.

    This function is called by RLlib to determine which policy controls each agent.
    It enables runtime policy switching - units can change policies mid-episode via
    Godot's unit.set_policy("policy_name") method.

    Priority:
    1. Try to read policy_id from episode info (dynamic assignment from Godot)
    2. Fall back to default_policy from JSON config

    Args:
        agent_id: Unit identifier (e.g., "u25", "u87")
        episode: Episode object containing agent info/observations (RLlib API)
        worker: Worker object (unused, for API compatibility)

    Returns:
        str: Policy ID from JSON config
    """
    # Try to get policy from episode info (sent from Godot via observations)
    if episode is not None:
        try:
            # Access the agent's last info dict which contains policy_id from Godot
            agent_infos = episode.get_agents_to_act()
            if agent_id in agent_infos:
                info = episode.last_info_for(agent_id)
                if info and "policy_id" in info:
                    policy_id = info["policy_id"]
                    # Validate policy exists
                    if policy_id in POLICIES:
                        return policy_id  # Dynamic policy assignment from Godot
        except (AttributeError, KeyError, TypeError):
            # Episode API might differ or info not available, fall through
            pass

    # Fallback to default policy from config
    return policy_manager.default_policy

if __name__ == "__main__":
    # Suppress deprecation warnings for cleaner output
    os.environ.setdefault("PYTHONWARNINGS", "ignore::DeprecationWarning")

    # Initialize Ray distributed computing framework
    # Single machine, 4 CPU cores allocated
    ray.shutdown()  # Idempotent - ensures clean start
    ray.init(include_dashboard=False, num_cpus=4)

    # Setup checkpoint directories (must use absolute paths for RLlib restore)
    checkpoint_dir = os.path.abspath("./checkpoints")
    model_dir = os.path.abspath("./models")
    os.makedirs(checkpoint_dir, exist_ok=True)
    os.makedirs(model_dir, exist_ok=True)

    # Auto-detect latest checkpoint for resume capability
    # Note: We explicitly load checkpoint_3policy below, but this finds numbered checkpoints
    latest_checkpoint = None
    next_iteration = 1  # Default iteration number if no checkpoints exist

    if os.path.exists(checkpoint_dir):
        checkpoints = [d for d in os.listdir(checkpoint_dir) if d.startswith("checkpoint_")]
        if checkpoints:
            # Sort by creation time and get the latest
            checkpoints.sort(key=lambda x: os.path.getctime(os.path.join(checkpoint_dir, x)))
            latest_checkpoint = os.path.join(checkpoint_dir, checkpoints[-1])
            print(f"Found latest checkpoint: {latest_checkpoint}")

            # Extract the highest iteration number from all checkpoints
            iteration_numbers = []
            for ckpt in checkpoints:
                try:
                    # Extract number from "checkpoint_XXX" format
                    if "_" in ckpt and not ckpt.endswith("_interrupted") and not ckpt.endswith("_final"):
                        num_str = ckpt.split("_")[-1]
                        iteration_numbers.append(int(num_str))
                except ValueError:
                    continue

            if iteration_numbers:
                next_iteration = max(iteration_numbers) + 1
                print(f"Resuming from iteration {next_iteration}")
            else:
                next_iteration = 1

    print("Observation space:", OBS_SPACE)
    print("Action space:", ACT_SPACE)

    # Configure which policies to train (loaded from JSON)
    # Frozen policies are used as baselines for comparison
    POLICIES_TO_TRAIN = policy_manager.get_trainable_policies()
    FROZEN_POLICIES = policy_manager.get_frozen_policies()
    print(f"\nTraining configuration:")
    print(f"  Trainable policies: {POLICIES_TO_TRAIN}")
    print(f"  Frozen policies: {FROZEN_POLICIES}\n")

    # PPO configuration for 3-policy multi-agent RTS training
    # Architecture: Single worker with 100 agents split across 3 policies
    cfg = (
        PPOConfig()
        .api_stack(
            enable_rl_module_and_learner=True,      # Use new RLlib API stack
            enable_env_runner_and_connector_v2=True  # Required for new API
        )
        .framework("torch")  # PyTorch backend for neural networks
        .environment(
            env=GodotRTSMultiAgentEnv,
            env_config={
                "host": DEFAULT_HOST,
                "port": DEFAULT_PORT,
                "timeout": DEFAULT_TIMEOUT,
            },
            disable_env_checking=True,  # Skip gym space validation (custom spaces)
        )
        .env_runners(
            num_env_runners=0,  # 0 = single-worker mode (local training)
            num_envs_per_env_runner=1,  # 1 Godot instance per worker
            batch_mode="complete_episodes",  # Collect full episodes before training
            rollout_fragment_length=100,  # Steps per rollout fragment
        )
        .training(
            gamma=GAMMA,
            lr=LEARNING_RATE,  # Reduced from 3e-4 to 1e-4 in central config
            train_batch_size=TRAIN_BATCH_SIZE,
            minibatch_size=MINIBATCH_SIZE,
            num_epochs=NUM_EPOCHS,
            clip_param=CLIP_PARAM,
            vf_clip_param=VF_CLIP_PARAM,
            use_gae=USE_GAE,
            lambda_=GAE_LAMBDA,
            entropy_coeff=ENTROPY_COEFF,
        )
        .multi_agent(
            policies=POLICIES,  # Loaded from JSON via PolicyManager
            policy_mapping_fn=policy_mapping_fn,
            # Use POLICIES_TO_TRAIN variable to control which policies are trained
            # Policies not in this list will be frozen (inference only, no gradient updates)
            policies_to_train=POLICIES_TO_TRAIN,
            count_steps_by="agent_steps",  # Count steps per agent (not env steps)
        )
        .resources(
            num_gpus=1,  # CPU-only training (set to 1 for GPU acceleration)
            num_cpus_for_main_process=4,  # Allocate 4 CPU cores for training
        )
        .reporting(
            metrics_num_episodes_for_smoothing=1,  # Report raw episode metrics (no smoothing)
            min_time_s_per_iteration=0,  # No minimum time between iterations
            min_sample_timesteps_per_iteration=100,  # Minimum 100 timesteps per iteration
        )
        .debugging(
            log_level="DEBUG",  # Verbose logging for troubleshooting
        )
    )

    print("\n" + "="*50)
    # Checkpoint loading configuration
    # Priority: latest numbered checkpoint > checkpoint_3policy > train from scratch
    skip_checkpoint_loading = False  # Set to True to train from scratch

    # Determine which checkpoint to load
    checkpoint_to_load = None
    if not skip_checkpoint_loading:
        if latest_checkpoint:
            checkpoint_to_load = latest_checkpoint
            print(f"Found latest checkpoint: {checkpoint_to_load}")
        else:
            checkpoint_3policy = os.path.abspath("./checkpoints/checkpoint_3policy")
            if os.path.exists(checkpoint_3policy):
                checkpoint_to_load = checkpoint_3policy
                print(f"No training checkpoints found, loading baseline: {checkpoint_3policy}")
            else:
                print("No checkpoints found, training from scratch")

    # Build algorithm
    print("Building algorithm...")
    algo = cfg.build()

    # Restore from checkpoint if available
    if checkpoint_to_load:
        print(f"Restoring from checkpoint: {checkpoint_to_load}")
        try:
            algo.restore(checkpoint_to_load)
            print("✓ Algorithm restored successfully!")
            print(f"  Loaded 3 policies: LT50, GT50, frontline")

            # Manually update all training hyperparameters post-restore
            # This allows tuning hyperparameters between runs without losing progress
            print(f"\n  Updating training hyperparameters from rts_config.py:")
            print(f"    Learning rate: {LEARNING_RATE}")
            print(f"    Entropy coefficient: {ENTROPY_COEFF}")
            print(f"    Gamma (discount): {GAMMA}")
            print(f"    PPO clip param: {CLIP_PARAM}")
            print(f"    VF clip param: {VF_CLIP_PARAM}")
            print(f"    GAE lambda: {GAE_LAMBDA}")

            try:
                # Update the algorithm's config object (used for future operations)
                algo.config.training(
                    lr=LEARNING_RATE,
                    entropy_coeff=ENTROPY_COEFF,
                    gamma=GAMMA,
                    clip_param=CLIP_PARAM,
                    vf_clip_param=VF_CLIP_PARAM,
                    lambda_=GAE_LAMBDA,
                )

                # Access learner group and update optimizer settings directly
                learner_group = algo.learner_group
                if learner_group and hasattr(learner_group, '_learners'):
                    for learner in learner_group._learners:
                        # Update optimizer learning rate
                        if hasattr(learner, '_optimizer') and learner._optimizer is not None:
                            for param_group in learner._optimizer.param_groups:
                                param_group['lr'] = LEARNING_RATE

                        # Update learner config if accessible
                        if hasattr(learner, '_hps'):
                            learner._hps.lr = LEARNING_RATE
                            learner._hps.entropy_coeff = ENTROPY_COEFF
                            learner._hps.gamma = GAMMA
                            learner._hps.clip_param = CLIP_PARAM
                            learner._hps.vf_clip_param = VF_CLIP_PARAM
                            learner._hps.lambda_ = GAE_LAMBDA

                print("  ✓ Hyperparameters updated successfully!")
            except Exception as e:
                print(f"  ⚠ WARNING: Could not fully update hyperparameters: {e}")
                print(f"    Training will attempt to continue anyway...")

        except Exception as e:
            print(f"✗ WARNING: Failed to restore checkpoint: {e}")
            print("  Continuing with fresh algorithm...")
    else:
        print("No checkpoint to restore - training from scratch")

    print("="*50 + "\n")

    try:
        for i in range(20000):
            current_iteration = next_iteration + i
            print(f"\n--- Training iteration {current_iteration} (loop {i+1}) ---")

            # Train for one iteration
            result = algo.train()

            # Extract metrics safely
            print(f"\nIteration {current_iteration:03d} results:")

            # Check different possible metric locations
            # New API puts metrics in different places

            # Try env_runners metrics first (new API)
            env_runners = result.get("env_runners", {})
            if env_runners:
                episodes = env_runners.get("episodes_this_iter", 0)
                print(f"  Episodes collected: {episodes}")

                if episodes > 0:
                    episode_reward_mean = env_runners.get("episode_reward_mean", None)
                    if episode_reward_mean is not None:
                        print(f"  Episode reward mean: {episode_reward_mean:.3f}")
                        print(f"  Episode reward min: {env_runners.get('episode_reward_min', 0):.3f}")
                        print(f"  Episode reward max: {env_runners.get('episode_reward_max', 0):.3f}")

                    episode_len_mean = env_runners.get("episode_len_mean", None)
                    if episode_len_mean is not None:
                        print(f"  Episode length mean: {episode_len_mean:.1f}")

                # Timesteps info
                timesteps = env_runners.get("timesteps_this_iter", 0)
                if timesteps > 0:
                    print(f"  Timesteps collected: {timesteps}")

            # Also check top-level metrics (compatibility)
            if "episode_reward_mean" in result:
                print(f"  [Top-level] Episode reward mean: {result['episode_reward_mean']:.3f}")

            # Training metrics
            timesteps_total = result.get("timesteps_total", 0)
            if timesteps_total > 0:
                print(f"  Total timesteps: {timesteps_total}")

            num_agent_steps = result.get("num_agent_steps_trained", 0)
            if num_agent_steps > 0:
                print(f"  Agent steps trained: {num_agent_steps}")

            # Learner metrics (new API might use different keys)
            learners = result.get("learners", {})

            # Debug: Print top-level keys to see where metrics are stored
            if not learners:
                print("  DEBUG: No 'learners' key found. Top-level result keys:", list(result.keys()))
                # Try alternative locations
                if "info" in result and "learner" in result["info"]:
                    learners = result["info"]["learner"]
                    print("  Found learners in result['info']['learner']")
                elif "learner_info" in result:
                    learners = result["learner_info"]
                    print("  Found learners in result['learner_info']")

            if learners:
                print("  Learner metrics found")
                print(f"  Available policies in learners: {list(learners.keys())}")

                # Dynamically determine labels based on POLICIES_TO_TRAIN configuration
                # The structure might be nested differently
                if "policy_LT50" in learners:
                    lt50_stats = learners["policy_LT50"]
                    lt50_label = "LT50 TRAINABLE" if "policy_LT50" in POLICIES_TO_TRAIN else "LT50 FROZEN"
                    print(f"    [{lt50_label}] Policy loss: {lt50_stats.get('policy_loss', 'N/A')}")
                    print(f"    [{lt50_label}] VF loss: {lt50_stats.get('vf_loss', 'N/A')}")
                    print(f"    [{lt50_label}] Entropy: {lt50_stats.get('entropy', 'N/A')}")
                    if "policy_LT50" not in POLICIES_TO_TRAIN:
                        print(f"    WARNING: policy_LT50 appears in learners but is configured as FROZEN!")

                if "policy_frontline" in learners:
                    frontline_stats = learners["policy_frontline"]
                    frontline_label = "FRONTLINE TRAINABLE" if "policy_frontline" in POLICIES_TO_TRAIN else "FRONTLINE FROZEN"
                    print(f"    [{frontline_label}] Policy loss: {frontline_stats.get('policy_loss', 'N/A')}")
                    print(f"    [{frontline_label}] VF loss: {frontline_stats.get('vf_loss', 'N/A')}")
                    print(f"    [{frontline_label}] Entropy: {frontline_stats.get('entropy', 'N/A')}")
                    if "policy_frontline" not in POLICIES_TO_TRAIN:
                        print(f"    WARNING: policy_frontline appears in learners but is configured as FROZEN!")

                if "policy_GT50" in learners:
                    gt50_stats = learners["policy_GT50"]
                    gt50_label = "GT50 TRAINABLE" if "policy_GT50" in POLICIES_TO_TRAIN else "GT50 FROZEN"
                    print(f"    [{gt50_label}] Policy loss: {gt50_stats.get('policy_loss', 'N/A')}")
                    print(f"    [{gt50_label}] VF loss: {gt50_stats.get('vf_loss', 'N/A')}")
                    print(f"    [{gt50_label}] Entropy: {gt50_stats.get('entropy', 'N/A')}")
                    if "policy_GT50" not in POLICIES_TO_TRAIN:
                        print(f"    WARNING: policy_GT50 appears in learners but is configured as FROZEN!")

                if "default_policy" in learners:
                    default_stats = learners["default_policy"]
                    print(f"    [LEGACY] Policy loss: {default_stats.get('policy_loss', 'N/A')}")
                    print(f"    [LEGACY] VF loss: {default_stats.get('vf_loss', 'N/A')}")
                    print(f"    Entropy: {default_stats.get('entropy', 'N/A')}")

            # Save checkpoint periodically
            if (i + 1) % 1 == 0:
                ckpt_path = os.path.join(checkpoint_dir, f"checkpoint_{current_iteration:03d}")
                ckpt = algo.save(ckpt_path)
                print(f"\n>>> Saved checkpoint: {ckpt}")

                # Note: Model export not available with new RLModule API
                # Use checkpoints for both training resume and inference

    except KeyboardInterrupt:
        print("\nInterrupted by user; saving checkpoint...")
        ckpt_path = os.path.join(checkpoint_dir, "checkpoint_interrupted")
        ckpt = algo.save(ckpt_path)
        print(f"Saved checkpoint: {ckpt}")
    except Exception as e:
        print(f"\nError during training: {e}")
        import traceback
        traceback.print_exc()
    finally:
        # Save final checkpoint
        print("\nSaving final checkpoint...")
        ckpt_path = os.path.join(checkpoint_dir, "checkpoint_final")
        ckpt = algo.save(ckpt_path)
        print(f"Final checkpoint: {ckpt}")

        algo.stop()
        ray.shutdown()