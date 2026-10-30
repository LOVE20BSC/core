#!/usr/bin/env python3
"""Deployment regression checks with isolated configs and fake RPC/signing tools."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time


# 敏感值哨兵：任何一步把它写进 stdout/stderr 都视为回归。
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
    elif tool == "mktemp":
        if "-d" in args:
            print(tempfile.mkdtemp(dir=os.environ["MOCK_TMP"]))
        else:
            fd, path = tempfile.mkstemp(dir=os.environ["MOCK_TMP"])
            os.close(fd)
            print(path)
    elif args[0] == "script":
        # 凭据哨兵：密码不得进进程参数，密码文件必须已写入且非空。
        if "--password" in args:
            print("CREDENTIAL_IN_ARGV", file=sys.stderr)
        password_file = args[args.index("--password-file") + 1] if "--password-file" in args else None
        if not password_file or not Path(password_file).is_file() or not Path(password_file).read_text():
            print("PASSWORD_FILE_MISSING", file=sys.stderr)
        else:
            print("PASSWORD_SHA=" + hashlib.sha256(Path(password_file).read_bytes()).hexdigest(),
                  file=sys.stderr)
        if os.environ.get("DEPLOY_FAIL"):
            return 1
        # 成功广播会刷新 run-latest.json 的 timestamp；STALE_BROADCAST 模拟过期产物。
        broadcast = os.environ.get("MOCK_BROADCAST")
        if broadcast and Path(broadcast).exists():
            artifact = json.loads(Path(broadcast).read_text())
            artifact["timestamp"] = 0 if os.environ.get("STALE_BROADCAST") else int(time.time() * 1000)
            Path(broadcast).write_text(json.dumps(artifact, indent=2))
        for key, value in data["env"].items():
            if key in data["contracts"] and key != os.environ.get("OMIT_ADDRESS"):
                print(key + "= " + value)
    elif args[0] == "verify-contract":
        if os.environ.get("VERIFY_FAIL") == args[2]:
            return 1
    else:
        raise AssertionError(args)
    return 0


def params_loader_cases() -> None:
    """params.sh：1e 写法展开、行尾注释、引号内 # 保留、逗号项去空格。"""
    repo = Path(__file__).resolve().parents[1]
    cases = [
        ("A=1e17\n", "100000000000000000"),
        ("A=3e15  # 0.30%\n", "3000000000000000"),
        ("A=1_000\n", "1000"),
        ('A="a # b"\n', "a # b"),
        ("A=1e17, 4e17\n", "100000000000000000,400000000000000000"),
        ("A=x1e5y\n", "x1e5y"),
    ]
    with tempfile.TemporaryDirectory(prefix="params-loader-test-") as directory:
        path = Path(directory) / "case.params"
        for text, expected in cases:
            path.write_text(text)
            result = subprocess.run(
                ["bash", "-c", '. "$1"; params_load "$2"; printf "%s" "$A"',
                 "bash", str(repo / "script/deploy/params.sh"), str(path)],
                text=True, capture_output=True)
            assert result.returncode == 0, (text, result.stderr)
            assert result.stdout == expected, (text, result.stdout)


def main():
    params_loader_cases()
    core = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="core-deploy-test-") as directory:
        root = Path(directory)
        deploy = root / "script/deploy"
        shutil.copytree(core / "script/deploy", deploy)
        network = root / "script/network/test"
        network.mkdir(parents=True)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for tool in ("cast", "forge", "osascript", "mktemp"):
            stub = bin_dir / tool
            stub.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " "
                            + shlex.quote(str(Path(__file__).resolve())) + " --fake " + tool + ' "$@"\n')
            stub.chmod(0o755)
        names = ["LOVE20_TOKEN", "MEMBER_NFT", "PHASE", "LAUNCH", "MINT", "STAKE", "SUBMIT", "VOTE"]
        env = {name + "_ADDRESS": f"0x{index + 10:040x}" for index, name in enumerate(names)}
        contracts = list(env)
        env.update({"CHAIN_ID": "97", "RPC_URL": "http://invalid.local", "ETHERSCAN_API_KEY": "test-key",
                    "WETH_ADDRESS": "0x" + "ab" * 20, "FACTORY_ADDRESS": "0x" + "cd" * 20,
                    "ROUTER_ADDRESS": "0x" + "ef" * 20, "TOKEN_NAME": "TestLOVE20", "TOKEN_SYMBOL": "TestLOVE20@WETH",
                    "INITIAL_SUPPLY": "1000000000000000000000000000", "MAX_SUPPLY": "10000000000000000000000000000",
                    "DISTRIBUTOR_ADDRESS": "0x" + "12" * 20, "MEMBER_BASE_DIVISOR": "100000000", "MEMBER_BYTES_THRESHOLD": "7",
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

        getters("LOVE20_TOKEN", {"name()(string)": "TOKEN_NAME", "symbol()(string)": "TOKEN_SYMBOL",
                "MAX_SUPPLY()(uint256)": "MAX_SUPPLY", "MINTER()(address)": "MINT_ADDRESS",
                "PARENT_TOKEN_ADDRESS()(address)": "WETH_ADDRESS", "totalSupply()(uint256)": "INITIAL_SUPPLY"})
        calls[env["LOVE20_TOKEN_ADDRESS"].lower() + "/balanceOf(address)(uint256)"] = env["INITIAL_SUPPLY"]
        getters("MEMBER_NFT", {key + "()(uint256)": "MEMBER_" + key for key in ("BASE_DIVISOR", "BYTES_THRESHOLD", "MULTIPLIER", "MAX_NAME_LENGTH")})
        getters("MEMBER_NFT", {"LOVE20_TOKEN_ADDRESS()(address)": "LOVE20_TOKEN_ADDRESS"})
        getters("PHASE", {key + "()(uint256)": "PHASE_" + key for key in ("ORIGIN_BLOCKS", "ORIGIN_PHASE_BLOCKS", "TARGET_SECONDS", "ADJUST_THRESHOLD", "SYNC_OBSERVATION_LIMIT")})
        getters("LAUNCH", {key + "()(uint256)": key for key in ("LAUNCH_RATIO", "MAX_LAUNCH_COUNT", "TOKEN_SYMBOL_LENGTH", "MAX_SUPPLY")})
        getters("LAUNCH", {"LAUNCH_AMOUNT()(uint256)": "INITIAL_SUPPLY", "ROOT_PARENT_TOKEN_ADDRESS()(address)": "WETH_ADDRESS",
                "FIRST_TOKEN_ADDRESS()(address)": "LOVE20_TOKEN_ADDRESS", "PAIR_FACTORY_ADDRESS()(address)": "FACTORY_ADDRESS",
                "isLOVE20Token(address)(bool)": "true"})
        getters("MINT", {key + "()(uint256)": value for key, value in {
            "PROPOSAL_REWARD_MIN_VOTE_RATIO": "PROPOSAL_REWARD_MIN_VOTE_RATIO", "ROUND_REWARD_GOV_RATIO": "GOV_REWARD_RATIO",
            "ROUND_REWARD_PROPOSAL_RATIO": "PROPOSAL_REWARD_RATIO", "MAX_GOV_BOOST_REWARD_MULTIPLIER": "MAX_BOOST_MULTIPLIER"}.items()})
        getters("MINT", {"PHASE_ADDRESS()(address)": "PHASE_ADDRESS"})
        getters("STAKE", {key + "()(uint256)": key for key in ("PROMISED_WAITING_PHASES_MIN", "PROMISED_WAITING_PHASES_MAX", "FEE_SETTLEMENT_RATIO")})
        getters("STAKE", {"ROUTER_ADDRESS()(address)": "ROUTER_ADDRESS", "PAIR_FACTORY_ADDRESS()(address)": "FACTORY_ADDRESS"})
        getters("SUBMIT", {"SUBMIT_MIN_RATIO()(uint256)": "SUBMIT_MIN_RATIO"})
        dep_keys = {"mint": "MINT", "memberNFT": "MEMBER_NFT", "phase": "PHASE", "stake": "STAKE", "vote": "VOTE", "submit": "SUBMIT", "launch": "LAUNCH"}
        for name, dependencies in {"MEMBER_NFT": [], "LAUNCH": ["mint", "memberNFT"], "MINT": ["vote", "submit", "launch", "memberNFT"],
                "STAKE": ["phase", "memberNFT", "vote", "launch"], "SUBMIT": ["phase", "stake", "memberNFT"],
                "VOTE": ["phase", "stake", "submit", "memberNFT"]}.items():
            getters(name, {"initialized()(bool)": "true"})
            getters(name, {dep_keys.get(dep, dep.upper()) + "_ADDRESS()(address)": dep_keys.get(dep, dep.upper()) + "_ADDRESS" for dep in dependencies})
        getters("ROUTER", {"factory()(address)": "FACTORY_ADDRESS", "WETH()(address)": "WETH_ADDRESS"})
        # cast 对 uint 返回值会带科学计数法标注，且供应量超过 64 位；21_check 必须先归一再按十进制串比较。
        calls[env["LAUNCH_ADDRESS"].lower() + "/LAUNCH_AMOUNT()(uint256)"] = env["INITIAL_SUPPLY"] + " [1e27]"
        calls[env["LAUNCH_ADDRESS"].lower() + "/MAX_SUPPLY()(uint256)"] = env["MAX_SUPPLY"] + " [1e28]"
        calls[env["MINT_ADDRESS"].lower() + "/ROUND_REWARD_GOV_RATIO()(uint256)"] = env["GOV_REWARD_RATIO"] + " [1e17]"
        calls[env["MINT_ADDRESS"].lower() + "/ROUND_REWARD_PROPOSAL_RATIO()(uint256)"] = env["PROPOSAL_REWARD_RATIO"] + " [1e17]"
        data_path, log_path = root / "rpc.json", root / "calls.log"
        tmp_dir = root / "tmp"
        tmp_dir.mkdir()
        data_path.write_text(json.dumps({"env": env, "contracts": contracts, "calls": calls}))
        network.joinpath("network.params").write_text("\n".join(key + "=" + shlex.quote(value) for key, value in env.items()) + "\n")
        for name in ("addresses.uniswapv2.params", "core.params"):
            network.joinpath(name).write_text("")
        saved = network / "addresses.core.params"
        # 步骤自行载入地址文件：先写入一份与 env 一致的已部署地址，供独立运行的 21_check / 31_verify 读取。
        saved.write_text("\n".join(name + "_ADDRESS=" + env[name + "_ADDRESS"] for name in names) + "\n")
        broadcast = root / "broadcast/DeployCore.s.sol/97/run-latest.json"
        broadcast.parent.mkdir(parents=True)
        broadcast.write_text(json.dumps({"timestamp": 0}, indent=2))
        base = {"PATH": str(bin_dir) + os.pathsep + os.environ["PATH"], "MOCK_DATA": str(data_path), "MOCK_LOG": str(log_path),
                "MOCK_BROADCAST": str(broadcast), "MOCK_TMP": str(tmp_dir), "PROJECT_ROOT": str(root),
                "NETWORK_DIR": str(network), "network": "test", **env}
        checks = 0

        def write_account(password_line=""):
            # 正确用法：keystore 名称 + 账户地址 + 可选密码。
            network.joinpath(".account").write_text(
                "KEYSTORE_ACCOUNT=test-keystore\nACCOUNT_ADDRESS=0x" + "f5" * 20 + "\n" + password_line)

        def run(script, success=True, args=(), **extra):
            nonlocal checks
            log_path.write_text("")
            result = subprocess.run(["bash", str(deploy / script), *args], env={**base, **extra}, text=True, capture_output=True)
            assert (result.returncode == 0) == success, (script, extra, result.stdout, result.stderr)
            output = result.stdout + result.stderr
            assert SECRET_PASSWORD not in output
            for marker in ("CREDENTIAL_IN_ARGV", "PASSWORD_FILE_MISSING"):
                assert marker not in output, (marker, output)
            log = [json.loads(line) for line in log_path.read_text().splitlines()]
            for call in log:
                if call[:2] == ["forge", "script"] and "--password-file" in call:
                    assert not Path(call[call.index("--password-file") + 1]).exists(), call
            checks += 1
            return result, log

        def forge_script_call(log):
            return next(call for call in log if call[:2] == ["forge", "script"])

        write_account()

        run("21_check.sh", args=("test",))
        # 地址文件键集合不符（漏改键名）必须显式失败。
        saved.write_text("\n".join(name + "_ADDRESS=" + env[name + "_ADDRESS"] for name in names[:-1]) + "\nSTAKE_ADDR=" + env["STAKE_ADDRESS"] + "\n")
        result, _ = run("21_check.sh", False, ("test",))
        assert "key set mismatch" in result.stdout + result.stderr, result.stdout + result.stderr
        saved.write_text("\n".join(name + "_ADDRESS=" + env[name + "_ADDRESS"] for name in names) + "\n")
        for contract, signature in [("LAUNCH", "ROOT_PARENT_TOKEN_ADDRESS()(address)"),
                ("LAUNCH", "FIRST_TOKEN_ADDRESS()(address)"), ("LAUNCH", "PAIR_FACTORY_ADDRESS()(address)"),
                ("LAUNCH", "TOKEN_SYMBOL_LENGTH()(uint256)"), ("LAUNCH", "LAUNCH_AMOUNT()(uint256)"), ("LAUNCH", "MAX_SUPPLY()(uint256)"),
                ("MEMBER_NFT", "MAX_NAME_LENGTH()(uint256)"), ("PHASE", "ORIGIN_BLOCKS()(uint256)"),
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
                      {"STALE_BROADCAST": "1"},
                      {"BAD_CALL": env["LAUNCH_ADDRESS"] + "/PAIR_FACTORY_ADDRESS()(address)"}):
            result, _ = run("one_click_deploy.sh", False, ("test",), **extra)
            assert saved.read_text() == "# previous deployment\n"
            output = result.stdout + result.stderr
            if "BAD_CALL" in extra:
                assert "New deployment addresses" in output, output
                assert "VOTE_ADDRESS=" in output, output
                assert "Broadcast artifact:" in output, output
                assert "The previously saved addresses were restored." in output, output
            if "Deployment log:" in output:
                kept_log = Path(output.split("Deployment log:", 1)[1].splitlines()[0].strip())
                assert kept_log.exists(), kept_log
                kept_log.unlink()
        result, log = run("one_click_deploy.sh", args=("test",))
        command = forge_script_call(log)
        assert not list(tmp_dir.iterdir()), list(tmp_dir.iterdir())
        assert command[command.index("--chain-id") + 1] == "97"
        assert command[command.index("--account") + 1] == "test-keystore"
        assert command[command.index("--sender") + 1] == "0x" + "f5" * 20
        assert "--unlocked" not in command and "--private-key" not in command
        # 留空 KEYSTORE_PASSWORD：弹窗一次读取（osascript）。密码经临时文件传给 forge，不进 argv。
        assert "--password" not in command, command
        assert "PASSWORD_SHA=" + hashlib.sha256(b"test-password").hexdigest() in result.stdout + result.stderr, \
            result.stdout + result.stderr
        assert len([call for call in log if call[0] == "osascript"]) == 1, log
        assert "VOTE_ADDRESS=" in saved.read_text()
        # .account 配了非空 KEYSTORE_PASSWORD 就直接用它解锁，不弹窗。
        write_account("KEYSTORE_PASSWORD=" + SECRET_PASSWORD + "\n")
        result, log = run("one_click_deploy.sh", args=("test",))
        command = forge_script_call(log)
        assert "--password" not in command, command
        assert "PASSWORD_SHA=" + hashlib.sha256(SECRET_PASSWORD.encode()).hexdigest() in result.stdout + result.stderr, \
            result.stdout + result.stderr
        assert not any(call[0] == "osascript" for call in log), log
        # 显式留空等同未配置：仍走弹窗。
        write_account("KEYSTORE_PASSWORD=\n")
        result, log = run("one_click_deploy.sh", args=("test",))
        assert "--password" not in forge_script_call(log)
        assert "PASSWORD_SHA=" + hashlib.sha256(b"test-password").hexdigest() in result.stdout + result.stderr, \
            result.stdout + result.stderr
        assert len([call for call in log if call[0] == "osascript"]) == 1, log
        write_account()
        # .account 缺 KEYSTORE_ACCOUNT / ACCOUNT_ADDRESS，或整个文件缺失：广播前即失败，不弹窗不广播。
        network.joinpath(".account").write_text("UNRELATED=x\n")
        run("11_deploy.sh", False, ("test",))
        network.joinpath(".account").unlink()
        run("11_deploy.sh", False, ("test",))
        write_account()
        # 广播失败：合约可能已部分上链，必须保留日志并打印路径。
        saved_before = saved.read_text()
        result, _ = run("11_deploy.sh", False, ("test",), DEPLOY_FAIL="1")
        output = result.stdout + result.stderr
        assert "contracts may already be on chain" in output, output
        assert "Deployment log:" in output, output
        kept_log = Path(output.split("Deployment log:", 1)[1].splitlines()[0].strip())
        assert kept_log.exists(), kept_log
        kept_log.unlink()
        assert saved.read_text() == saved_before, saved.read_text()
        run("11_deploy.sh", args=("test",))
        saved_before = saved.read_text()
        # 广播后地址提取失败：同样保留日志，且不写半截文件。
        result, _ = run("11_deploy.sh", False, ("test",), OMIT_ADDRESS="VOTE_ADDRESS")
        output = result.stdout + result.stderr
        assert "VOTE_ADDRESS" in output, output
        assert "contracts may already be on chain" in output, output
        assert "Deployment log:" in output, output
        kept_log = Path(output.split("Deployment log:", 1)[1].splitlines()[0].strip())
        assert kept_log.exists(), kept_log
        kept_log.unlink()
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
        assert not list(tmp_dir.iterdir()), list(tmp_dir.iterdir())
        print(f"Passed {checks} isolated deployment checks (no network calls or broadcasts).")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--fake":
        sys.exit(fake_tool(sys.argv[2], sys.argv[3:]))
    main()
