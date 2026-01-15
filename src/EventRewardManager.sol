// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./EventRewardManagerStorage.sol";

/**
 * @title EventRewardManager
 * @notice Centralized reward configuration, decentralized on-chain claiming
 * @dev
 * - Project team (admin) decides reward amounts and whitelisted recipients
 * - Recipients claim rewards themselves from this contract
 * - Supports multiple ERC20 tokens as reward currencies
 * - Upgradeable via UUPS
 */
contract EventRewardManager is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, UUPSUpgradeable, EventRewardManagerStorage {
    /* ========== CONSTRUCTOR & INITIALIZER ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @param admin Admin address
     */
    function initialize(address admin) public initializer {
        require(admin != address(0), "Invalid admin address");

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(REWARD_MANAGER_ROLE, admin);
        _grantRole(FUND_MANAGER_ROLE, admin);
    }

    /* ========== TOKEN SUPPORT MANAGEMENT ========== */

    /**
     * @notice Enable or disable a bounty token
     * @dev Only admin can manage supported tokens
     * @param token ERC20 token address
     * @param supported Whether this token is supported
     */
    function setSupportedToken(address token, bool supported) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(0), "Invalid token");

        if (supported && !supportedTokens[token]) {
            supportedTokens[token] = true;
            _supportedTokenList.push(token);
        } else if (!supported && supportedTokens[token]) {
            supportedTokens[token] = false;
            // we do not remove from array to keep it simple, UI can filter
        }

        emit TokenSupportUpdated(token, supported);
    }

    /**
     * @notice Get all tokens that have been ever marked as supported
     * @dev Frontend can filter by supportedTokens[token] == true
     */
    function getAllKnownTokens() external view returns (address[] memory) {
        return _supportedTokenList;
    }

    /* ========== FUNDING (PROJECT SIDE / ANYONE) ========== */

    /**
     * @notice Fund the bounty pool with a supported token
     * @dev
     * - `amount` is transferred from caller to this contract
     * - Emits BountyFunded event for transparency (for investors / public)
     * @param token ERC20 token address
     * @param amount Amount to fund
     */
    function fundBounty(address token, uint256 amount) external payable nonReentrant whenNotPaused {
        require(supportedTokens[token], "Token not supported");
        require(amount > 0, "Invalid amount");

        if (msg.value > 0 && token == ETH_ADDRESS) {
            require(msg.value == amount, "ETH amount mismatch");
            totalFundedByToken[token] += amount;
            emit BountyFunded(token, msg.sender, amount);
        }

        if (token != ETH_ADDRESS) {
            IERC20 erc20 = IERC20(token);

            // Transfer tokens into this contract
            require(erc20.transferFrom(msg.sender, address(this), amount), "Token transfer failed");

            totalFundedByToken[token] += amount;

            emit BountyFunded(token, msg.sender, amount);
        }
    }

    /* ========== REWARD MANAGEMENT ========== */

    /**
     * @notice Batch add rewards for users (incremental)
     * @dev Only REWARD_MANAGER_ROLE can call
     * @param token ERC20 token address
     * @param users Array of user addresses
     * @param amounts Array of reward amounts (same length as users)
     */
    function batchAddRewards(address token, address[] calldata users, uint256[] calldata amounts) external onlyRole(REWARD_MANAGER_ROLE) {
        require(supportedTokens[token], "Token not supported");
        require(users.length == amounts.length, "Array length mismatch");
        require(users.length > 0, "Empty arrays");

        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            uint256 amount = amounts[i];

            require(user != address(0), "Invalid user");
            require(amount > 0, "Invalid amount");

            pendingRewards[token][user] += amount;
            totalPendingByToken[token] += amount;

            require(totalPendingByToken[token] <= IERC20(token).balanceOf(address(this)), "Overflow");

            emit RewardAdded(token, user, amount, msg.sender);
        }
    }

    /**
     * @notice Batch set user rewards to specific values (absolute override)
     * @dev
     * - totalPendingByToken adjusted accordingly
     * - Only REWARD_MANAGER_ROLE can call
     * @param token ERC20 token address
     * @param users Array of user addresses
     * @param amounts Array of reward amounts (same length as users)
     */
    function batchSetRewards(address token, address[] calldata users, uint256[] calldata amounts) external onlyRole(REWARD_MANAGER_ROLE) {
        require(supportedTokens[token], "Token not supported");
        require(users.length == amounts.length, "Array length mismatch");
        require(users.length > 0, "Empty arrays");

        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            uint256 newAmount = amounts[i];

            require(user != address(0), "Invalid user");

            uint256 oldAmount = pendingRewards[token][user];

            if (newAmount > oldAmount) {
                totalPendingByToken[token] += (newAmount - oldAmount);
            } else if (oldAmount > newAmount) {
                totalPendingByToken[token] -= (oldAmount - newAmount);
            }

            require(totalPendingByToken[token] <= IERC20(token).balanceOf(address(this)), "Overflow");

            pendingRewards[token][user] = newAmount;

            emit RewardSet(token, user, oldAmount, newAmount, msg.sender);
        }
    }

    /**
     * @notice Batch clear pending rewards for users
     * @dev Only REWARD_MANAGER_ROLE can call
     * @param token ERC20 token address
     * @param users Array of user addresses
     */
    function batchClearRewards(address token, address[] calldata users) external onlyRole(REWARD_MANAGER_ROLE) {
        require(supportedTokens[token], "Token not supported");
        require(users.length > 0, "Empty users");

        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            require(user != address(0), "Invalid user");

            uint256 amount = pendingRewards[token][user];
            if (amount > 0) {
                pendingRewards[token][user] = 0;
                totalPendingByToken[token] -= amount;

                emit RewardCleared(token, user, amount, msg.sender);
            }
        }
    }

    /* ========== USER CLAIM ========== */

    /**
     * @notice Claim pending bounty for a specific token
     * @dev
     * - User claims for themselves
     * - Uses token balance of this contract as source
     * @param token ERC20 token address
     */
    function claimReward(address rewardAddress, address token) external nonReentrant whenNotPaused {
        require(supportedTokens[token], "Token not supported");

        uint256 pending = pendingRewards[token][rewardAddress];
        require(pending > 0, "No pending reward");

        IERC20 erc20 = IERC20(token);
        uint256 balance = erc20.balanceOf(address(this));
        require(balance >= pending, "Insufficient contract balance");

        // Update accounting
        pendingRewards[token][rewardAddress] = 0;
        totalPendingByToken[token] -= pending;
        totalClaimedByToken[token] += pending;

        // Transfer tokens to user
        require(erc20.transfer(rewardAddress, pending), "Token transfer failed");

        emit RewardClaimed(token, rewardAddress, pending);
    }

    /* ========== EMERGENCY / FUND MANAGEMENT ========== */

    /**
     * @notice Withdraw tokens from the contract in emergency
     * @dev
     * - Only DEFAULT_ADMIN_ROLE can call
     * - Can be restricted to whenPaused if desired
     * - For safety, we only allow withdrawing "excess" above totalPendingByToken,
     *   so that already-assigned rewards are backed 1:1.
     * @param token ERC20 token address
     * @param to Receiver address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(to != address(0), "Invalid receiver");
        require(amount > 0, "Invalid amount");

        IERC20 erc20 = IERC20(token);
        uint256 balance = erc20.balanceOf(address(this));

        // Do not break assigned rewards by default
        require(balance > totalPendingByToken[token], "No excess funds");
        uint256 maxWithdrawable = balance - totalPendingByToken[token];
        require(amount <= maxWithdrawable, "Amount exceeds excess funds");

        require(erc20.transfer(to, amount), "Token transfer failed");

        totalFundedByToken[token] -= amount;

        emit EmergencyWithdraw(token, to, amount, msg.sender);
    }

    /* ========== VIEW HELPERS ========== */

    /**
     * @notice Get user info for a specific token
     * @param token ERC20 token address
     * @param user User address
     * @return pending Pending reward
     */
    function getUserInfo(address token, address user) external view returns (uint256 pending) {
        return pendingRewards[token][user];
    }

    /**
     * @notice Get token-level stats
     * @param token ERC20 token address
     * @return funded Total funded amount
     * @return pending Total pending rewards
     * @return claimed Total claimed rewards
     * @return balance Current token balance in contract
     */
    function getTokenStats(address token) external view returns (uint256 funded, uint256 pending, uint256 claimed, uint256 balance) {
        IERC20 erc20 = IERC20(token);
        return (totalFundedByToken[token], totalPendingByToken[token], totalClaimedByToken[token], erc20.balanceOf(address(this)));
    }

    /* ========== PAUSE CONTROL ========== */

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /* ========== UUPS UPGRADE AUTHORIZATION ========== */

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        // Only DEFAULT_ADMIN_ROLE can upgrade
    }
}
