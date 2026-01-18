import gymnasium as gym
from gymnasium.spaces import Discrete, Box
from ray.rllib.env.multi_agent_env import MultiAgentEnv
import socket
import json
import time
import numpy as np
import csv
import os
from datetime import datetime
from typing import Dict, Any, Tuple, Optional

# Import central configuration
from rts_config import (
    OBSERVATION_SPACE,
    ACTION_SPACE,
    POSSIBLE_AGENT_IDS,
    DEFAULT_HOST,
    DEFAULT_PORT,
    DEFAULT_TIMEOUT
)

class GodotRTSMultiAgentEnv(MultiAgentEnv):
    """
    Multi-agent RTS environment bridge between Godot game and Ray RLlib.

    Connects to a Godot game instance via TCP socket (JSON protocol) and manages
    up to 100 RTS units as individual RL agents across multiple policies.

    Features:
    - Dynamic policy assignment: Units send policy_id in observations
    - 94-dimensional observations: velocity, HP, battle stats, nearby units, POIs
    - Continuous 2D action space: [dx, dy] movement vectors in range [-1, 1]
    - Episode management: Automatic reset after max steps or victory/defeat
    - Position-invariant learning: Velocity-based observations prevent position-specific strategies
    """

    # Class-level shared dicts for policy mapping - NEVER replaced, only updated in place
    # This ensures policy_mapping_fn always reads from the same dict regardless of which
    # environment instance last updated it
    _agent_to_policy_global = {}  # Maps agent_id -> policy_id from Godot observations
    _last_policy_mapping = {}     # Maps agent_id -> policy_id returned by policy_mapping_fn

    def __init__(self, env_config: Dict[str, Any]):
        super().__init__()
        # Verbosity settings
        self.verbose = env_config.get("verbose", False)
        self.quiet = env_config.get("quiet", False)

        # TCP connection configuration (use central config defaults)
        self.host = env_config.get("host", DEFAULT_HOST)
        self.port = env_config.get("port", DEFAULT_PORT)
        self.timeout = env_config.get("timeout", DEFAULT_TIMEOUT)
        self._log(f"GodotRTSMultiAgentEnv: Connecting to Godot RTS game at {self.host}:{self.port}")

        # Socket state
        self.socket: Optional[socket.socket] = None
        self.connected = False

        # Agent tracking (uses POSSIBLE_AGENT_IDS from central config)
        self.agents = set()  # Currently active agents in this episode
        self.possible_agents = POSSIBLE_AGENT_IDS  # All possible unit IDs from config
        self.last_obs = {}  # Cache of last observation for each agent
        self._done_agents = set()  # Agents marked as done this episode (can't receive more data)

        # Multi-policy support: Point to class-level shared dict
        # All instances share the same dict so policy_mapping_fn always sees latest data
        self.agent_to_policy = GodotRTSMultiAgentEnv._agent_to_policy_global

        # Episode state
        self.episode_step = 0
        self.episode_ended = False
        self._soft_reset_pending = False  # If True, next reset() preserves game state
        self.inference_mode = env_config.get("inference_mode", False)
        self.training_mode = not self.inference_mode  # True for training, False for inference

        # Episode summary logging - write directly to CSV
        self.last_episode_summary = None  # Filled when episode ends
        self._episode_log_path = self._init_episode_log()

        # Observation and action spaces (imported from central config)
        # See rts_config.py for detailed space documentation
        self.observation_space = OBSERVATION_SPACE
        self.action_space = ACTION_SPACE

        # Multi-agent spaces - initialize with possible agents
        self.observation_spaces = {}
        self.action_spaces = {}

        # Pre-populate spaces for all possible agents (required by new RLLib API)
        for agent_id in self.possible_agents:
            self.observation_spaces[agent_id] = self.observation_space
            self.action_spaces[agent_id] = self.action_space

        self._log(f"GodotRTSMultiAgentEnv initialized: {self.host}:{self.port}")
        self._log(f"Observation space: {self.observation_space}", level="debug")
        self._log(f"Action space: {self.action_space}", level="debug")
        self._log(f"Pre-defined possible agents: {len(self.possible_agents)} agents", level="debug")

    def _log(self, msg: str, level: str = "normal"):
        """Print message based on verbosity level.

        Levels:
        - "debug": Only shown with verbose=True
        - "normal": Shown unless quiet=True
        - "important": Always shown (errors, checkpoints)
        """
        if level == "debug" and not self.verbose:
            return
        if level == "normal" and self.quiet:
            return
        print(msg)

    def get_agent_ids(self):
        """Return current active agent IDs"""
        return list(self.agents)

    @property
    def _agent_ids(self):
        """Property required by some RLLib versions"""
        return list(self.agents)

    def observation_space_for_agent(self, agent_id: str):
        """Return observation space for a specific agent"""
        return self.observation_space

    def action_space_for_agent(self, agent_id: str):
        """Return action space for a specific agent"""
        return self.action_space

    def _connect(self) -> bool:
        """Establish connection to Godot server"""
        if self.connected:
            return True

        try:
            self._log(f"Connecting to Godot at {self.host}:{self.port}...", level="debug")
            self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.socket.settimeout(self.timeout)
            self.socket.connect((self.host, self.port))
            self.connected = True
            self._log("Connected to Godot!")
            return True
        except Exception as e:
            self._log(f"Failed to connect to Godot: {e}", level="important")
            self.socket = None
            self.connected = False
            return False

    def _send_message(self, msg: Dict[str, Any]) -> bool:
        """Send a JSON message to Godot"""
        if not self.connected:
            if not self._connect():
                return False

        try:
            # Convert numpy types to native Python types for JSON serialization
            def convert_numpy_types(obj):
                if isinstance(obj, np.integer):
                    return int(obj)
                elif isinstance(obj, np.floating):
                    return float(obj)
                elif isinstance(obj, np.ndarray):
                    return obj.tolist()
                elif isinstance(obj, dict):
                    return {k: convert_numpy_types(v) for k, v in obj.items()}
                elif isinstance(obj, list):
                    return [convert_numpy_types(v) for v in obj]
                else:
                    return obj

            converted_msg = convert_numpy_types(msg)
            line = json.dumps(converted_msg) + "\n"
            self.socket.send(line.encode('utf-8'))
            return True
        except Exception as e:
            self._log(f"Error sending message: {e}", level="important")
            self.connected = False
            return False

    def _receive_message(self, timeout: Optional[float] = None) -> Optional[Dict[str, Any]]:
        """Receive a JSON message from Godot"""
        if not self.connected:
            return None

        try:
            if timeout:
                self.socket.settimeout(timeout)
            else:
                self.socket.settimeout(self.timeout)

            # Initialize or use existing buffer
            if not hasattr(self, '_receive_buffer'):
                self._receive_buffer = ""

            # Read data and accumulate in buffer
            while '\n' not in self._receive_buffer:
                chunk = self.socket.recv(1024).decode('utf-8')
                if not chunk:
                    # Connection closed
                    self.connected = False
                    return None
                self._receive_buffer += chunk

            # Extract the first complete message
            lines = self._receive_buffer.split('\n', 1)
            if len(lines) < 2:
                return None

            message_line = lines[0].strip()
            # Keep remaining data for next message
            self._receive_buffer = lines[1] if len(lines) > 1 else ""

            if not message_line:
                # Empty line, try again
                return self._receive_message(timeout)

            return json.loads(message_line)

        except socket.timeout:
            return None
        except json.JSONDecodeError as e:
            self._log(f"Error parsing JSON message: {e}", level="important")
            self._log(f"Problematic message: '{message_line[:100]}...'", level="debug")
            # Clear buffer on JSON error and try to recover
            self._receive_buffer = ""
            return None
        except Exception as e:
            self._log(f"Error receiving message: {e}", level="important")
            self.connected = False
            return None

    def _wait_for_observation(self, timeout: float = 5.0) -> Optional[Dict[str, Any]]:
        """Wait specifically for an observation message"""
        start_time = time.time()
        while time.time() - start_time < timeout:
            msg = self._receive_message(timeout=0.5)
            if msg and msg.get("type") == "obs":
                return msg.get("data", {})
        self._log(f"Timeout waiting for observation after {timeout}s", level="important")
        return None

    def _extract_obs_and_agents(self, godot_obs: Dict[str, Any]) -> Tuple[Dict[str, np.ndarray], Dict[str, Dict]]:
        """
        Convert Godot observation message to RLlib format.

        Transforms raw Godot unit data into normalized 94-dimensional observation vectors
        and extracts policy assignments for dynamic multi-policy support.

        Observation structure (94 dimensions):
        - Base (3): vel_x, vel_y, hp_ratio
        - Battle stats (5): attack_range, attack_damage, attack_cooldown, cooldown_remaining, speed
        - Closest allies (40): 10 × (direction_x, direction_y, distance, hp_ratio)
        - Closest enemies (40): 10 × (direction_x, direction_y, distance, hp_ratio)
        - Points of interest (6): 2 POIs × (direction_x, direction_y, distance)

        Args:
            godot_obs: Raw observation from Godot containing units list and map info

        Returns:
            Tuple of (observations dict, infos dict) where both are keyed by agent_id
        """
        observations = {}
        infos = {}

        units = godot_obs.get("units", [])

        # Map info - use defaults if not provided (shouldn't happen but be resilient)
        if "map" not in godot_obs:
            self._log("Warning: Map dimensions not provided by Godot, using defaults", level="debug")
            map_info = {"w": 2560, "h": 1440}
        else:
            map_info = godot_obs["map"]

        if "w" not in map_info or "h" not in map_info:
            self._log(f"Warning: Invalid map info from Godot: {map_info}, using defaults", level="debug")
            map_info = {"w": 2560, "h": 1440}

        # Track which agents are alive in this observation
        current_agents = set()

        for unit in units:
            try:
                agent_id = unit.get("id", "")
                if not agent_id:
                    continue

                # Skip agents that are already marked as done (prevents RLlib error)
                # This can happen if Godot spawns new units with IDs > 100 mid-episode
                if agent_id in self._done_agents:
                    continue

                current_agents.add(agent_id)

                # Extract and store policy assignment from Godot
                # This enables dynamic policy switching - unit can change policy via set_policy()
                policy_id = unit.get("policy_id", "policy_baseline")
                self.agent_to_policy[agent_id] = policy_id
                # Note: self.agent_to_policy IS the class-level _agent_to_policy_global dict
                # Updates here are automatically visible to policy_mapping_fn

                # Convert unit data to normalized observation vector
                velocity = unit.get("velocity", [0.0, 0.0])
                if not isinstance(velocity, (list, tuple)) or len(velocity) < 2:
                    velocity = [0.0, 0.0]
                hp_ratio = unit.get("hp", 1) / max(unit.get("max_hp", 1), 1)

                # Normalize velocity by max expected speed (around 100 pixels/second)
                max_speed = 100.0
                norm_vel_x = velocity[0] / max_speed
                norm_vel_y = velocity[1] / max_speed

                # Build observation vector: velocity + hp + battle stats + closest allies + closest enemies + POIs
                obs_vector = [norm_vel_x, norm_vel_y, hp_ratio]

                # Add battle stats (normalized)
                attack_range = unit.get("attack_range", 64.0)
                attack_damage = unit.get("attack_damage", 15.0)
                attack_cooldown = unit.get("attack_cooldown", 0.8)
                attack_cooldown_remaining = unit.get("attack_cooldown_remaining", 0.0)
                speed = unit.get("speed", 50.0)

                # Normalize battle stats for better learning
                norm_attack_range = attack_range / 200.0  # Max expected range around 200
                norm_attack_damage = attack_damage / 50.0  # Max expected damage around 50
                norm_attack_cooldown = attack_cooldown / 2.0  # Max expected cooldown around 2s
                norm_cooldown_remaining = attack_cooldown_remaining / 2.0  # Same as cooldown
                norm_speed = speed / 100.0  # Max expected speed around 100

                obs_vector.extend([norm_attack_range, norm_attack_damage, norm_attack_cooldown,
                                 norm_cooldown_remaining, norm_speed])

                # Process closest allies (10 units, 4 values each)
                closest_allies = unit.get("closest_allies", [])
                max_distance = np.sqrt(map_info["w"]**2 + map_info["h"]**2)
                for ally_data in closest_allies:
                    direction = ally_data.get("direction", [0.0, 0.0])
                    distance = ally_data.get("distance", 0.0)
                    ally_hp_ratio = ally_data.get("hp_ratio", 0.0)

                    # Normalize distance by map diagonal for better scaling
                    norm_distance = distance / max_distance if max_distance > 0 else 0.0

                    obs_vector.extend([direction[0], direction[1], norm_distance, ally_hp_ratio])

                # Process closest enemies (10 units, 4 values each)
                closest_enemies = unit.get("closest_enemies", [])
                for enemy_data in closest_enemies:
                    direction = enemy_data.get("direction", [0.0, 0.0])
                    distance = enemy_data.get("distance", 0.0)
                    enemy_hp_ratio = enemy_data.get("hp_ratio", 0.0)

                    # Normalize distance by map diagonal for better scaling
                    norm_distance = distance / max_distance if max_distance > 0 else 0.0

                    obs_vector.extend([direction[0], direction[1], norm_distance, enemy_hp_ratio])

                # Process points of interest (POIs) - e.g., map center, control points
                pois = unit.get("points_of_interest", [])

                # Ensure we have exactly 2 POIs (enemy base and own base)
                expected_poi_count = 2
                for i in range(expected_poi_count):
                    if i < len(pois):
                        poi_data = pois[i]
                        direction = poi_data.get("direction", [0.0, 0.0])
                        distance = poi_data.get("distance", 0.0)

                        # Normalize distance by map diagonal
                        norm_distance = distance / max_distance if max_distance > 0 else 0.0

                        obs_vector.extend([direction[0], direction[1], norm_distance])
                    else:
                        # Pad with zeros if POI not provided
                        obs_vector.extend([0.0, 0.0, 0.0])

                # Validate observation size
                expected_size = 94
                if len(obs_vector) != expected_size:
                    self._log(f"Warning: Agent {agent_id} observation size mismatch: got {len(obs_vector)}, expected {expected_size}", level="debug")
                    # Pad or truncate to expected size
                    if len(obs_vector) < expected_size:
                        obs_vector.extend([0.0] * (expected_size - len(obs_vector)))
                    else:
                        obs_vector = obs_vector[:expected_size]

                observations[agent_id] = np.array(obs_vector, dtype=np.float32)

                infos[agent_id] = {
                    "velocity": velocity,
                    "hp": unit.get("hp", 1),
                    "max_hp": unit.get("max_hp", 1),
                    "episode_step": self.episode_step,
                    "policy_id": policy_id  # Include policy ID in info
                }

                # Update spaces
                self.observation_spaces[agent_id] = self.observation_space
                self.action_spaces[agent_id] = self.action_space

            except Exception as e:
                self._log(f"Warning: Failed to process unit {unit.get('id', 'unknown')}: {e}", level="debug")
                # Skip this agent but continue processing others

        # Handle dead agents - provide final observation for agents that disappeared
        dead_agents = self.agents - current_agents
        for dead_agent in dead_agents:
            # Give dead agent a zero observation (94 values total - indicating death)
            # Structure: 3 (base: vel_x, vel_y, hp) + 5 (battle) + 40 (allies) + 40 (enemies) + 6 (2 POIs) = 94
            dead_obs = [0.0, 0.0, 0.0]  # Base: zero velocity, zero hp
            # Add zeros for: 5 (battle stats) + 40 (allies) + 40 (enemies) + 6 (POIs) = 91
            dead_obs.extend([0.0] * 91)

            # Validate dead observation size
            if len(dead_obs) != 94:
                raise ValueError(f"Dead agent {dead_agent} observation size mismatch: got {len(dead_obs)}, expected 94")

            observations[dead_agent] = np.array(dead_obs, dtype=np.float32)
            infos[dead_agent] = {
                "velocity": [0.0, 0.0],
                "hp": 0,
                "max_hp": 100,
                "episode_step": self.episode_step,
                "dead": True
            }
            self._log(f"Agent {dead_agent} died - providing final observation", level="debug")

        # Update agent set to include both current and dead agents for this step
        # This ensures dead agents get their final observation before being removed
        self.agents = current_agents | dead_agents

        return observations, infos

    def reset(self, seed: Optional[int] = None, options: Optional[Dict] = None, soft: bool = False) -> Tuple[Dict[str, np.ndarray], Dict[str, Dict]]:
        """Reset the environment

        Args:
            seed: Random seed (unused)
            options: Additional options (unused)
            soft: If True, request current observation without resetting game state.
                  Useful for polling when waiting for units to spawn.
        """
        super().reset(seed=seed)

        # Reset episode tracking
        self.episode_step = 0
        self.episode_ended = False
        self._done_agents = set()  # Clear done agents on new episode
        self._episode_start_time = datetime.now()  # Track episode start for CSV logging

        # Check if this should be a soft reset (preserve game state)
        if self._soft_reset_pending or soft:
            if not soft:  # Only print and clear flag for internally triggered soft resets
                self._log("Performing soft reset (game state preserved, new policy mappings)", level="debug")
            self._soft_reset_pending = False
            # Request current observation without resetting game
            if not self._send_message({"type": "_ai_request_observation", "training_mode": self.training_mode}):
                raise RuntimeError("Failed to request observation from Godot")
        else:
            self._log("Resetting Godot environment...", level="debug")
            # Full reset - respawn units, reset bases
            # training_mode controls matchup rotation and unit spawning in Godot
            if not self._send_message({"type": "_ai_request_reset", "training_mode": self.training_mode}):
                raise RuntimeError("Failed to send reset command to Godot")

        # Wait for initial observation
        godot_obs = self._wait_for_observation(timeout=5.0)
        if godot_obs is None:
            raise RuntimeError("Failed to receive initial observation from Godot after reset")

        observations, infos = self._extract_obs_and_agents(godot_obs)
        self.last_obs = observations

        self._log(f"Reset complete. Agents: {len(self.agents)} active", level="debug")
        return observations, infos

    def step(self, actions: Dict[str, np.ndarray]) -> Tuple[Dict[str, np.ndarray], Dict[str, float], Dict[str, bool], Dict[str, bool], Dict[str, Dict]]:
        """Step the environment with continuous actions"""
        if not self.connected:
            self._log("Connection lost, attempting to reconnect...", level="important")
            if not self._connect():
                raise RuntimeError("Not connected to Godot")

        # Track episode steps
        self.episode_step += 1

        # Convert continuous actions to Godot format
        godot_actions = {}
        for agent_id, action in actions.items():
            try:
                if agent_id not in self.agents:
                    continue

                # Ensure action is a numpy array with 2 elements [dx, dy]
                if isinstance(action, np.ndarray):
                    action_array = action.flatten()
                elif isinstance(action, (list, tuple)):
                    action_array = np.array(action, dtype=np.float32)
                else:
                    action_array = np.array([0.0, 0.0], dtype=np.float32)

                if len(action_array) < 2:
                    action_array = np.array([0.0, 0.0], dtype=np.float32)

                # Extract movement vector (range [-1, 1]) with NaN/Inf protection
                dx = float(action_array[0])
                dy = float(action_array[1])

                # Protect against NaN or Inf values
                if not np.isfinite(dx):
                    dx = 0.0
                if not np.isfinite(dy):
                    dy = 0.0

                # Send the raw movement vector to Godot
                # Godot will handle scaling and calculating absolute target position
                godot_actions[agent_id] = {"move_vector": [dx, dy]}
            except Exception as e:
                self._log(f"Warning: Failed to process action for agent {agent_id}: {e}", level="debug")
                # Skip this agent's action

        # Send actions with retry logic
        if not self._send_message({"type": "act", "actions": godot_actions}):
            self._log("Failed to send actions, attempting to reconnect...", level="important")
            if self._connect():
                if not self._send_message({"type": "act", "actions": godot_actions}):
                    raise RuntimeError("Failed to send actions to Godot after reconnect")
            else:
                raise RuntimeError("Failed to send actions to Godot")

        # Wait for observation
        godot_obs = self._wait_for_observation(timeout=3.0)
        if godot_obs is None:
            self._log("Failed to receive observation, connection may be lost", level="important")
            self.connected = False
            raise RuntimeError("Failed to receive observation after step")

        # Check if Godot signaled a policy change (requires episode reset)
        if godot_obs.get("policy_changed", False):
            self._log("Policy change detected via UI - soft episode reset (game state preserved)", level="debug")
            # Set flag so next reset() does a soft reset (no game state change)
            self._soft_reset_pending = True
            # Extract observations first so we have valid data to return
            observations, infos = self._extract_obs_and_agents(godot_obs)
            self.last_obs = observations
            # Return truncated=True for all agents to signal episode end
            # RLlib will call reset() which starts a new episode with correct policy mappings
            rewards = {agent_id: 0.0 for agent_id in self.agents}
            terminateds = {agent_id: False for agent_id in self.agents}
            truncateds = {agent_id: True for agent_id in self.agents}
            terminateds["__all__"] = False
            truncateds["__all__"] = True
            self.episode_ended = True
            # Mark all agents as done to prevent straggler data
            self._done_agents.update(self.agents)
            return observations, rewards, terminateds, truncateds, infos

        observations, infos = self._extract_obs_and_agents(godot_obs)
        self.last_obs = observations

        # Wait for reward message
        reward_msg = None
        for attempt in range(3):
            reward_msg = self._receive_message(timeout=0.5)
            if reward_msg and reward_msg.get("type") == "reward":
                break

        if not reward_msg or reward_msg.get("type") != "reward":
            self._log("Warning: No reward message received", level="debug")
            # Default values if no reward message
            rewards = {agent_id: 0.0 for agent_id in self.agents}
            terminateds = {agent_id: False for agent_id in self.agents}
            truncateds = {agent_id: False for agent_id in self.agents}
            terminateds["__all__"] = False
            truncateds["__all__"] = False
        else:
            # Extract rewards and done flags
            agent_rewards = reward_msg.get("rewards", {})
            done_flags = reward_msg.get("dones", {})
            global_done = reward_msg.get("done", False)

            # Extract episode summary if present (sent when episode ends)
            episode_summary = reward_msg.get("episode_summary", None)
            if episode_summary:
                self.last_episode_summary = episode_summary
                # Log to CSV file
                self._log_episode_summary(episode_summary)

            # DEBUG: Log detailed reward message info
            # print(f"Step {self.episode_step}: Received reward message: {reward_msg}")
            # print(f"Step {self.episode_step}: Extracted - rewards: {agent_rewards}, done_flags: {done_flags}, global_done: {global_done}")

            # Use the actual per-agent rewards
            rewards = {}
            terminateds = {}
            truncateds = {}

            # Track agents that died this step
            dead_agents_this_step = set()
            for agent_id in self.agents:
                if agent_id in infos and infos[agent_id].get("dead", False):
                    dead_agents_this_step.add(agent_id)

            for agent_id in self.agents:
                # Use the actual reward for each agent
                reward = float(agent_rewards.get(agent_id, 0.0))
                rewards[agent_id] = reward

                # Optional: Log significant combat rewards for debugging (skip in inference mode)
                if not self.inference_mode and abs(reward) > 3.0:
                    # Show the policy that was actually used by policy_mapping_fn
                    actual_policy = getattr(GodotRTSMultiAgentEnv, '_last_policy_mapping', {}).get(agent_id, "unknown")
                    expected_policy = self.agent_to_policy.get(agent_id, "unknown")

                    # Note: A mismatch here is expected when policy changes mid-episode
                    # actual_policy = policy used for THIS step's action (from previous observation)
                    # expected_policy = policy from CURRENT observation (will be used next step)
                    if actual_policy != expected_policy and actual_policy != "unknown":
                        self._log(f"Agent {agent_id} policy change pending: {actual_policy} -> {expected_policy} (reward: {reward:.2f})", level="debug")
                    else:
                        self._log(f"Agent {agent_id} ({actual_policy}) received significant reward: {reward:.2f}", level="debug")

                # Mark dead agents as terminated (not truncated)
                if agent_id in dead_agents_this_step:
                    terminateds[agent_id] = True
                    truncateds[agent_id] = False
                else:
                    # Living agents don't terminate individually
                    terminateds[agent_id] = False
                    # But they do get truncated when episode ends
                    truncateds[agent_id] = global_done

            # CRITICAL: Set global episode end flags correctly
            # __all__ indicates the entire episode is done
            terminateds["__all__"] = False  # We're using truncation for episode ends
            truncateds["__all__"] = global_done  # Episode ends via truncation

            # Mark episode as ended
            if global_done:
                self.episode_ended = True
                self._log(f"Episode ended at step {self.episode_step}")

            # Remove dead agents from the active agent set for next step
            # But only after we've processed them for this step
            self.agents = self.agents - dead_agents_this_step
            if dead_agents_this_step:
                self._log(f"Removed dead agents from active set: {dead_agents_this_step}", level="debug")
                # Add dead agents to done set - they can't receive more data this episode
                self._done_agents.update(dead_agents_this_step)

            # When episode ends, mark ALL current agents as done
            # This prevents any straggler observations from causing errors
            if global_done:
                self._done_agents.update(self.agents)

            # DEBUG: Log final termination/truncation states
            # print(f"Step {self.episode_step}: Final states - terminateds: {terminateds}, truncateds: {truncateds}")

        return observations, rewards, terminateds, truncateds, infos

    def close(self):
        """Close the environment"""
        if self.socket:
            try:
                self.socket.close()
            except:
                pass
        self.socket = None
        self.connected = False
        # Clear receive buffer
        if hasattr(self, '_receive_buffer'):
            self._receive_buffer = ""
        self._log("Godot environment closed")

    def _init_episode_log(self) -> str:
        """Initialize episode statistics CSV log file."""
        log_dir = os.path.join(os.path.dirname(__file__), "logs")
        os.makedirs(log_dir, exist_ok=True)

        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        log_path = os.path.join(log_dir, f"episode_stats_{timestamp}.csv")

        # Write CSV header
        headers = [
            "timestamp_started",
            "timestamp_ended",
            "tick_ended",
            "ally_policy",
            "enemy_policy",
            "ally_damage_to_units",
            "enemy_damage_to_units",
            "ally_damage_to_base",
            "enemy_damage_to_base",
            "outcome",
            "ally_units_left",
            "enemy_units_left"
        ]

        with open(log_path, 'w', newline='') as f:
            writer = csv.writer(f)
            writer.writerow(headers)

        self._log(f"Episode stats will be logged to: {log_path}")
        return log_path

    def _log_episode_summary(self, summary: dict):
        """Write episode summary to CSV file."""
        try:
            # Get timestamps
            episode_start = getattr(self, '_episode_start_time', None)
            episode_end = datetime.now()

            row = [
                episode_start.isoformat() if episode_start else "",
                episode_end.isoformat(),
                summary.get("episode_steps", self.episode_step),  # tick_ended
                summary.get("ally_policy", ""),
                summary.get("enemy_policy", ""),
                summary.get("ally_damage_to_units", 0),
                summary.get("enemy_damage_to_units", 0),
                summary.get("ally_damage_to_base", 0),
                summary.get("enemy_damage_to_base", 0),
                summary.get("outcome", ""),
                summary.get("ally_units_left", 0),
                summary.get("enemy_units_left", 0)
            ]

            with open(self._episode_log_path, 'a', newline='') as f:
                writer = csv.writer(f)
                writer.writerow(row)

        except Exception as e:
            self._log(f"Warning: Failed to log episode summary: {e}", level="important")