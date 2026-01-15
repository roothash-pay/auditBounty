// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract EventRewardManagerStorage {
    /* ========== ROLES ========== */

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant REWARD_MANAGER_ROLE = keccak256("REWARD_MANAGER_ROLE");
    bytes32 public constant FUND_MANAGER_ROLE = keccak256("FUND_MANAGER_ROLE");

    /* ========== CONSTANTS ========== */
    address public constant ETH_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    /* ========== STORAGE ========== */

    // Supported bounty tokens
    mapping(address => bool) public supportedTokens;
    address[] public _supportedTokenList;

    // pendingRewards[token][user] = amount
    mapping(address => mapping(address => uint256)) public pendingRewards;

    // Total stats per token
    mapping(address => uint256) public totalPendingByToken; // sum of all pending rewards
    mapping(address => uint256) public totalClaimedByToken; // total claimed by all users
    mapping(address => uint256) public totalFundedByToken; // total funded into this contract

    /* ========== EVENTS ========== */

    event TokenSupportUpdated(address indexed token, bool supported);
    event RewardAdded(address indexed token, address indexed user, uint256 amount, address indexed operator);
    event RewardSet(address indexed token, address indexed user, uint256 oldAmount, uint256 newAmount, address indexed operator);
    event RewardCleared(address indexed token, address indexed user, uint256 clearedAmount, address indexed operator);

    event RewardClaimed(address indexed token, address indexed user, uint256 amount);
    event BountyFunded(address indexed token, address indexed from, uint256 amount);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount, address indexed operator);
}
