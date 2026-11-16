// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Script} from "@forge-std/Script.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Arrays} from "@openzeppelin/contracts/utils/Arrays.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract CheckSnapshot is Script {
    function run(string calldata path, bytes32 root) external view {
        _checkSnapshot(path, root);
    }

    function _checkSnapshot(string memory path, bytes32 root) internal view {
        string memory snapshot = vm.readFile(path);
        require(vm.parseJsonBytes32(snapshot, ".merkleRoot") == root, "Snapshot root mismatch");
        require(vm.parseUint(vm.parseJsonString(snapshot, ".totalShare")) == 1e18, "Snapshot total share mismatch");
        uint256 count = vm.parseUint(vm.parseJsonString(snapshot, ".accountCount"));
        require(
            count != 0 && vm.keyExistsJson(snapshot, string.concat(".entries[", Strings.toString(count - 1), "]"))
                && !vm.keyExistsJson(snapshot, string.concat(".entries[", Strings.toString(count), "]")),
            "Snapshot account count mismatch"
        );
        address[] memory accounts = new address[](count);
        uint256 total = 0;
        for (uint256 i = 0; i < count; ++i) {
            string memory entry = string.concat(".entries[", Strings.toString(i), "]");
            // These calls only parse local JSON; this script does not broadcast transactions.
            // forge-lint: disable-next-item(calls-loop)
            address account = vm.parseJsonAddress(snapshot, string.concat(entry, ".account"));
            accounts[i] = account;
            // forge-lint: disable-next-item(calls-loop)
            uint256 share = vm.parseUint(vm.parseJsonString(snapshot, string.concat(entry, ".share")));
            // forge-lint: disable-next-item(calls-loop)
            bytes32[] memory proof = vm.parseJsonBytes32Array(snapshot, string.concat(entry, ".proof"));
            // forge-lint: disable-next-item(require-revert-in-loop)
            require(share > 0, "Snapshot share is zero");
            // forge-lint: disable-next-item(require-revert-in-loop)
            require(
                MerkleProof.verify(proof, root, keccak256(bytes.concat(keccak256(abi.encode(account, share))))),
                "Snapshot proof mismatch"
            );
            total += share;
        }
        Arrays.sort(accounts);
        for (uint256 i = 1; i < count; ++i) {
            // forge-lint: disable-next-item(require-revert-in-loop)
            require(accounts[i] != accounts[i - 1], "Duplicate snapshot account");
        }
        require(total == 1e18, "Snapshot shares must sum to 1e18");
    }

    function _snapshotPath(string memory directory, string memory uri) internal pure returns (string memory) {
        string[] memory parts = vm.split(vm.split(vm.split(uri, "#")[0], "?")[0], "/");
        string[] memory directories = vm.split(directory, "/");
        require(
            parts.length == 8 && Strings.equal(parts[0], "https:") && bytes(parts[1]).length == 0
                && bytes(parts[2]).length != 0 && Strings.equal(parts[3], "core") && Strings.equal(parts[4], "script")
                && Strings.equal(parts[5], "network") && Strings.equal(parts[6], directories[directories.length - 1]),
            "Genesis snapshot URI must point to this network's HTTPS snapshot"
        );
        string[] memory filename = vm.split(parts[7], ".");
        require(
            bytes(vm.split(parts[7], "airdrop")[0]).length == 0 && Strings.equal(filename[filename.length - 1], "json"),
            "Genesis snapshot filename must be airdrop*.json"
        );
        return string.concat(directory, "/", parts[7]);
    }
}
