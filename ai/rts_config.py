"""
Central configuration for RTS Multi-Agent RL Training

This module defines the single source of truth for observation/action spaces
and other shared configuration between the training script and environment.

IMPORTANT: Both train_rllib_ppo_simple.py and godot_multi_env.py import from this file
to ensure space definitions stay synchronized.
"""

import gymnasium as gym
import numpy as np

# ============================================================================
# OBSERVATION SPACE
# ============================================================================
# 94-dimensional observation vector with the following structure:
#
# Base stats (3 dimensions):
#   - vel_x: Velocity X component (normalized, range depends on max speed)
#   - vel_y: Velocity Y component (normalized, range depends on max speed)
#   - hp_ratio: Current HP / Max HP (range [0, 1])
#
# Battle stats (5 dimensions):
#   - attack_range: Attack range in pixels (normalized)
#   - attack_damage: Damage per attack (normalized)
#   - attack_cooldown: Time between attacks in seconds (normalized)
#   - cooldown_remaining: Current cooldown remaining (normalized)
#   - speed: Movement speed in pixels/second (normalized)
#
# Closest allies (40 dimensions = 10 units × 4 values):
#   For each of the 10 closest allied units:
#     - direction_x: Normalized X direction to ally (range [-1, 1])
#     - direction_y: Normalized Y direction to ally (range [-1, 1])
#     - distance: Distance to ally in pixels (normalized, can exceed 1.0)
#     - hp_ratio: Ally's HP ratio (range [0, 1])
#
# Closest enemies (40 dimensions = 10 units × 4 values):
#   For each of the 10 closest enemy units:
#     - direction_x: Normalized X direction to enemy (range [-1, 1])
#     - direction_y: Normalized Y direction to enemy (range [-1, 1])
#     - distance: Distance to enemy in pixels (normalized, can exceed 1.0)
#     - hp_ratio: Enemy's HP ratio (range [0, 1])
#
# Points of Interest (6 dimensions = 2 POIs × 3 values):
#   POI 1: Enemy base
#     - direction_x: Normalized X direction to enemy base (range [-1, 1])
#     - direction_y: Normalized Y direction to enemy base (range [-1, 1])
#     - distance: Distance to enemy base (normalized, can exceed 1.0)
#   POI 2: Own base
#     - direction_x: Normalized X direction to own base (range [-1, 1])
#     - direction_y: Normalized Y direction to own base (range [-1, 1])
#     - distance: Distance to own base (normalized, can exceed 1.0)
#
# Total: 3 + 5 + 40 + 40 + 6 = 94 dimensions

OBSERVATION_SPACE = gym.spaces.Box(
    low=-1.0,
    high=10.0,  # High value accounts for unnormalized distances
    shape=(94,),
    dtype=np.float32
)

# ============================================================================
# ACTION SPACE
# ============================================================================
# Continuous 2D movement vector [dx, dy] in range [-1, 1]
#
# Action format:
#   [dx, dy] where both components are in range [-1, 1]
#
# Interpretation (handled by Godot):
#   - Direction: The vector direction determines movement direction
#     Example: [1, 0] = east, [0, 1] = north, [1, 1] = northeast
#   - Magnitude: The vector magnitude determines movement distance
#     Example: [1.0, 0] = full step, [0.5, 0] = half step
#
# Normalization:
#   - Actions are normalized to unit length and scaled by magnitude fraction
#   - [1, 1] results in same distance as [0, 1] (200px max step)
#   - This prevents diagonal movement from being 41% longer
#
# Benefits over Discrete action space:
#   - Smooth, precise movement (no jittering between discrete directions)
#   - Natural representation for 2D continuous environments
#   - Enables nuanced positioning and trajectory control
#   - Works well with direction consistency rewards

ACTION_SPACE = gym.spaces.Box(
    low=-1.0,
    high=1.0,
    shape=(2,),
    dtype=np.float32
)

# ============================================================================
# AGENT CONFIGURATION
# ============================================================================
# Number of possible agents (RTS units)
MAX_AGENTS = 10000

# Agent ID format: "u{number}" (e.g., "u1", "u2", ..., "u1000")
POSSIBLE_AGENT_IDS = [f"u{i}" for i in range(1, MAX_AGENTS + 1)]

# ============================================================================
# NETWORK CONFIGURATION
# ============================================================================
# TCP connection settings for Godot <-> Python communication
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 5555
DEFAULT_TIMEOUT = 5.0  # Socket timeout in seconds

# ============================================================================
# POLICY CONFIGURATION
# ============================================================================
# Policies are now loaded dynamically from game/config/ai_policies.json
# See PolicyManager in ai/policy_manager.py for policy loading logic
# This eliminates the need for hardcoded policy names here

# ============================================================================
# TRAINING HYPERPARAMETERS
# ============================================================================
# Default PPO hyperparameters (can be overridden in training script)

# Learning rate - REDUCED from 3e-4 to 1e-4 for better convergence
# High entropy after 10+ hours suggests learning rate may be too high
LEARNING_RATE = 1e-5

# Entropy coefficient - controls exploration vs exploitation
# Lower values encourage more deterministic policies (less random exploration)
# For Box(2) continuous action space, 0.01 is standard (vs 0.1 for discrete)
ENTROPY_COEFF = 0.01

# Discount factor - how much to value future rewards
GAMMA = 0.99

# PPO clipping parameter - prevents large policy updates
CLIP_PARAM = 0.2

# Training batch size - total timesteps per iteration
TRAIN_BATCH_SIZE = 2000

# Minibatch size for SGD
MINIBATCH_SIZE = 500

# Number of SGD epochs per training iteration
NUM_EPOCHS = 10

# GAE (Generalized Advantage Estimation) parameters
USE_GAE = True
GAE_LAMBDA = 0.9

# Value function clipping
VF_CLIP_PARAM = 10.0

# ============================================================================
# NETWORK ARCHITECTURE
# ============================================================================
# Multi-layer perceptron configuration

# Hidden layer sizes - 3-layer network
# Larger network needed for 94D observation space vs previous 4D
FCNET_HIDDENS = [128, 256, 128]

# Activation function
FCNET_ACTIVATION = "tanh"

# Weight initialization
FCNET_WEIGHTS_INITIALIZER = "xavier_uniform_"
FCNET_BIAS_INITIALIZER = "zeros_"
