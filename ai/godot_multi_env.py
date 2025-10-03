import gymnasium as gym
from gymnasium.spaces import Discrete, Box
from ray.rllib.env.multi_agent_env import MultiAgentEnv
import socket
import json
import time
import numpy as np
from typing import Dict, Any, Tuple, Optional

class GodotRTSMultiAgentEnv(MultiAgentEnv):
    """
    Multi-agent environment that connects to a single Godot RTS game instance via TCP socket.
    Uses Ray RLlib's new API stack with single worker configuration for stable training.
    Manages 20 RTS units as individual agents in a shared environment.
    """

    def __init__(self, env_config: Dict[str, Any]):
        super().__init__()
        self.host = env_config.get("host", "127.0.0.1")
        self.port = env_config.get("port", 5555)
        print(f"GodotRTSMultiAgentEnv: Connecting to Godot RTS game at {self.host}:{self.port}")
        self.timeout = env_config.get("timeout", 2.0)
        self.ep_horizon = env_config.get("ep_horizon", 50)
        self.step_len = env_config.get("step_len", 10.0)

        # Socket connection
        self.socket: Optional[socket.socket] = None
        self.connected = False

        # Agent tracking
        self.agents = set()
        self.possible_agents = [f"u{i}" for i in range(1, 1001)]  # Pre-define possible agents u1 to u100
        self.last_obs = {}

        # Episode tracking
        self.episode_step = 0
        self.episode_ended = False

        # Define spaces (these should match your actual observation/action spaces)
        # New observation space: base(4) + battle_stats(5) + closest_allies(10*4) + closest_enemies(10*4) = 89 values
        self.observation_space = Box(low=-1.0, high=10.0, shape=(89,), dtype=np.float32)  # Increased upper bound for distances
        self.action_space = Discrete(9)

        # Multi-agent spaces - initialize with possible agents
        self.observation_spaces = {}
        self.action_spaces = {}

        # Pre-populate spaces for all possible agents (required by new RLLib API)
        for agent_id in self.possible_agents:
            self.observation_spaces[agent_id] = self.observation_space
            self.action_spaces[agent_id] = self.action_space

        print(f"GodotRTSMultiAgentEnv initialized: {self.host}:{self.port}")
        print(f"Pre-defined possible agents: {self.possible_agents}")

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
            print(f"Connecting to Godot at {self.host}:{self.port}...")
            self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.socket.settimeout(self.timeout)
            self.socket.connect((self.host, self.port))
            self.connected = True
            print("Connected to Godot!")
            return True
        except Exception as e:
            print(f"Failed to connect to Godot: {e}")
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
            print(f"Error sending message: {e}")
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
            print(f"Error parsing JSON message: {e}")
            print(f"Problematic message: '{message_line[:100]}...'")
            # Clear buffer on JSON error and try to recover
            self._receive_buffer = ""
            return None
        except Exception as e:
            print(f"Error receiving message: {e}")
            self.connected = False
            return None

    def _wait_for_observation(self, timeout: float = 5.0) -> Optional[Dict[str, Any]]:
        """Wait specifically for an observation message"""
        start_time = time.time()
        while time.time() - start_time < timeout:
            msg = self._receive_message(timeout=0.5)
            if msg and msg.get("type") == "obs":
                return msg.get("data", {})
        print(f"Timeout waiting for observation after {timeout}s")
        return None

    def _extract_obs_and_agents(self, godot_obs: Dict[str, Any]) -> Tuple[Dict[str, np.ndarray], Dict[str, Dict]]:
        """Convert Godot observation to gym format"""
        observations = {}
        infos = {}

        units = godot_obs.get("units", [])
        map_info = godot_obs.get("map", {"w": 1024, "h": 768})

        # Track current agents from Godot
        current_agents = set()

        for unit in units:
            agent_id = unit.get("id", "")
            if not agent_id:
                continue

            current_agents.add(agent_id)

            # Convert unit data to normalized observation vector
            pos = unit.get("pos", [0, 0])
            hp_ratio = unit.get("hp", 1) / max(unit.get("max_hp", 1), 1)

            # Normalize position to [0, 1]
            norm_x = pos[0] / map_info["w"] if map_info["w"] > 0 else 0.5
            norm_y = pos[1] / map_info["h"] if map_info["h"] > 0 else 0.5

            # Distance to center (normalized)
            center_x, center_y = 0.5, 0.5
            dist_to_center = np.sqrt((norm_x - center_x)**2 + (norm_y - center_y)**2)

            # Build observation vector: base info + battle stats + closest allies + closest enemies
            obs_vector = [norm_x, norm_y, hp_ratio, dist_to_center]

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

            observations[agent_id] = np.array(obs_vector, dtype=np.float32)

            infos[agent_id] = {
                "raw_pos": pos,
                "hp": unit.get("hp", 1),
                "max_hp": unit.get("max_hp", 1),
                "episode_step": self.episode_step
            }

            # Update spaces
            self.observation_spaces[agent_id] = self.observation_space
            self.action_spaces[agent_id] = self.action_space

        # Handle dead agents - provide final observation for agents that disappeared
        dead_agents = self.agents - current_agents
        for dead_agent in dead_agents:
            # Give dead agent a zero observation (89 values total - indicating death)
            dead_obs = [0.0, 0.0, 0.0, 1.0]  # Base observation indicating death
            # Add 5 zeros for battle stats + 80 zeros for closest allies and enemies (10*4 + 10*4)
            dead_obs.extend([0.0] * 85)
            observations[dead_agent] = np.array(dead_obs, dtype=np.float32)
            infos[dead_agent] = {
                "raw_pos": [0, 0],
                "hp": 0,
                "max_hp": 100,
                "episode_step": self.episode_step,
                "dead": True
            }
            print(f"Agent {dead_agent} died - providing final observation")

        # Update agent set to include both current and dead agents for this step
        # This ensures dead agents get their final observation before being removed
        self.agents = current_agents | dead_agents

        return observations, infos

    def reset(self, seed: Optional[int] = None, options: Optional[Dict] = None) -> Tuple[Dict[str, np.ndarray], Dict[str, Dict]]:
        """Reset the environment"""
        super().reset(seed=seed)

        print("Resetting Godot environment...")

        # Reset episode tracking
        self.episode_step = 0
        self.episode_ended = False

        # Send reset command
        if not self._send_message({"type": "_ai_request_reset"}):
            raise RuntimeError("Failed to send reset command to Godot")

        # Wait for initial observation
        godot_obs = self._wait_for_observation(timeout=5.0)
        if godot_obs is None:
            raise RuntimeError("Failed to receive initial observation from Godot after reset")

        observations, infos = self._extract_obs_and_agents(godot_obs)
        self.last_obs = observations

        # Store map info for action conversion
        self.map_info = godot_obs.get("map", {"w": 1280, "h": 720})

        print(f"Reset complete. Agents: {list(self.agents)}")
        return observations, infos

    def step(self, actions: Dict[str, int]) -> Tuple[Dict[str, np.ndarray], Dict[str, float], Dict[str, bool], Dict[str, bool], Dict[str, Dict]]:
        """Step the environment"""
        if not self.connected:
            print("Connection lost, attempting to reconnect...")
            if not self._connect():
                raise RuntimeError("Not connected to Godot")

        # Track episode steps
        self.episode_step += 1

        # Convert actions to Godot format
        godot_actions = {}
        for agent_id, action in actions.items():
            if agent_id not in self.agents:
                continue

            # Convert discrete action to move command
            if isinstance(action, (np.integer, int)):
                action = int(action)
            else:
                action = 0  # Default action

            # Map action to movement
            moves = [
                [0, 0],    # 0: no move
                [-100, -100], [0, -100], [100, -100],  # 1,2,3: up-left, up, up-right
                [-100, 0],   [0, 0],   [100, 0],    # 4,5,6: left, stay, right
                [-100, 100],  [0, 100],  [100, 100]    # 7,8,9: down-left, down, down-right
            ]

            if 0 <= action < len(moves):
                # Get current position and add movement
                current_pos = self.last_obs.get(agent_id, np.array([0.5, 0.5, 1.0, 0.0]))
                # Convert normalized back to world coordinates using actual map size
                map_w = getattr(self, 'map_info', {"w": 1280, "h": 720})["w"]
                map_h = getattr(self, 'map_info', {"w": 1280, "h": 720})["h"]

                world_x = current_pos[0] * map_w
                world_y = current_pos[1] * map_h

                new_x = max(0, min(map_w, world_x + moves[action][0]))
                new_y = max(0, min(map_h, world_y + moves[action][1]))

                godot_actions[agent_id] = {"move": [new_x, new_y]}
            else:
                # Default to center using actual map size
                map_w = getattr(self, 'map_info', {"w": 1280, "h": 720})["w"]
                map_h = getattr(self, 'map_info', {"w": 1280, "h": 720})["h"]
                godot_actions[agent_id] = {"move": [map_w/2, map_h/2]}

        # Send actions with retry logic
        if not self._send_message({"type": "act", "actions": godot_actions}):
            print("Failed to send actions, attempting to reconnect...")
            if self._connect():
                if not self._send_message({"type": "act", "actions": godot_actions}):
                    raise RuntimeError("Failed to send actions to Godot after reconnect")
            else:
                raise RuntimeError("Failed to send actions to Godot")

        # Wait for observation
        godot_obs = self._wait_for_observation(timeout=3.0)
        if godot_obs is None:
            print("Failed to receive observation, connection may be lost")
            self.connected = False
            raise RuntimeError("Failed to receive observation after step")

        observations, infos = self._extract_obs_and_agents(godot_obs)
        self.last_obs = observations

        # Update map info for next action conversion
        self.map_info = godot_obs.get("map", {"w": 1280, "h": 720})

        # Wait for reward message
        reward_msg = None
        for attempt in range(3):
            reward_msg = self._receive_message(timeout=0.5)
            if reward_msg and reward_msg.get("type") == "reward":
                break

        if not reward_msg or reward_msg.get("type") != "reward":
            print("Warning: No reward message received")
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

                # Optional: Log significant combat rewards for debugging
                if abs(reward) > 1.0:  # Log rewards above normal positional range
                    print(f"Agent {agent_id} received significant reward: {reward:.2f}")

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
                print(f"Episode ended at step {self.episode_step}")

            # Remove dead agents from the active agent set for next step
            # But only after we've processed them for this step
            self.agents = self.agents - dead_agents_this_step
            if dead_agents_this_step:
                print(f"Removed dead agents from active set: {dead_agents_this_step}")

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
        print("Godot environment closed")