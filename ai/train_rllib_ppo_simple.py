# train_rllib_ppo_simple.py - Multi-policy PPO training for Godot RTS units
#
# This script trains 100 RTS units across 3 policies:
# - policy_LT50: 49 trainable units (u1-u49)
# - policy_GT50: 26 frozen baseline units (u50-u75)
# - policy_frontline: 25 trainable frontline units (u76-u100)
#
# The system supports dynamic policy assignment - units can switch policies at runtime
# via Godot's unit.set_policy() method. Policy assignments are sent from Godot in
# observations and read via policy_mapping_fn.

import gymnasium as gym
import numpy as np
import ray
from ray.rllib.algorithms.ppo import PPOConfig
from godot_multi_env import GodotRTSMultiAgentEnv
import os

# Observation space: Box(-1.0, 1.0, (4,))
# - Normalized x, y position
# - HP ratio (current/max)
# - Distance to map center (normalized)
# Note: Actual observation is 92-dimensional with battle stats, nearby units, and POIs
OBS_SPACE = gym.spaces.Box(low=-1.0, high=1.0, shape=(4,), dtype=np.float32)

# Action space: Discrete(9) - 8 directional movements + stay
# Actions map to movement offsets applied in godot_multi_env.py
ACT_SPACE = gym.spaces.Discrete(9)

# Three policies with different training configurations
POLICIES = {
    "policy_LT50": (None, OBS_SPACE, ACT_SPACE, {}),      # 49 units (u1-u49), trainable
    "policy_GT50": (None, OBS_SPACE, ACT_SPACE, {}),      # 26 units (u50-u75), frozen baseline
    "policy_frontline": (None, OBS_SPACE, ACT_SPACE, {}), # 25 units (u76-u100), trainable
}

def policy_mapping_fn(agent_id, episode=None, worker=None, **kwargs):
    """
    Map agents to policies dynamically based on policy_id from Godot observations.

    This function is called by RLlib to determine which policy controls each agent.
    It enables runtime policy switching - units can change policies mid-episode via
    Godot's unit.set_policy("policy_name") method.

    Priority:
    1. Try to read policy_id from episode info (dynamic assignment from Godot)
    2. Fall back to unit ID-based assignment (u1-49→LT50, u50-75→GT50, u76-100→frontline)
    3. Default to policy_LT50 if all else fails

    Args:
        agent_id: Unit identifier (e.g., "u25", "u87")
        episode: Episode object containing agent info/observations (RLlib API)
        worker: Worker object (unused, for API compatibility)

    Returns:
        str: Policy name ("policy_LT50", "policy_GT50", or "policy_frontline")
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
                    return policy_id  # Dynamic policy assignment
        except (AttributeError, KeyError, TypeError):
            # Episode API might differ or info not available, fall through
            pass

    # Fallback: Derive policy from unit ID number
    # This handles initial assignment before first observation is received
    try:
        if agent_id.startswith("u"):
            unit_num = int(agent_id[1:])
            if unit_num < 50:
                return "policy_LT50"      # u1-u49: trainable
            elif unit_num < 76:
                return "policy_GT50"      # u50-u75: frozen baseline
            else:
                return "policy_frontline"  # u76-u100: trainable frontline
    except (ValueError, IndexError):
        pass

    # Final fallback for malformed IDs
    return "policy_LT50"

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

    print("Observation space defined:", OBS_SPACE)
    print("Action space defined:", ACT_SPACE)

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
                "host": "127.0.0.1",
                "port": 5555,  # TCP connection to Godot game
                "timeout": 5,   # Socket timeout in seconds
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
            gamma=0.99,          # Discount factor for future rewards
            lr=3e-4,             # Learning rate (standard PPO: 3e-4)
            train_batch_size=2000,   # Total timesteps per training iteration
            minibatch_size=500,     # Batch size for SGD (split train_batch into chunks)
            num_epochs=10,          # Number of SGD passes over each batch
            clip_param=0.2,         # PPO clip parameter (prevent large policy updates)
            vf_clip_param=10.0,     # Value function clip parameter
            use_gae=True,           # Use Generalized Advantage Estimation
            lambda_=0.9,            # GAE lambda parameter (bias-variance tradeoff)
            entropy_coeff=0.01,    # Entropy bonus for exploration (increased for more randomness)
        )
        .rl_module(
            model_config={
                "fcnet_hiddens": [64,64,64],                    # 3-layer MLP, known to work: [64,64,64] with 89dim obs space
                "fcnet_activation": "tanh",                     # Tanh activation function
                "fcnet_weights_initializer": "xavier_uniform_", # Xavier uniform weight init
                "fcnet_bias_initializer": "zeros_",             # Zero bias initialization
            }
        )
        .multi_agent(
            policies={"policy_LT50", "policy_GT50", "policy_frontline"},
            policy_mapping_fn=policy_mapping_fn,
            # Train policy_LT50 only, keep GT50 and frontline frozen
            # Note: User can change policies_to_train to enable/disable training per policy
            policies_to_train=["policy_LT50", "policy_GT50", "policy_frontline"],
            count_steps_by="agent_steps",  # Count steps per agent (not env steps)
        )
        .resources(
            num_gpus=0,  # CPU-only training (set to 1 for GPU acceleration)
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
    skip_checkpoint_loading = False  # Set to True to train from scratch - ENABLED for fresh start

    # Determine which checkpoint to load
    checkpoint_to_load = None
    if not skip_checkpoint_loading:
        if latest_checkpoint:
            # Load most recent training checkpoint to continue from where we left off
            checkpoint_to_load = latest_checkpoint
            print(f"Found latest checkpoint: {checkpoint_to_load}")
        else:
            # Fallback to baseline 3-policy checkpoint if no training checkpoints exist
            checkpoint_3policy = os.path.abspath("./checkpoints/checkpoint_3policy")
            if os.path.exists(checkpoint_3policy):
                checkpoint_to_load = checkpoint_3policy
                print(f"No training checkpoints found, loading baseline: {checkpoint_3policy}")
            else:
                print("No checkpoints found, training from scratch")

    if checkpoint_to_load:
        print(f"Restoring algorithm from checkpoint: {checkpoint_to_load}")
        algo = cfg.build()
        try:
            algo.restore(checkpoint_to_load)
            print("Algorithm restored successfully!")
            print(f"  Loaded 3 policies: LT50 (trainable), GT50 (frozen baseline), frontline (trainable)")
        except Exception as e:
            print(f"WARNING: Failed to restore checkpoint: {e}")
            print("Starting fresh training instead...")
            algo = cfg.build()
    else:
        print("Building new algorithm (training from scratch)...")
        algo = cfg.build()
        print("Algorithm built successfully!")
    print("="*50 + "\n")

    try:
        for i in range(200):
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
                # The structure might be nested differently
                if "policy_LT50" in learners:
                    lt50_stats = learners["policy_LT50"]
                    print(f"    [LT50 TRAINABLE] Policy loss: {lt50_stats.get('policy_loss', 'N/A')}")
                    print(f"    [LT50 TRAINABLE] VF loss: {lt50_stats.get('vf_loss', 'N/A')}")
                    print(f"    [LT50 TRAINABLE] Entropy: {lt50_stats.get('entropy', 'N/A')}")
                else:
                    print("    WARNING: policy_LT50 not found in learners!")

                if "policy_frontline" in learners:
                    frontline_stats = learners["policy_frontline"]
                    print(f"    [FRONTLINE TRAINABLE] Policy loss: {frontline_stats.get('policy_loss', 'N/A')}")
                    print(f"    [FRONTLINE TRAINABLE] VF loss: {frontline_stats.get('vf_loss', 'N/A')}")
                    print(f"    [FRONTLINE TRAINABLE] Entropy: {frontline_stats.get('entropy', 'N/A')}")
                else:
                    print("    WARNING: policy_frontline not found in learners!")

                if "policy_GT50" in learners:
                    gt50_stats = learners["policy_GT50"]
                    print(f"    [GT50 FROZEN] Policy loss: {gt50_stats.get('policy_loss', 'N/A')}")
                    print(f"    [GT50 FROZEN] VF loss: {gt50_stats.get('vf_loss', 'N/A')}")
                    print(f"    [GT50 FROZEN] Entropy: {gt50_stats.get('entropy', 'N/A')}")
                    print(f"    WARNING: GT50 should NOT appear in learners if frozen!")
                else:
                    print(f"    [OK] GT50 not in learners (correctly frozen)")

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