// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

contract MockPhase {
    uint256 private _currentPhase;

    function currentPhase() external view returns (uint256) {
        return _currentPhase;
    }

    function setPhase(uint256 phase) external {
        _currentPhase = phase;
    }

    function sync(address, uint256) external {}
}

contract MockVote {
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) private _voteAmounts;
    address public SUBMIT_ADDRESS;

    function setSubmitAddress(address submitAddress) external {
        SUBMIT_ADDRESS = submitAddress;
    }

    function voteAmountByMemberId(address tokenAddress, uint256 round, uint256 memberId)
        external
        view
        returns (uint256)
    {
        return _voteAmounts[tokenAddress][round][memberId];
    }

    function setVoteAmount(address tokenAddress, uint256 round, uint256 memberId, uint256 voteAmount) external {
        _voteAmounts[tokenAddress][round][memberId] = voteAmount;
    }
}

contract MockLaunch {
    mapping(address => bool) public isLOVE20Token;

    function register(address token) external {
        isLOVE20Token[token] = true;
    }
}

contract MockSubmit {
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) private _proposalIdBySubmitterId;

    function proposalIdBySubmitterId(address tokenAddress, uint256 round, uint256 submitterId)
        external
        view
        returns (uint256)
    {
        return _proposalIdBySubmitterId[tokenAddress][round][submitterId];
    }

    function setProposalIdBySubmitter(address tokenAddress, uint256 round, uint256 submitterId, uint256 proposalId)
        external
    {
        _proposalIdBySubmitterId[tokenAddress][round][submitterId] = proposalId;
    }
}

contract MockPairFactory {
    mapping(address => mapping(address => address)) private _pairs;

    function getPair(address tokenA, address tokenB) external view returns (address) {
        return _pairs[tokenA][tokenB];
    }

    function setPair(address tokenA, address tokenB, address pair) external {
        _pairs[tokenA][tokenB] = pair;
        _pairs[tokenB][tokenA] = pair;
    }
}
