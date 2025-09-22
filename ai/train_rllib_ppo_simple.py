# train_rllib_ppo_simple.py - Simplified version with high entropy for unbiased exploration
import gymnasium as gym
import numpy as np
import ray
from ray.rllib.algorithms.ppo import PPOConfig
from godot_multi_env import GodotRTSMultiAgentEnv
import os

# --- Define spaces to match the env ---
OBS_SPACE = gym.spaces.Box(low=-1.0, high=1.0, shape=(4,), dtype=np.float32)
ACT_SPACE = gym.spaces.Discrete(9)

# Single shared policy for all units
POLICIES = {
    "infantry": (None, OBS_SPACE, ACT_SPACE, {}),
}

def policy_mapping_fn(agent_id, *_, **__):
    return "infantry"

if __name__ == "__main__":
    # Keep logs quieter in notebooks
    os.environ.setdefault("PYTHONWARNINGS", "ignore::DeprecationWarning")

    # Idempotent Ray startup
    ray.shutdown()
    ray.init(include_dashboard=False, num_cpus=4)

    # Checkpoint and model paths - use absolute paths for new RLlib API
    checkpoint_dir = os.path.abspath("./checkpoints")
    model_dir = os.path.abspath("./models")
    os.makedirs(checkpoint_dir, exist_ok=True)
    os.makedirs(model_dir, exist_ok=True)

    # Look for latest checkpoint to resume training and determine next iteration number
    latest_checkpoint = None
    next_iteration = 1  # Start from 1 if no checkpoints exist

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

    # Create a test environment to verify connection to Godot
    test_env = GodotRTSMultiAgentEnv({
        "host": "127.0.0.1",
        "port": 5555,
        "timeout": 5,
    })
    print("Test environment created successfully")
    test_obs, test_info = test_env.reset()
    print(f"Test reset successful, connected to {len(test_obs)} agents: {list(test_obs.keys())}")
    test_env.close()

    # PPO configuration for single-worker multi-agent RTS training
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
                "host": "127.0.0.1",
                "port": 5555,  # Single Godot instance on port 5555
                "timeout": 5,
            },
            disable_env_checking=True,
        )
        .env_runners(
            num_env_runners=1,  # 3 workers for faster training
            num_envs_per_env_runner=1,
            # CRITICAL: Use complete_episodes mode for proper episode handling
            batch_mode="complete_episodes",
            # With 12 agents and 200 steps per episode = 2400 total timesteps per episode
            rollout_fragment_length=200,  # 200 steps * 12 agents = 2400 timesteps
        )
        .training(
            gamma=0.99,
            lr=3e-3,
            # Train batch size for single worker setup
            train_batch_size=400,  # Single worker collecting 400 timesteps
            minibatch_size=200,   # Half of train batch for gradient updates
            num_epochs=10,
            clip_param=0.2,
            vf_clip_param=10.0,
            # Use GAE
            use_gae=True,
            lambda_=0.9,
            entropy_coeff=0.001,
        )
        .rl_module(
            model_config={
                "fcnet_hiddens": [64, 64, 64],
                "fcnet_activation": "tanh",
                # Better initialization with proper PyTorch syntax
                "fcnet_weights_initializer": "xavier_uniform_",
                "fcnet_bias_initializer": "zeros_",
            }
        )
        .multi_agent(
            policies={"infantry"},  # Single shared policy for all RTS units
            policy_mapping_fn=policy_mapping_fn,
            # Count by agent steps for proper multi-agent metrics
            count_steps_by="agent_steps",
        )
        .resources(
            num_gpus=0,
            num_cpus_for_main_process=1,  # Single worker setup
        )
        .reporting(
            # Report metrics at episode granularity for single worker
            metrics_num_episodes_for_smoothing=1,
            min_time_s_per_iteration=0,
            min_sample_timesteps_per_iteration=400,  # Match train_batch_size for single worker
        )
        .debugging(
            log_level="INFO",
        )
    )

    print("\n" + "="*50)
    if latest_checkpoint:
        print(f"Restoring algorithm from checkpoint: {latest_checkpoint}")
        algo = cfg.build()
        algo.restore(latest_checkpoint)
        print("Algorithm restored successfully!")
    else:
        print("Building new algorithm...")
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

            # Learner metrics
            learners = result.get("learners", {})
            if learners:
                print("  Learner metrics found")
                # The structure might be nested differently
                if "infantry" in learners:
                    infantry_stats = learners["infantry"]
                    print(f"    Policy loss: {infantry_stats.get('policy_loss', 'N/A')}")
                    print(f"    VF loss: {infantry_stats.get('vf_loss', 'N/A')}")
                    print(f"    Entropy: {infantry_stats.get('entropy', 'N/A')}")
                elif "default_policy" in learners:
                    default_stats = learners["default_policy"]
                    print(f"    Policy loss: {default_stats.get('policy_loss', 'N/A')}")
                    print(f"    VF loss: {default_stats.get('vf_loss', 'N/A')}")
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