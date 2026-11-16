#!/usr/bin/env python3
"""Verify network snapshots without signing transactions."""
import argparse
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]


def check_network(directory):
    root, uri = subprocess.check_output([
        "bash", "-euc",
        'source "$1"; params_require_values "$2" GENESIS_AIRDROP_MERKLE_ROOT GENESIS_AIRDROP_SNAPSHOT_URI; '
        'params_unset_all "$2"; params_load "$2"; '
        'printf "%s\\n%s" "$GENESIS_AIRDROP_MERKLE_ROOT" "$GENESIS_AIRDROP_SNAPSHOT_URI"',
        "bash", str(ROOT / "script/deploy/params.sh"), str(directory / "core.params"),
    ], text=True, stderr=subprocess.PIPE).splitlines()
    root = root.lower()
    url = urlparse(uri)
    filename = Path(url.path).name
    if not re.fullmatch(r"0x[0-9a-f]{64}", root):
        raise ValueError("Invalid genesis Merkle root")
    if url.path != f"/core/script/network/{directory.name}/{filename}":
        raise ValueError("Genesis snapshot URI must point to this network's snapshot file")
    if url.scheme != "https" or not url.netloc or len(uri.encode()) > 256:
        raise ValueError("Genesis snapshot URI must be HTTPS and at most 256 bytes")
    snapshots = sorted(directory.glob("airdrop*.json"))
    if directory / filename not in snapshots:
        raise ValueError(f"Missing snapshot: {directory.name}/{filename}")
    for path in snapshots:
        snapshot = json.loads(path.read_text())
        snapshot_root = root if path.name == filename else snapshot["merkleRoot"].lower()
        subprocess.run([
            "forge", "script", "script/deploy/CheckSnapshot.s.sol:CheckSnapshot",
            "--sig", "run(string,bytes32)", str(path), snapshot_root,
        ], cwd=ROOT, check=True, capture_output=True, text=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("network", nargs="?")
    args = parser.parse_args()
    directories = ([ROOT / "script/network" / args.network] if args.network else
                   sorted(path.parent for path in (ROOT / "script/network").glob("*/core.params")))
    try:
        for directory in directories:
            check_network(directory)
            print(f"Verified network snapshots: {directory.name}")
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError):
            parser.exit(1, f"Network check failed ({directory.name}):\n{error.stdout or ''}{error.stderr or ''}")
        parser.exit(1, f"Network check failed ({directory.name}): {error}\n")
