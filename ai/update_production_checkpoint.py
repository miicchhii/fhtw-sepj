#!/usr/bin/env python3
"""
Update production checkpoint from the latest training checkpoint.

Usage:
    python update_production_checkpoint.py           # Auto-detect latest, auto-increment version
    python update_production_checkpoint.py --checkpoint checkpoint_150  # Use specific checkpoint
    python update_production_checkpoint.py --git     # Also stage for git commit

This script:
1. Finds the latest training checkpoint (or uses specified one)
2. Auto-detects the next production version number (v01, v02, etc.)
3. Copies to both 'production' (latest) and 'production_vXX' (versioned)
"""

import argparse
import os
import re
import shutil
import subprocess
import sys


def find_latest_checkpoint(checkpoint_dir: str) -> str:
    """Find the latest numbered training checkpoint."""
    if not os.path.exists(checkpoint_dir):
        raise FileNotFoundError(f"Checkpoint directory not found: {checkpoint_dir}")

    checkpoints = [d for d in os.listdir(checkpoint_dir) if d.startswith("checkpoint_")]
    # Filter out non-numbered checkpoints (final, interrupted, etc.)
    numbered = [c for c in checkpoints if re.match(r"checkpoint_\d+$", c)]

    if not numbered:
        raise FileNotFoundError("No numbered checkpoints found")

    # Sort by number
    numbered.sort(key=lambda x: int(x.split("_")[1]))
    return numbered[-1]


def find_next_version(checkpoint_dir: str) -> int:
    """Find the next production version number."""
    existing = [d for d in os.listdir(checkpoint_dir) if d.startswith("production_v")]

    if not existing:
        return 1

    # Extract version numbers
    versions = []
    for name in existing:
        match = re.match(r"production_v(\d+)$", name)
        if match:
            versions.append(int(match.group(1)))

    if not versions:
        return 1

    return max(versions) + 1


def main():
    parser = argparse.ArgumentParser(
        description="Update production checkpoint from latest training checkpoint"
    )
    parser.add_argument(
        "--checkpoint", "-c",
        type=str,
        default=None,
        help="Specific checkpoint to use (e.g., checkpoint_150). Uses latest if not specified."
    )
    parser.add_argument(
        "--git",
        action="store_true",
        help="Stage files for git commit after copying"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be done without actually doing it"
    )
    args = parser.parse_args()

    # Setup paths
    script_dir = os.path.dirname(os.path.abspath(__file__))
    checkpoint_dir = os.path.join(script_dir, "checkpoints")

    # Find source checkpoint
    if args.checkpoint:
        source_name = args.checkpoint
        source_path = os.path.join(checkpoint_dir, source_name)
        if not os.path.exists(source_path):
            print(f"Error: Checkpoint not found: {source_path}")
            sys.exit(1)
    else:
        source_name = find_latest_checkpoint(checkpoint_dir)
        source_path = os.path.join(checkpoint_dir, source_name)

    # Find next version
    next_version = find_next_version(checkpoint_dir)
    version_name = f"production_v{next_version:02d}"

    # Target paths
    production_path = os.path.join(checkpoint_dir, "production")
    versioned_path = os.path.join(checkpoint_dir, version_name)

    print(f"Source checkpoint: {source_name}")
    print(f"New version: {version_name}")
    print(f"")
    print(f"Will copy to:")
    print(f"  - {production_path}")
    print(f"  - {versioned_path}")

    if args.dry_run:
        print("\n[Dry run - no changes made]")
        return

    # Confirm
    response = input("\nProceed? [y/N] ").strip().lower()
    if response != 'y':
        print("Aborted.")
        return

    # Remove old production if exists
    if os.path.exists(production_path):
        print(f"Removing old production checkpoint...")
        shutil.rmtree(production_path)

    # Copy to production (latest)
    print(f"Copying {source_name} -> production...")
    shutil.copytree(source_path, production_path)

    # Copy to versioned
    print(f"Copying {source_name} -> {version_name}...")
    shutil.copytree(source_path, versioned_path)

    print("\nCheckpoints updated successfully!")

    # Git operations
    if args.git:
        print("\nStaging for git...")
        repo_root = os.path.dirname(script_dir)

        # Stage both checkpoints
        subprocess.run(
            ["git", "add", "-f",
             f"ai/checkpoints/production",
             f"ai/checkpoints/{version_name}"],
            cwd=repo_root,
            check=True
        )

        print(f"\nFiles staged. To commit, run:")
        print(f'  git commit -m "Update production checkpoint to {version_name} ({source_name})"')
        print(f"  git push")


if __name__ == "__main__":
    main()
