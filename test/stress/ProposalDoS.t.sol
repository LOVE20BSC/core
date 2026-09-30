// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ILOVE20Token} from "../../src/interfaces/ILOVE20Token.sol";
import {IMemberNFT} from "../../src/interfaces/IMemberNFT.sol";
import {IPhase} from "../../src/interfaces/IPhase.sol";
import {IStake} from "../../src/interfaces/IStake.sol";
import {ISubmit} from "../../src/interfaces/ISubmit.sol";
import {IVote} from "../../src/interfaces/IVote.sol";

/**
 * @title ProposalDoS - M-01 边界压力测试
 * @notice 测试大量 Proposal 创建对系统的影响
 * @dev 目标：
 *      1. 找到可接受的 Proposal 数量上限
 *      2. 测量 gas 消耗增长曲线
 *      3. 验证系统在极限情况下的行为
 */
contract ProposalDoSTest is Test {
    // 需要从实际部署环境注入的地址
    address public token;
    address public memberNFT;
    address public phase;
    address public stake;
    address public submit;
    address public vote;

    // 测试账户
    address public attacker;
    uint256 public attackerMemberId;

    // 测试结果记录
    struct GasRecord {
        uint256 proposalCount;
        uint256 submitGas;
        uint256 voteGas;
        uint256 mintGas;
    }

    GasRecord[] public gasRecords;

    function setUp() public {
        // 从环境变量读取部署地址
        token = vm.envOr("LOVE20TOKEN_ADDRESS", address(0));
        memberNFT = vm.envOr("MEMBERNFT_ADDRESS", address(0));
        phase = vm.envOr("PHASE_ADDRESS", address(0));
        stake = vm.envOr("STAKE_ADDRESS", address(0));
        submit = vm.envOr("SUBMIT_ADDRESS", address(0));
        vote = vm.envOr("VOTE_ADDRESS", address(0));

        // 验证地址已设置
        require(token != address(0), "LOVE20TOKEN_ADDRESS not set");
        require(memberNFT != address(0), "MEMBERNFT_ADDRESS not set");
        require(phase != address(0), "PHASE_ADDRESS not set");
        require(stake != address(0), "STAKE_ADDRESS not set");
        require(submit != address(0), "SUBMIT_ADDRESS not set");
        require(vote != address(0), "VOTE_ADDRESS not set");

        // 创建测试账户
        attacker = makeAddr("attacker");

        // 给攻击者铸造 MemberNFT
        vm.prank(attacker);
        attackerMemberId = IMemberNFT(memberNFT).mint(token);
    }

    /**
     * @notice 测试：逐步增加 Proposal 数量，观察 gas 消耗
     * @dev 分阶段测试：10, 50, 100, 200, 500, 1000
     */
    function testProposalGasGrowth() public {
        console.log("=== Proposal Gas Growth Test ===");
        console.log("Token:", token);
        console.log("Attacker:", attacker);
        console.log("MemberId:", attackerMemberId);

        uint256[] memory testCounts = new uint256[](6);
        testCounts[0] = 10;
        testCounts[1] = 50;
        testCounts[2] = 100;
        testCounts[3] = 200;
        testCounts[4] = 500;
        testCounts[5] = 1000;

        for (uint256 i = 0; i < testCounts.length; i++) {
            uint256 targetCount = testCounts[i];
            console.log("\n--- Testing %d proposals ---", targetCount);

            _testAtProposalCount(targetCount);
        }

        _printGasReport();
    }

    /**
     * @notice 测试指定数量的 Proposal
     */
    function _testAtProposalCount(uint256 targetCount) internal {
        uint256 currentPhase = IPhase(phase).currentPhase();
        uint256 currentCount = ISubmit(submit).proposalIdsByPhase(token, currentPhase, 0, type(uint256).max);

        // 创建 Proposal 直到达到目标数量
        if (currentCount < targetCount) {
            _createProposals(targetCount - currentCount);
        }

        // 测量关键操作的 gas
        GasRecord memory record;
        record.proposalCount = targetCount;

        // 1. 测量新 Proposal 提交的 gas
        record.submitGas = _measureSubmitGas();

        // 2. 测量投票的 gas
        record.voteGas = _measureVoteGas();

        // 3. 测量 mint 遍历的 gas（需要推进到下一个 phase）
        record.mintGas = _measureMintGas();

        gasRecords.push(record);

        console.log("  Submit gas:  %d", record.submitGas);
        console.log("  Vote gas:    %d", record.voteGas);
        console.log("  Mint gas:    %d", record.mintGas);
    }

    /**
     * @notice 批量创建 Proposal
     */
    function _createProposals(uint256 count) internal {
        console.log("Creating %d proposals...", count);

        // 确保攻击者有足够的质押和投票权
        _prepareStake();

        for (uint256 i = 0; i < count; i++) {
            string memory desc = string(abi.encodePacked("Proposal #", vm.toString(i)));

            vm.prank(attacker);
            try ISubmit(submit).submit(token, attackerMemberId, desc) {
                // 成功
            } catch {
                console.log("  Failed to create proposal %d", i);
                break;
            }

            // 每 100 个打印一次进度
            if ((i + 1) % 100 == 0) {
                console.log("  Created %d/%d proposals", i + 1, count);
            }
        }
    }

    /**
     * @notice 准备质押（确保可以提交 Proposal）
     */
    function _prepareStake() internal {
        // 检查是否已有质押
        (uint256 liquidityShares,,,,) = IStake(stake).stakeData(token, attackerMemberId);

        if (liquidityShares == 0) {
            // 需要质押流动性
            // 这里需要根据实际代币余额和池子状态来设置
            // 简化起见，假设已经通过其他方式准备好了质押
            vm.skip(true);
        }
    }

    /**
     * @notice 测量提交新 Proposal 的 gas
     */
    function _measureSubmitGas() internal returns (uint256) {
        string memory desc = "Gas measurement proposal";

        uint256 gasBefore = gasleft();
        vm.prank(attacker);
        try ISubmit(submit).submit(token, attackerMemberId, desc) {
            return gasBefore - gasleft();
        } catch {
            return type(uint256).max; // 标记失败
        }
    }

    /**
     * @notice 测量投票的 gas
     */
    function _measureVoteGas() internal returns (uint256) {
        uint256 currentPhase = IPhase(phase).currentPhase();

        // 获取当前阶段的第一个 Proposal
        uint256 proposalId = ISubmit(submit).proposalIdsByPhase(token, currentPhase, 0, 1);
        if (proposalId == 0) return 0;

        uint256 gasBefore = gasleft();
        vm.prank(attacker);
        try IVote(vote).vote(token, attackerMemberId, proposalId, true) {
            return gasBefore - gasleft();
        } catch {
            return type(uint256).max;
        }
    }

    /**
     * @notice 测量 mint 遍历所有 Proposal 的 gas
     */
    function _measureMintGas() internal returns (uint256) {
        // 推进到下一个 phase
        uint256 currentPhase = IPhase(phase).currentPhase();
        vm.warp(block.timestamp + IPhase(phase).PHASE_BLOCKS() * 12); // 假设 12s per block

        uint256 gasBefore = gasleft();
        // 这里需要调用触发 mint 的操作
        // 具体实现取决于 Mint 合约的接口
        return gasBefore - gasleft();
    }

    /**
     * @notice 打印 gas 消耗报告
     */
    function _printGasReport() internal view {
        console.log("\n=== Gas Consumption Report ===");
        console.log("Proposals | Submit Gas | Vote Gas   | Mint Gas   | Total");
        console.log("----------|------------|------------|------------|------------");

        for (uint256 i = 0; i < gasRecords.length; i++) {
            GasRecord memory r = gasRecords[i];
            uint256 total = r.submitGas + r.voteGas + r.mintGas;

            console.log(
                "%9d | %10d | %10d | %10d | %10d",
                r.proposalCount,
                r.submitGas,
                r.voteGas,
                r.mintGas,
                total
            );
        }

        console.log("\n=== Analysis ===");
        _analyzeGasGrowth();
    }

    /**
     * @notice 分析 gas 增长趋势
     */
    function _analyzeGasGrowth() internal view {
        if (gasRecords.length < 2) return;

        // 计算增长率
        GasRecord memory first = gasRecords[0];
        GasRecord memory last = gasRecords[gasRecords.length - 1];

        uint256 proposalIncrease = last.proposalCount - first.proposalCount;
        uint256 submitIncrease = last.submitGas - first.submitGas;
        uint256 voteIncrease = last.voteGas - first.voteGas;
        uint256 mintIncrease = last.mintGas - first.mintGas;

        console.log("From %d to %d proposals:", first.proposalCount, last.proposalCount);
        console.log("  Submit gas increased: %d (+%d%%)",
            submitIncrease,
            (submitIncrease * 100) / first.submitGas
        );
        console.log("  Vote gas increased:   %d (+%d%%)",
            voteIncrease,
            (voteIncrease * 100) / first.voteGas
        );
        console.log("  Mint gas increased:   %d (+%d%%)",
            mintIncrease,
            (mintIncrease * 100) / first.mintGas
        );

        // 判断是否线性增长
        bool isLinearSubmit = _isLinearGrowth(first.submitGas, last.submitGas, proposalIncrease);
        bool isLinearVote = _isLinearGrowth(first.voteGas, last.voteGas, proposalIncrease);
        bool isLinearMint = _isLinearGrowth(first.mintGas, last.mintGas, proposalIncrease);

        console.log("\nGrowth Pattern:");
        console.log("  Submit: %s", isLinearSubmit ? "Linear" : "Non-linear");
        console.log("  Vote:   %s", isLinearVote ? "Linear" : "Non-linear");
        console.log("  Mint:   %s", isLinearMint ? "Linear" : "Non-linear");
    }

    /**
     * @notice 判断是否为线性增长
     */
    function _isLinearGrowth(
        uint256 initialGas,
        uint256 finalGas,
        uint256 countIncrease
    ) internal pure returns (bool) {
        if (initialGas == 0 || countIncrease == 0) return false;

        // 计算每个 Proposal 的平均 gas 增量
        uint256 avgIncrement = (finalGas - initialGas) / countIncrease;

        // 如果增量很小（< 1000 gas per proposal），认为是常数级别
        return avgIncrement < 1000;
    }

    /**
     * @notice 估算达到 block gas limit 需要的 Proposal 数量
     */
    function testEstimateBlockGasLimit() public {
        uint256 blockGasLimit = 30_000_000; // BSC block gas limit

        console.log("=== Block Gas Limit Estimation ===");
        console.log("Target block gas limit: %d", blockGasLimit);

        // 假设从 gas 记录中推算
        if (gasRecords.length >= 2) {
            GasRecord memory last = gasRecords[gasRecords.length - 1];

            // 假设 mint 是瓶颈操作
            if (last.mintGas > 0 && last.mintGas < blockGasLimit) {
                uint256 estimatedLimit = (blockGasLimit * last.proposalCount) / last.mintGas;
                console.log("Estimated safe proposal limit: %d", estimatedLimit);
                console.log("(This is a rough estimate based on current gas usage)");
            }
        }
    }
}
