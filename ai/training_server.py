# training_server.py - Multi-policy PPO training for Godot RTS units
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
import argparse
import logging

# Suppress verbose Ray/RLlib logging
logging.getLogger("ray").setLevel(logging.WARNING)
logging.getLogger("ray.rllib").setLevel(logging.WARNING)

# =============================================================================
# Command Line Arguments
# =============================================================================

parser = argparse.ArgumentParser(description="RTS Multi-Agent PPO Training Server")
parser.add_argument("-v", "--verbose", action="store_true",
                    help="Enable verbose output (debug logging)")
parser.add_argument("-q", "--quiet", action="store_true",
                    help="Minimal output (only errors and checkpoints)")
# Use parse_known_args to ignore PyCharm/IDE arguments
args, _ = parser.parse_known_args()

# Verbosity levels: quiet < normal < verbose
VERBOSE = args.verbose
QUIET = args.quiet

def log(msg, level="normal"):
    """Print message based on verbosity level.

    Levels:
    - "debug": Only shown with --verbose
    - "normal": Shown unless --quiet
    - "important": Always shown
    """
    if level == "debug" and not VERBOSE:
        return
    if level == "normal" and QUIET:
        return
    print(msg)

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

# =============================================================================
# Policy Configuration
# =============================================================================

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

log(f"\n=== Configured {len(POLICIES)} policies for training ===")
for policy_id in POLICIES.keys():
    net_config = policy_manager.get_network_config(policy_id)
    trainable = policy_manager.is_trainable(policy_id)
    log(f"  {policy_id}: {net_config.get('fcnet_hiddens')} [{'TRAIN' if trainable else 'FROZEN'}]")

def policy_mapping_fn(agent_id, episode=None, worker=None, **kwargs):
    """
    Map agents to policies dynamically based on policy_id from Godot observations.

    This function is called by RLlib to determine which policy controls each agent.
    It enables runtime policy switching - units can change policies mid-episode via
    Godot's unit.set_policy("policy_name") method.

    Priority:
    1. Try to get from worker's environment directly (most reliable, same process)
    2. Try to read from class-level global mapping (backup)
    3. Try to read policy_id from episode info
    4. Fall back to default_policy from JSON config

    Args:
        agent_id: Unit identifier (e.g., "u25", "u87")
        episode: Episode object containing agent info/observations (RLlib API)
        worker: Worker object that has access to the environment

    Returns:
        str: Policy ID from JSON config
    """
    # DEBUG: Log ALL calls to understand the flow
    global _policy_mapping_call_count
    if '_policy_mapping_call_count' not in globals():
        _policy_mapping_call_count = 0
    _policy_mapping_call_count += 1

    # Log every 1000th call to see if this function is being called at all
    if _policy_mapping_call_count <= 10 or _policy_mapping_call_count % 1000 == 0:
        log(f"DEBUG policy_mapping_fn called #{_policy_mapping_call_count}: agent={agent_id}, worker={worker is not None}, episode={episode is not None}", level="debug")

    from godot_multi_env import GodotRTSMultiAgentEnv

    # Method 1: Try to get from worker's environment directly (most reliable)
    # This accesses the actual env instance in the same process
    if worker is not None:
        try:
            # Try different ways to access the environment from worker
            env = None
            if hasattr(worker, 'env'):
                env = worker.env
            elif hasattr(worker, 'async_env'):
                env = worker.async_env
            elif hasattr(worker, 'env_runner') and hasattr(worker.env_runner, 'env'):
                env = worker.env_runner.env

            if env is not None:
                # Handle vectorized envs
                if hasattr(env, 'envs') and len(env.envs) > 0:
                    env = env.envs[0]
                if hasattr(env, 'env'):
                    env = env.env

                if hasattr(env, 'agent_to_policy') and agent_id in env.agent_to_policy:
                    policy_id = env.agent_to_policy[agent_id]
                    if policy_id in POLICIES:
                        if _policy_mapping_call_count < 5:
                            log(f"DEBUG policy_mapping_fn: {agent_id} -> {policy_id} (from worker env)", level="debug")
                            _policy_mapping_call_count += 1
                        # Update class-level tracking
                        GodotRTSMultiAgentEnv._last_policy_mapping[agent_id] = policy_id
                        return policy_id
        except Exception as e:
            if _policy_mapping_call_count < 5:
                log(f"DEBUG policy_mapping_fn: worker access failed: {e}", level="debug")

    # Method 2: Try to get from environment's global agent_to_policy mapping
    # This works when policy_mapping_fn runs in same process as env
    try:
        if hasattr(GodotRTSMultiAgentEnv, '_agent_to_policy_global'):
            agent_to_policy = GodotRTSMultiAgentEnv._agent_to_policy_global
            if agent_id in agent_to_policy:
                policy_id = agent_to_policy[agent_id]
                if policy_id in POLICIES:
                    if _policy_mapping_call_count < 5:
                        log(f"DEBUG policy_mapping_fn: {agent_id} -> {policy_id} (from global mapping)", level="debug")
                        _policy_mapping_call_count += 1

                    # Store what we're returning so environment can verify it
                    if not hasattr(GodotRTSMultiAgentEnv, '_last_policy_mapping'):
                        GodotRTSMultiAgentEnv._last_policy_mapping = {}
                    GodotRTSMultiAgentEnv._last_policy_mapping[agent_id] = policy_id

                    return policy_id
    except (ImportError, AttributeError, KeyError, TypeError) as e:
        pass

    # Method 3: Try to get policy from episode info (for mid-episode switches)
    if episode is not None:
        try:
            info = None

            if hasattr(episode, 'last_info_for'):
                info = episode.last_info_for(agent_id)
            elif hasattr(episode, '_agent_to_last_info') and agent_id in episode._agent_to_last_info:
                info = episode._agent_to_last_info[agent_id]
            elif hasattr(episode, 'agent_infos') and agent_id in episode.agent_infos:
                info = episode.agent_infos[agent_id]

            if info and "policy_id" in info:
                policy_id = info["policy_id"]
                if policy_id in POLICIES:
                    if _policy_mapping_call_count < 5:
                        log(f"DEBUG policy_mapping_fn: {agent_id} -> {policy_id} (from episode info)", level="debug")
                        _policy_mapping_call_count += 1
                    return policy_id
        except (AttributeError, KeyError, TypeError) as e:
            pass

    # Method 4: Fallback to default policy from config
    if _policy_mapping_call_count < 5:
        log(f"DEBUG policy_mapping_fn: {agent_id} -> fallback to default ({policy_manager.default_policy})", level="debug")
        _policy_mapping_call_count += 1

    # Store the fallback policy
    try:
        if not hasattr(GodotRTSMultiAgentEnv, '_last_policy_mapping'):
            GodotRTSMultiAgentEnv._last_policy_mapping = {}
        GodotRTSMultiAgentEnv._last_policy_mapping[agent_id] = policy_manager.default_policy
    except:
        pass

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
            log(f"Found latest checkpoint: {latest_checkpoint}")

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
                log(f"Resuming from iteration {next_iteration}")
            else:
                next_iteration = 1

    log(f"Observation space: {OBS_SPACE}")
    log(f"Action space: {ACT_SPACE}")

    # Configure which policies to train (loaded from JSON)
    # Frozen policies are used as baselines for comparison
    POLICIES_TO_TRAIN = policy_manager.get_trainable_policies()
    FROZEN_POLICIES = policy_manager.get_frozen_policies()
    log(f"\nTraining configuration:")
    log(f"  Trainable policies: {POLICIES_TO_TRAIN}")
    log(f"  Frozen policies: {FROZEN_POLICIES}\n")

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
                "verbose": VERBOSE,
                "quiet": QUIET,
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
            log_level="WARN",  # Suppress INFO spam (use DEBUG for troubleshooting)
        )
    )

    log("\n" + "="*50)
    # Checkpoint loading configuration
    # Priority: latest numbered checkpoint > checkpoint_3policy > train from scratch
    # IMPORTANT: Set to True when policy configuration changes (policy names/count)
    skip_checkpoint_loading = False  # Set to False to load from checkpoint (policies must match!)

    # Determine which checkpoint to load
    checkpoint_to_load = None
    if not skip_checkpoint_loading:
        if latest_checkpoint:
            checkpoint_to_load = latest_checkpoint
            log(f"Found latest checkpoint: {checkpoint_to_load}")
        else:
            checkpoint_3policy = os.path.abspath("./checkpoints/checkpoint_3policy")
            if os.path.exists(checkpoint_3policy):
                checkpoint_to_load = checkpoint_3policy
                log(f"No training checkpoints found, loading baseline: {checkpoint_3policy}")
            else:
                log("No checkpoints found, training from scratch")
    else:
        log("Checkpoint loading disabled - training from scratch with new policy configuration")

    # Build algorithm with current hyperparameters from rts_config.py
    log("Building algorithm with hyperparameters from rts_config.py:")
    log(f"    Learning rate: {LEARNING_RATE}")
    log(f"    Entropy coefficient: {ENTROPY_COEFF}")
    log(f"    Gamma (discount): {GAMMA}")
    log(f"    PPO clip param: {CLIP_PARAM}")
    log(f"    VF clip param: {VF_CLIP_PARAM}")
    log(f"    GAE lambda: {GAE_LAMBDA}")
    algo = cfg.build()

    # Restore trained weights from checkpoint (but keep new hyperparameters)
    if checkpoint_to_load:
        log(f"Loading trained weights from checkpoint: {checkpoint_to_load}")
        try:
            # Load the checkpoint's learner state (neural network weights)
            learner_state_dir = os.path.join(checkpoint_to_load, "learner")
            if os.path.exists(learner_state_dir):
                # Load learner group state (contains policy weights)
                algo.learner_group.load_state(learner_state_dir)
                log("[OK] Loaded trained weights from checkpoint!")
                log(f"  Policies restored: {list(POLICIES.keys())}")
                log("  Hyperparameters: Using NEW values from rts_config.py")
            else:
                # Fallback: try full restore if learner state not found separately
                log("  Learner state dir not found, attempting full restore...", level="debug")
                algo.restore(checkpoint_to_load)
                log("[OK] Full checkpoint restore completed")
                log("  Note: Hyperparameters from checkpoint (not rts_config.py)", level="important")

        except Exception as e:
            log(f"[X] WARNING: Failed to load checkpoint weights: {e}", level="important")
            log("  Continuing with randomly initialized weights...", level="important")
    else:
        log("No checkpoint to load - training from scratch with random weights")

    log("="*50 + "\n")

    consecutive_errors = 0
    max_consecutive_errors = 5  # Stop if too many errors in a row

    try:
        for i in range(20000):
            current_iteration = next_iteration + i
            log(f"\n--- Training iteration {current_iteration} (loop {i+1}) ---")

            # Train for one iteration with error recovery
            try:
                result = algo.train()
                consecutive_errors = 0  # Reset on success
            except Exception as train_error:
                consecutive_errors += 1
                error_msg = str(train_error)

                # Check if it's a recoverable error
                if "already had its" in error_msg and "is_done" in error_msg:
                    log(f"WARNING: Agent done-state error (attempt {consecutive_errors}/{max_consecutive_errors})", level="important")
                    log(f"  Error: {error_msg[:200]}...", level="important")
                    log("  This usually means Godot sent data for an agent after episode ended.", level="important")
                    log("  Attempting to continue training...", level="important")

                    if consecutive_errors >= max_consecutive_errors:
                        log(f"ERROR: Too many consecutive errors ({consecutive_errors}), stopping training", level="important")
                        raise

                    # Try to recover by waiting a bit
                    import time
                    time.sleep(1.0)
                    continue  # Skip to next iteration
                else:
                    # Unknown error - re-raise
                    raise

            # Extract metrics safely
            log(f"\nIteration {current_iteration:03d} results:")

            # Check different possible metric locations
            # New API puts metrics in different places

            # Try env_runners metrics first (new API)
            env_runners = result.get("env_runners", {})
            if env_runners:
                episodes = env_runners.get("episodes_this_iter", 0)
                log(f"  Episodes collected: {episodes}")

                if episodes > 0:
                    episode_reward_mean = env_runners.get("episode_reward_mean", None)
                    if episode_reward_mean is not None:
                        log(f"  Episode reward mean: {episode_reward_mean:.3f}")
                        log(f"  Episode reward min: {env_runners.get('episode_reward_min', 0):.3f}")
                        log(f"  Episode reward max: {env_runners.get('episode_reward_max', 0):.3f}")

                    episode_len_mean = env_runners.get("episode_len_mean", None)
                    if episode_len_mean is not None:
                        log(f"  Episode length mean: {episode_len_mean:.1f}")

                # Timesteps info
                timesteps = env_runners.get("timesteps_this_iter", 0)
                if timesteps > 0:
                    log(f"  Timesteps collected: {timesteps}")

            # Also check top-level metrics (compatibility)
            if "episode_reward_mean" in result:
                log(f"  [Top-level] Episode reward mean: {result['episode_reward_mean']:.3f}")

            # Training metrics
            timesteps_total = result.get("timesteps_total", 0)
            if timesteps_total > 0:
                log(f"  Total timesteps: {timesteps_total}")

            num_agent_steps = result.get("num_agent_steps_trained", 0)
            if num_agent_steps > 0:
                log(f"  Agent steps trained: {num_agent_steps}")

            # Learner metrics (new API might use different keys)
            learners = result.get("learners", {})

            # Debug: Print top-level keys to see where metrics are stored
            if not learners:
                log("  DEBUG: No 'learners' key found. Top-level result keys: " + str(list(result.keys())), level="debug")
                # Try alternative locations
                if "info" in result and "learner" in result["info"]:
                    learners = result["info"]["learner"]
                    log("  Found learners in result['info']['learner']", level="debug")
                elif "learner_info" in result:
                    learners = result["learner_info"]
                    log("  Found learners in result['learner_info']", level="debug")

            if learners:
                log("  Learner metrics found", level="debug")

                # Display metrics for each policy dynamically
                for policy_id in policy_manager.get_policy_ids():
                    if policy_id in learners:
                        stats = learners[policy_id]
                        trainable = policy_manager.is_trainable(policy_id)
                        display_name = policy_manager.get_display_name(policy_id)
                        label = f"{display_name} ({'TRAIN' if trainable else 'FROZEN'})"

                        log(f"    [{label}]")
                        log(f"      Policy loss: {stats.get('policy_loss', 'N/A')}")
                        log(f"      VF loss: {stats.get('vf_loss', 'N/A')}")
                        log(f"      Entropy: {stats.get('entropy', 'N/A')}")
                        log(f"      Mean KL: {stats.get('mean_kl_loss', 'N/A')}")

            # Save checkpoint periodically
            if (i + 1) % 1 == 0:
                ckpt_name = f"checkpoint_{current_iteration:03d}"
                ckpt_path = os.path.join(checkpoint_dir, ckpt_name)
                ckpt = algo.save(ckpt_path)
                log(f"\n>>> Saved checkpoint: {ckpt}", level="important")

                # Note: Model export not available with new RLModule API
                # Use checkpoints for both training resume and inference

    except KeyboardInterrupt:
        log("\nInterrupted by user; saving checkpoint...", level="important")
        ckpt_name = "checkpoint_interrupted"
        ckpt_path = os.path.join(checkpoint_dir, ckpt_name)
        ckpt = algo.save(ckpt_path)
        log(f"Saved checkpoint: {ckpt}", level="important")
    except Exception as e:
        log(f"\nError during training: {e}", level="important")
        import traceback
        traceback.print_exc()
    finally:
        # Save final checkpoint
        log("\nSaving final checkpoint...", level="important")
        ckpt_name = "checkpoint_final"
        ckpt_path = os.path.join(checkpoint_dir, ckpt_name)
        ckpt = algo.save(ckpt_path)
        log(f"Final checkpoint: {ckpt}", level="important")

        algo.stop()
        ray.shutdown()