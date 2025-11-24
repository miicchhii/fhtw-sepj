"""
PolicyManager - Centralized AI policy configuration management

Loads policy definitions from config/ai_policies.json and provides
helper methods for accessing policy information, reward profiles,
and trainability settings.

This ensures Python training scripts and Godot game logic use the
same policy definitions from a single source of truth.
"""

import json
from pathlib import Path
from typing import Dict, List, Optional


class PolicyManager:
    """Manages AI policy configurations loaded from JSON"""

    def __init__(self, config_path: Optional[str] = None):
        """
        Initialize PolicyManager by loading configuration from JSON.

        Args:
            config_path: Path to ai_policies.json. If None, uses default location.
        """
        if config_path is None:
            # Default to game/config/ai_policies.json (shared with Godot)
            project_root = Path(__file__).parent.parent
            config_path = project_root / "game" / "config" / "ai_policies.json"

        self.config_path = Path(config_path)
        self.config = self._load_config()
        self.policies = self.config["policies"]
        self.default_policy = self.config.get("default_policy", "policy_baseline")

    def _load_config(self) -> Dict:
        """Load and parse the JSON configuration file"""
        if not self.config_path.exists():
            raise FileNotFoundError(
                f"Policy configuration not found: {self.config_path}\n"
                "Please create config/ai_policies.json"
            )

        with open(self.config_path, 'r') as f:
            config = json.load(f)

        # Validate required structure
        if "policies" not in config:
            raise ValueError("Invalid config: missing 'policies' key")

        return config

    def get_policy_ids(self) -> List[str]:
        """
        Get list of all policy IDs.

        Returns:
            List of policy ID strings (e.g., ['policy_aggressive_1', ...])
        """
        return list(self.policies.keys())

    def get_trainable_policies(self) -> List[str]:
        """
        Get list of policy IDs marked as trainable.

        Returns:
            List of trainable policy ID strings
        """
        return [
            policy_id
            for policy_id, config in self.policies.items()
            if config.get("trainable", True)
        ]

    def get_frozen_policies(self) -> List[str]:
        """
        Get list of policy IDs marked as non-trainable (frozen).

        Returns:
            List of frozen policy ID strings
        """
        return [
            policy_id
            for policy_id, config in self.policies.items()
            if not config.get("trainable", True)
        ]

    def get_reward_profile(self, policy_id: str) -> Dict[str, float]:
        """
        Get reward weight configuration for a specific policy.

        Args:
            policy_id: ID of the policy

        Returns:
            Dictionary mapping reward type to weight value

        Raises:
            KeyError: If policy_id doesn't exist
        """
        if policy_id not in self.policies:
            raise KeyError(f"Policy not found: {policy_id}")

        return self.policies[policy_id]["reward_profile"]

    def get_display_name(self, policy_id: str) -> str:
        """
        Get human-readable display name for a policy.

        Args:
            policy_id: ID of the policy

        Returns:
            Display name string (e.g., "Aggressive Alpha")

        Raises:
            KeyError: If policy_id doesn't exist
        """
        if policy_id not in self.policies:
            raise KeyError(f"Policy not found: {policy_id}")

        return self.policies[policy_id].get("display_name", policy_id)

    def get_description(self, policy_id: str) -> str:
        """
        Get description of a policy's behavior.

        Args:
            policy_id: ID of the policy

        Returns:
            Description string

        Raises:
            KeyError: If policy_id doesn't exist
        """
        if policy_id not in self.policies:
            raise KeyError(f"Policy not found: {policy_id}")

        return self.policies[policy_id].get("description", "")

    def is_trainable(self, policy_id: str) -> bool:
        """
        Check if a policy is trainable.

        Args:
            policy_id: ID of the policy

        Returns:
            True if trainable, False if frozen

        Raises:
            KeyError: If policy_id doesn't exist
        """
        if policy_id not in self.policies:
            raise KeyError(f"Policy not found: {policy_id}")

        return self.policies[policy_id].get("trainable", True)

    def get_policy_config(self, policy_id: str) -> Dict:
        """
        Get complete configuration for a policy.

        Args:
            policy_id: ID of the policy

        Returns:
            Complete policy configuration dictionary

        Raises:
            KeyError: If policy_id doesn't exist
        """
        if policy_id not in self.policies:
            raise KeyError(f"Policy not found: {policy_id}")

        return self.policies[policy_id]

    def get_network_config(self, policy_id: str) -> Dict:
        """
        Get neural network configuration for a policy.

        Args:
            policy_id: ID of the policy

        Returns:
            Dictionary with network config (fcnet_hiddens, fcnet_activation, etc.)

        Raises:
            KeyError: If policy_id doesn't exist
        """
        if policy_id not in self.policies:
            raise KeyError(f"Policy not found: {policy_id}")

        return self.policies[policy_id].get("network_config", {})

    def print_summary(self) -> None:
        """Print a summary of all configured policies"""
        print(f"\n=== Policy Configuration Summary ===")
        print(f"Config file: {self.config_path}")
        print(f"Default policy: {self.default_policy}")
        print(f"\nTotal policies: {len(self.policies)}")
        print(f"Trainable: {len(self.get_trainable_policies())}")
        print(f"Frozen: {len(self.get_frozen_policies())}")

        print("\n--- Policy Details ---")
        for policy_id in self.get_policy_ids():
            config = self.policies[policy_id]
            trainable = "TRAIN" if config.get("trainable", True) else "FROZEN"
            print(f"\n{policy_id} [{trainable}]")
            print(f"  Name: {config.get('display_name', 'N/A')}")
            print(f"  Desc: {config.get('description', 'N/A')}")


# Convenience function for quick access
def load_policy_manager() -> PolicyManager:
    """Load and return a PolicyManager instance with default config path"""
    return PolicyManager()


if __name__ == "__main__":
    # Test the policy manager
    pm = load_policy_manager()
    pm.print_summary()

    print("\n--- Reward Profile Example ---")
    print("policy_aggressive_1 rewards:")
    for key, value in pm.get_reward_profile("policy_aggressive_1").items():
        print(f"  {key}: {value}")
