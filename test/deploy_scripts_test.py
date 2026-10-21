#!/usr/bin/env python3
"""Deployment regression checks with isolated configs and fake RPC/signing tools."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile


# 敏感值哨兵：任何一步把它们写进 stdout/stderr 都视为回归。
SECRET_KEY = "do-not-print-this-key"
SECRET_PASSWORD = "do-not-print-this-password"


def fake_tool(tool, args):
    data = json.loads(Path(os.environ["MOCK_DATA"]).read_text())
    with Path(os.environ["MOCK_LOG"]).open("a") as log:
        log.write(json.dumps([tool, *args]) + "\n")
    if tool == "osascript":
        print("test-password")
    elif tool == "cast":
        if args[0] == "chain-id":
            print(os.environ.get("RPC_CHAIN", data["env"]["CHAIN_ID"]))
        elif args[0] == "code":
            if os.environ.get("RPC_CODE_ERROR"):
                return 1
            print("0x01")
        elif args[0] == "call":
            key = args[1].lower() + "/" + args[2]
            print(os.environ.get("BAD_VALUE", "ERROR") if key == os.environ.get("BAD_CALL") else data["calls"][key])
        elif args[0] == "abi-encode":
            if os.environ.get("ABI_ENCODE_FAIL") == args[1]:
                return 1
            print("0x1234")
        else:
            raise AssertionError(args)
    elif args[0] == "script":
        if os.environ.get("DEPLOY_FAIL"):
            return 1
        for key, value in data["env"].items():
            if key in data["contracts"] and key != os.environ.get("OMIT_ADDRESS"):
                print(key + "= " + value)
    elif args[0] == "verify-contract":
        if os.environ.get("VERIFY_FAIL") == args[2]:
            return 1
    else:
        raise AssertionError(args)
    return 0


def main():
    core = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="core-deploy-test-") as directory:
        root = Path(directory)
        deploy = root / "script/deploy"
        shutil.copytree(core / "script/deploy", deploy)
        network = root / "script/network/test"
        network.mkdir(parents=True)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for tool in ("cast", "forge", "osascript"):
            stub = bin_dir / tool
            stub.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " "
                            + shlex.quote(str(Path(__file__).resolve())) + " --fake " + tool + ' "$@"\n')
            stub.chmod(0o755)
        names = ["LOVE20TOKEN", "MEMBERNFT", "PHASE", "LAUNCH", "MINT", "STAKE", "SUBMIT", "VOTE"]
        env = {name + "_ADDRESS": f"0x{index + 10:040x}" for index, name in enumerate(names)}
        contracts = list(env)
        env.update({"CHAIN_ID": "97", "RPC_URL": "http://invalid.local", "ETHERSCAN_API_KEY": "test-key",
                    "WETH_ADDRESS": "0x" + "ab" * 20, "FACTORY_ADDRESS": "0x" + "cd" * 20,
                    "ROUTER_ADDRESS": "0x" + "ef" * 20, "TOKEN_NAME": "TestLOVE20", "TOKEN_SYMBOL": "TestLOVE20@WETH",
                    "INITIAL_SUPPLY": "1000000000000000000000000000", "MAX_SUPPLY": "10000000000000000000000000000",
                    "DISTRIBUTOR": "0x" + "12" * 20, "MEMBER_BASE_DIVISOR": "100000000", "MEMBER_BYTES_THRESHOLD": "7",
                    "MEMBER_MULTIPLIER": "10", "MEMBER_MAX_NAME_LENGTH": "32", "PHASE_ORIGIN_BLOCKS": "1",
                    "PHASE_ORIGIN_PHASE_BLOCKS": "100", "PHASE_TARGET_SECONDS": "300",
                    "PHASE_ADJUST_THRESHOLD": "600000000000000000", "PHASE_SYNC_OBSERVATION_LIMIT": "100",
                    "LAUNCH_RATIO": "1000000000000000000", "MAX_LAUNCH_COUNT": "1000", "TOKEN_SYMBOL_LENGTH": "4",
                    "PROPOSAL_REWARD_MIN_VOTE_RATIO": "50000000000000000", "GOV_REWARD_RATIO": "100000000000000000",
                    "PROPOSAL_REWARD_RATIO": "100000000000000000",
                    "MAX_BOOST_MULTIPLIER": "2", "SUBMIT_MIN_RATIO": "10000000000000000", "PROMISED_WAITING_PHASES_MIN": "1",
                    "PROMISED_WAITING_PHASES_MAX": "100", "FEE_SETTLEMENT_RATIO": "3000000000000000"})
        calls = {}

        def getters(contract, fields):
            for signature, value in fields.items():
                calls[env[contract + "_ADDRESS"].lower() + "/" + signature] = env.get(value, value)

        getters("LOVE20TOKEN", {"name()(string)": "TOKEN_NAME", "symbol()(string)": "TOKEN_SYMBOL",
                "maxSupply()(uint256)": "MAX_SUPPLY", "minter()(address)": "MINT_ADDRESS", "parentTokenAddress()(address)": "WETH_ADDRESS"})
        getters("MEMBERNFT", {key + "()(uint256)": "MEMBER_" + key for key in ("BASE_DIVISOR", "BYTES_THRESHOLD", "MULTIPLIER", "MAX_NAME_LENGTH")})
        getters("MEMBERNFT", {"LOVE20_TOKEN_ADDRESS()(address)": "LOVE20TOKEN_ADDRESS"})
        getters("PHASE", {key + "()(uint256)": "PHASE_" + key for key in ("ORIGIN_BLOCKS", "ORIGIN_PHASE_BLOCKS", "TARGET_SECONDS", "ADJUST_THRESHOLD", "SYNC_OBSERVATION_LIMIT")})
        getters("LAUNCH", {key + "()(uint256)": key for key in ("LAUNCH_RATIO", "MAX_LAUNCH_COUNT", "TOKEN_SYMBOL_LENGTH", "MAX_SUPPLY")})
        getters("LAUNCH", {"LAUNCH_AMOUNT()(uint256)": "INITIAL_SUPPLY", "rootParentTokenAddress()(address)": "WETH_ADDRESS",
                "firstTokenAddress()(address)": "LOVE20TOKEN_ADDRESS", "pairFactoryAddress()(address)": "FACTORY_ADDRESS",
                "isLOVE20Token(address)(bool)": "true"})
        getters("MINT", {key + "()(uint256)": value for key, value in {
            "PROPOSAL_REWARD_MIN_VOTE_RATIO": "PROPOSAL_REWARD_MIN_VOTE_RATIO", "ROUND_REWARD_GOV_RATIO": "GOV_REWARD_RATIO",
            "ROUND_REWARD_PROPOSAL_RATIO": "PROPOSAL_REWARD_RATIO", "MAX_GOV_BOOST_REWARD_MULTIPLIER": "MAX_BOOST_MULTIPLIER"}.items()})
        getters("MINT", {"phaseAddress()(address)": "PHASE_ADDRESS"})
        getters("STAKE", {key + "()(uint256)": key for key in ("PROMISED_WAITING_PHASES_MIN", "PROMISED_WAITING_PHASES_MAX", "FEE_SETTLEMENT_RATIO")})
        getters("STAKE", {"routerAddress()(address)": "ROUTER_ADDRESS", "pairFactoryAddress()(address)": "FACTORY_ADDRESS"})
        getters("SUBMIT", {"SUBMIT_MIN_RATIO()(uint256)": "SUBMIT_MIN_RATIO"})
        for name, dependencies in {"MEMBERNFT": [], "LAUNCH": ["mint", "memberNFT"], "MINT": ["vote", "submit", "launch", "memberNFT"],
                "STAKE": ["phase", "memberNFT", "vote", "launch"], "SUBMIT": ["phase", "stake", "memberNFT"],
                "VOTE": ["phase", "stake", "submit", "memberNFT"]}.items():
            getters(name, {"initialized()(bool)": "true"})
            getters(name, {dep + "Address()(address)": dep.upper() + "_ADDRESS" for dep in dependencies})
        getters("ROUTER", {"factory()(address)": "FACTORY_ADDRESS", "WETH()(address)": "WETH_ADDRESS"})
        data_path, log_path = root / "rpc.json", root / "calls.log"
        data_path.write_text(json.dumps({"env": env, "contracts": contracts, "calls": calls}))
        network.joinpath("network.params").write_text("\n".join(key + "=" + shlex.quote(value) for key, value in env.items()) + "\n")
        for name in ("addresses.uniswapv2.params", "core.params"):
            network.joinpath(name).write_text("")
        saved = network / "addresses.core.params"
        # 步骤自行载入地址文件：先写入一份与 env 一致的已部署地址，供独立运行的 21_check / 31_verify 读取。
        saved.write_text("\n".join(name + "_ADDRESS=" + env[name + "_ADDRESS"] for name in names) + "\n")
        base = {"PATH": str(bin_dir) + os.pathsep + os.environ["PATH"], "MOCK_DATA": str(data_path), "MOCK_LOG": str(log_path),
                "PROJECT_ROOT": str(root), "NETWORK_DIR": str(network), "network": "test", **env}
        checks = 0

        def write_account(password_line=""):
            network.joinpath(".account").write_text(
                "KEYSTORE_ACCOUNT=test-keystore\nACCOUNT_ADDRESS=0x" + "f5" * 20 + "\nPRIVATE_KEY=" + SECRET_KEY + "\n" + password_line)

        def run(script, success=True, args=(), **extra):
            nonlocal checks
            log_path.write_text("")
            result = subprocess.run(["bash", str(deploy / script), *args], env={**base, **extra}, text=True, capture_output=True)
            assert (result.returncode == 0) == success, (script, extra, result.stdout, result.stderr)
            assert not any(secret in result.stdout + result.stderr for secret in (SECRET_KEY, SECRET_PASSWORD))
            checks += 1
            return result, [json.loads(line) for line in log_path.read_text().splitlines()]

        def forge_script_call(log):
            return next(call for call in log if call[:2] == ["forge", "script"])

        write_account()

        run("21_check.sh", args=("test",))
        # 地址文件键集合不符（漏改键名）必须显式失败。
        saved.write_text("\n".join(name + "_ADDRESS=" + env[name + "_ADDRESS"] for name in names[:-1]) + "\nSTAKE_ADDR=" + env["STAKE_ADDRESS"] + "\n")
        result, _ = run("21_check.sh", False, ("test",))
        assert "key set mismatch" in result.stdout + result.stderr, result.stdout + result.stderr
        saved.write_text("\n".join(name + "_ADDRESS=" + env[name + "_ADDRESS"] for name in names) + "\n")
        for contract, signature in [("LAUNCH", "rootParentTokenAddress()(address)"), ("LAUNCH", "firstTokenAddress()(address)"),
                ("LAUNCH", "pairFactoryAddress()(address)"),
                ("LAUNCH", "TOKEN_SYMBOL_LENGTH()(uint256)"), ("LAUNCH", "LAUNCH_AMOUNT()(uint256)"), ("LAUNCH", "MAX_SUPPLY()(uint256)"),
                ("MEMBERNFT", "MAX_NAME_LENGTH()(uint256)"), ("PHASE", "ORIGIN_BLOCKS()(uint256)"),
                ("PHASE", "ORIGIN_PHASE_BLOCKS()(uint256)"), ("PHASE", "SYNC_OBSERVATION_LIMIT()(uint256)"), ("ROUTER", "WETH()(address)")]:
            wrong_value = "0x" + "98" * 20 if signature.endswith("(address)") else "999"
            run("21_check.sh", False, ("test",), BAD_CALL=env[contract + "_ADDRESS"].lower() + "/" + signature, BAD_VALUE=wrong_value)
        run("21_check.sh", False, ("test",), RPC_CODE_ERROR="1")
        run("21_check.sh", False, ("test",), RPC_CHAIN="56")
        run("21_check.sh", False, ("test",), BAD_CALL=env["STAKE_ADDRESS"] + "/FEE_SETTLEMENT_RATIO()(uint256)")
        # 地址比较大小写不敏感：配置写大写、链上读到小写，仍应通过（配置值由步骤自行载入）。
        params_path = network.joinpath("network.params")
        params_text = params_path.read_text()
        params_path.write_text(params_text + "WETH_ADDRESS=0x" + "AB" * 20 + "\n")
        run("21_check.sh", args=("test",))
        params_path.write_text(params_text)
        saved.write_text("# previous deployment\n")
        for extra in ({"RPC_CHAIN": "56"}, {"DEPLOY_FAIL": "1"}, {"OMIT_ADDRESS": "VOTE_ADDRESS"},
                      {"BAD_CALL": env["LAUNCH_ADDRESS"] + "/pairFactoryAddress()(address)"}):
            run("one_click_deploy.sh", False, ("test",), **extra)
            assert saved.read_text() == "# previous deployment\n"
        _, log = run("one_click_deploy.sh", args=("test",))
        command = forge_script_call(log)
        assert command[command.index("--chain-id") + 1] == "97"
        assert command[command.index("--account") + 1] == "test-keystore"
        assert command[command.index("--sender") + 1] == "0x" + "f5" * 20
        assert "--unlocked" not in command and "--private-key" not in command
        # 留空 KEYSTORE_PASSWORD：弹窗一次读取（osascript），直接用读取值解锁。
        assert command[command.index("--password") + 1] == "test-password"
        assert len([call for call in log if call[0] == "osascript"]) == 1, log
        assert "VOTE_ADDRESS=" in saved.read_text()
        # .account 配了非空 KEYSTORE_PASSWORD 就直接用它解锁，不弹窗。
        write_account("KEYSTORE_PASSWORD=" + SECRET_PASSWORD + "\n")
        _, log = run("one_click_deploy.sh", args=("test",))
        command = forge_script_call(log)
        assert command[command.index("--password") + 1] == SECRET_PASSWORD
        assert not any(call[0] == "osascript" for call in log), log
        # 显式留空等同未配置：仍走弹窗。
        write_account("KEYSTORE_PASSWORD=\n")
        _, log = run("one_click_deploy.sh", args=("test",))
        assert forge_script_call(log)[forge_script_call(log).index("--password") + 1] == "test-password"
        assert len([call for call in log if call[0] == "osascript"]) == 1, log
        write_account()
        # .account 缺 KEYSTORE_ACCOUNT / ACCOUNT_ADDRESS，或整个文件缺失：广播前即失败，不弹窗不广播。
        network.joinpath(".account").write_text("PRIVATE_KEY=" + SECRET_KEY + "\n")
        run("11_deploy.sh", False, ("test",))
        network.joinpath(".account").unlink()
        run("11_deploy.sh", False, ("test",))
        write_account()
        # DEX 依赖地址不是已部署合约：广播前失败（cast code 拿不到字节码）。
        run("11_deploy.sh", False, ("test",), RPC_CODE_ERROR="1")
        run("11_deploy.sh", args=("test",))
        saved_before = saved.read_text()
        result, _ = run("11_deploy.sh", False, ("test",), OMIT_ADDRESS="VOTE_ADDRESS")
        assert "VOTE_ADDRESS" in result.stdout + result.stderr, result.stdout + result.stderr
        assert saved.read_text() == saved_before, saved.read_text()
        result, _ = run("31_verify.sh", False, ("test",), VERIFY_FAIL="src/MemberNFT.sol:MemberNFT")
        assert "all 8 contracts" not in result.stdout
        result, log = run("31_verify.sh", False, ("test",), VERIFY_FAIL="src/Vote.sol:Vote")
        assert "all 8 contracts" not in result.stdout
        assert len([call for call in log if call[:2] == ["forge", "verify-contract"]]) == 8
        _, log = run("31_verify.sh", args=("test",))
        assert len([call for call in log if call[:2] == ["forge", "verify-contract"]]) == 8
        token_args = next(call for call in log if call[:2] == ["cast", "abi-encode"] and "string,string" in call[2])
        assert token_args[-2] == env["MINT_ADDRESS"]
        for signature, label in [("constructor(uint256,uint256,uint256,uint256)", "MemberNFT"),
                                 ("constructor(uint256,uint256,uint256,uint256,uint256)", "Phase"),
                                 ("constructor(string,string,uint256,uint256,address,address,address)", "LOVE20Token")]:
            result, log = run("31_verify.sh", False, ("test",), ABI_ENCODE_FAIL=signature)
            assert f"Failed to encode {label}" in result.stdout, result.stdout
            assert not any(call[0] == "forge" for call in log)
        with network.joinpath("network.params").open("a") as config:
            config.write("ETHERSCAN_API_KEY=\n")
        _, log = run("31_verify.sh", False, ("test",))
        assert not any(call[0] == "forge" for call in log)
        print(f"Passed {checks} isolated deployment checks (no network calls or broadcasts).")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--fake":
        sys.exit(fake_tool(sys.argv[2], sys.argv[3:]))
    main()
