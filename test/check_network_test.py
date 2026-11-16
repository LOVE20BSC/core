#!/usr/bin/env python3
"""Reject corrupted network snapshots before deployment or publication."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("check_network", ROOT / "script/check_network.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class PublicNetworkTest(unittest.TestCase):
    def test_rejects_invalid_snapshot(self):
        temporary_root = ROOT / "script/network/.check-network-tests"
        temporary_root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=temporary_root) as temporary:
            network = Path(temporary)
            source = ROOT / "script/network/anvil31337_dev"
            for path in source.iterdir():
                if path.name != ".account":
                    shutil.copyfile(path, network / path.name)
            config = network / "core.params"
            config.write_text(config.read_text().replace("/anvil31337_dev/", f"/{network.name}/"))
            checker.check_network(network)
            snapshot_path = network / "airdrop.json"
            snapshot = json.loads(snapshot_path.read_text())
            snapshot_path.write_text(json.dumps({**snapshot, "merkleRoot": "0x" + "11" * 32}))
            with self.assertRaises(subprocess.CalledProcessError):
                checker.check_network(network)

            # A corrupt fixture left under the test directory must not enter normal network discovery.
            subprocess.run([sys.executable, str(ROOT / "script/check_network.py")],
                           cwd=ROOT, check=True, capture_output=True, text=True)
            snapshot_path.write_text(json.dumps({**snapshot, "accountCount": "1"}))
            with self.assertRaises(subprocess.CalledProcessError):
                checker.check_network(network)
            duplicate = {**snapshot, "entries": [snapshot["entries"][0]] * len(snapshot["entries"])}
            snapshot_path.write_text(json.dumps(duplicate))
            with self.assertRaises(subprocess.CalledProcessError):
                checker.check_network(network)
            snapshot["entries"][0]["proof"][0] = "0x" + "00" * 32
            snapshot_path.write_text(json.dumps(snapshot))
            with self.assertRaises(subprocess.CalledProcessError):
                checker.check_network(network)


if __name__ == "__main__":
    unittest.main()
