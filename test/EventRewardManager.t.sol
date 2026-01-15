// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { EventRewardManager } from "../src/EventRewardManager.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockERC20 is IERC20 {
    string public name = "MockToken";
    string public symbol = "MCK";
    uint8 public decimals = 18;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    function totalSupply() external pure override returns (uint256) {
        return 0;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address owner, address to, uint256 amount) external override returns (bool) {
        require(allowance[owner][msg.sender] >= amount, "not approved");
        allowance[owner][msg.sender] -= amount;

        balanceOf[owner] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract EventRewardManagerTest is Test {
    EventRewardManager bounty;
    MockERC20 tokenA;
    MockERC20 tokenB;

    address admin = address(1);
    address auditor = address(2);
    address funder = address(3);
    address[] users = new address[](1);
    uint256[] amounts = new uint256[](1);
    uint256[] amtA = new uint256[](1);
    uint256[] amtB = new uint256[](1);

    function setUp() public {
        // Deploy implementation
        EventRewardManager implementation = new EventRewardManager();

        // Encode initializer call
        bytes memory initData = abi.encodeWithSelector(EventRewardManager.initialize.selector, admin);

        // Deploy UUPS Proxy
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        // Treat proxy as EventRewardManager
        bounty = EventRewardManager(address(proxy));

        // Deploy mock tokens
        tokenA = new MockERC20();
        tokenB = new MockERC20();

        // Label for debugging readability
        vm.label(admin, "Admin");
        vm.label(auditor, "Auditor");
        vm.label(funder, "Funder");
        vm.label(address(tokenA), "TokenA");
        vm.label(address(tokenB), "TokenB");
        vm.label(address(proxy), "AuditBountyProxy");

        // Set supported tokens
        vm.startPrank(admin);
        bounty.setSupportedToken(address(tokenA), true);
        bounty.setSupportedToken(address(tokenB), true);
        vm.stopPrank();

        // Mint tokens to funder
        tokenA.mint(funder, 1_000_000 ether);
        tokenB.mint(funder, 1_000_000 ether);
    }

    /* -------------------------------------------------------
                        FUNDING TEST
    ------------------------------------------------------- */

    function testFundBounty() public {
        vm.startPrank(funder);
        tokenA.approve(address(bounty), 500 ether);
        bounty.fundBounty(address(tokenA), 500 ether);
        vm.stopPrank();

        (, , , uint256 balance) = bounty.getTokenStats(address(tokenA));
        assertEq(balance, 500 ether, "Funding incorrect");

        uint256 funded = bounty.totalFundedByToken(address(tokenA));
        assertEq(funded, 500 ether, "Funded stat mismatch");
    }

    /* -------------------------------------------------------
                        REWARD SETTING
    ------------------------------------------------------- */

    function testAddRewardAndClaim() public {
        // Fund the pool first
        vm.startPrank(funder);
        tokenA.approve(address(bounty), 1000 ether);
        bounty.fundBounty(address(tokenA), 1000 ether);
        vm.stopPrank();

        // Set reward

        users[0] = auditor;
        amounts[0] = 100 ether;

        vm.startPrank(admin);
        bounty.batchAddRewards(address(tokenA), users, amounts);
        vm.stopPrank();

        // Verify pending
        uint256 pending = bounty.getUserInfo(address(tokenA), auditor);
        assertEq(pending, 100 ether);

        // Auditor claims
        vm.startPrank(auditor);
        bounty.claimReward(address(tokenA));
        vm.stopPrank();

        // Verify transfer
        assertEq(tokenA.balanceOf(auditor), 100 ether, "Claim failed");

        // Verify pending cleared
        assertEq(bounty.getUserInfo(address(tokenA), auditor), 0);
    }

    /* -------------------------------------------------------
                        MULTI-TOKEN TEST
    ------------------------------------------------------- */

    function testMultiTokenRewards() public {
        // Fund both pools
        vm.startPrank(funder);
        tokenA.approve(address(bounty), 1000 ether);
        tokenB.approve(address(bounty), 2000 ether);
        bounty.fundBounty(address(tokenA), 1000 ether);
        bounty.fundBounty(address(tokenB), 2000 ether);
        vm.stopPrank();

        // Assign rewards
        users[0] = auditor;

        amtA[0] = 80 ether;
        amtB[0] = 150 ether;

        vm.startPrank(admin);
        bounty.batchAddRewards(address(tokenA), users, amtA);
        bounty.batchAddRewards(address(tokenB), users, amtB);
        vm.stopPrank();

        // Claim tokenA
        vm.startPrank(auditor);
        bounty.claimReward(address(tokenA));
        // Claim tokenB
        bounty.claimReward(address(tokenB));
        vm.stopPrank();

        assertEq(tokenA.balanceOf(auditor), 80 ether);
        assertEq(tokenB.balanceOf(auditor), 150 ether);
    }

    /* -------------------------------------------------------
                        PAUSE TEST
    ------------------------------------------------------- */

    function testPauseClaim() public {
        // Fund pool
        vm.startPrank(funder);
        tokenA.approve(address(bounty), 100 ether);
        bounty.fundBounty(address(tokenA), 100 ether);
        vm.stopPrank();

        // Add reward
        users[0] = auditor;
        amounts[0] = 50 ether;

        vm.startPrank(admin);
        bounty.batchAddRewards(address(tokenA), users, amounts);
        bounty.pause();
        vm.stopPrank();

        // Claiming should revert
        vm.startPrank(auditor);
        vm.expectRevert();
        bounty.claimReward(address(tokenA));
        vm.stopPrank();
    }

    /* -------------------------------------------------------
                        EMERGENCY WITHDRAW
    ------------------------------------------------------- */

    function testEmergencyWithdraw() public {
        // Fund pool
        vm.startPrank(funder);
        tokenA.approve(address(bounty), 1000 ether);
        bounty.fundBounty(address(tokenA), 1000 ether);
        vm.stopPrank();

        // Add reward 100
        users[0] = auditor;
        amounts[0] = 100 ether;

        vm.startPrank(admin);
        bounty.batchAddRewards(address(tokenA), users, amounts);
        vm.stopPrank();

        // Only 900 can be withdrawn (excess)
        vm.startPrank(admin);
        bounty.emergencyWithdraw(address(tokenA), admin, 900 ether);
        vm.stopPrank();

        assertEq(tokenA.balanceOf(admin), 900 ether);
    }

    /* -------------------------------------------------------
                 ADDITIONAL COVERAGE TESTS
------------------------------------------------------- */

    /// @notice setSupportedToken: disable token, re-enable token
    function testSetSupportedTokenEnableDisable() public {
        vm.startPrank(admin);

        // Disable tokenA
        bounty.setSupportedToken(address(tokenA), false);
        assertEq(bounty.supportedTokens(address(tokenA)), false);

        // Re-enable tokenA
        bounty.setSupportedToken(address(tokenA), true);
        assertEq(bounty.supportedTokens(address(tokenA)), true);

        vm.stopPrank();
    }

    /// @notice Unsupported token should revert on fund
    function testFundUnsupportedTokenRevert() public {
        MockERC20 unsupported = new MockERC20();
        unsupported.mint(funder, 100 ether);

        vm.startPrank(funder);
        unsupported.approve(address(bounty), 100 ether);
        vm.expectRevert("Token not supported");
        bounty.fundBounty(address(unsupported), 100 ether);
        vm.stopPrank();
    }

    /// @notice Array length mismatch for batchAddRewards
    function testBatchAddRewardsArrayLengthMismatch() public {
        address[] memory user = new address[](1);
        uint256[] memory amount = new uint256[](2);
        user[0] = auditor;

        amount[0] = 10 ether;
        amount[1] = 20 ether;

        vm.startPrank(admin);
        vm.expectRevert("Array length mismatch");
        bounty.batchAddRewards(address(tokenA), user, amount);
        vm.stopPrank();
    }

    /// @notice batchSetRewards adjusting up & down
    function testBatchSetRewardsAdjust() public {
        // Fund pool
        vm.startPrank(funder);
        tokenA.approve(address(bounty), 1000 ether);
        bounty.fundBounty(address(tokenA), 1000 ether);
        vm.stopPrank();

        // Initial assignment
        users[0] = auditor;
        amounts[0] = 100 ether;

        vm.startPrank(admin);
        bounty.batchAddRewards(address(tokenA), users, amounts);

        // Now override to bigger amount: 150
        uint256[] memory newAmounts = new uint256[](1);
        newAmounts[0] = 150 ether;

        bounty.batchSetRewards(address(tokenA), users, newAmounts);
        vm.stopPrank();

        // Verify increase reflected
        assertEq(bounty.pendingRewards(address(tokenA), auditor), 150 ether);
        assertEq(bounty.totalPendingByToken(address(tokenA)), 150 ether);
    }

    /// @notice batchClearRewards for multiple users
    function testBatchClearRewardsMultiple() public {
        vm.startPrank(funder);
        tokenA.approve(address(bounty), 1000 ether);
        bounty.fundBounty(address(tokenA), 1000 ether);
        vm.stopPrank();
        address[] memory user = new address[](2);
        uint256[] memory amount = new uint256[](2);
        user[0] = auditor;
        user[1] = address(0x123);

        amount[0] = 70 ether;
        amount[1] = 30 ether;
        vm.startPrank(admin);
        bounty.batchAddRewards(address(tokenA), user, amount);
        vm.stopPrank();

        // Clear the rewards
        vm.startPrank(admin);
        bounty.batchClearRewards(address(tokenA), user);
        vm.stopPrank();

        assertEq(bounty.pendingRewards(address(tokenA), auditor), 0);
        assertEq(bounty.pendingRewards(address(tokenA), address(0x123)), 0);
        assertEq(bounty.totalPendingByToken(address(tokenA)), 0);
    }

    /// @notice Claim with zero pending reward reverts
    function testClaimZeroRewardRevert() public {
        vm.startPrank(auditor);
        vm.expectRevert("No pending reward");
        bounty.claimReward(address(tokenA));
        vm.stopPrank();
    }

    /// @notice Claim with insufficient pool balance reverts
    function testClaimInsufficientBalanceRevert() public {
        users[0] = auditor;
        amounts[0] = 100 ether;

        vm.startPrank(admin);
        bounty.batchAddRewards(address(tokenA), users, amounts);
        vm.stopPrank();

        // no funding done → balance = 0
        vm.startPrank(auditor);
        vm.expectRevert("Insufficient contract balance");
        bounty.claimReward(address(tokenA));
        vm.stopPrank();
    }

    /// @notice emergency withdraw: revert when trying to withdraw more than excess
    function testEmergencyWithdrawExceedsExcessRevert() public {
        // fund pool = 1000
        vm.startPrank(funder);
        tokenA.approve(address(bounty), 1000 ether);
        bounty.fundBounty(address(tokenA), 1000 ether);
        vm.stopPrank();

        // Assign pending = 400
        users[0] = auditor;
        amounts[0] = 400 ether;

        vm.startPrank(admin);
        bounty.batchAddRewards(address(tokenA), users, amounts);
        vm.stopPrank();

        // Excess = 600 → try withdrawing 700 → revert
        vm.startPrank(admin);
        vm.expectRevert("Amount exceeds excess funds");
        bounty.emergencyWithdraw(address(tokenA), admin, 700 ether);
        vm.stopPrank();
    }

    /// @notice Test: getTokenStats / getAllKnownTokens
    function testViewFunctions() public {
        vm.startPrank(funder);
        tokenA.approve(address(bounty), 100 ether);
        bounty.fundBounty(address(tokenA), 100 ether);
        vm.stopPrank();

        (uint256 funded, uint256 pending, uint256 claimed, uint256 balance) = bounty.getTokenStats(address(tokenA));

        assertEq(funded, 100 ether);
        assertEq(pending, 0);
        assertEq(claimed, 0);
        assertEq(balance, 100 ether);

        address[] memory list = bounty.getAllKnownTokens();
        // tokenA + tokenB
        assertEq(list.length, 2);
    }
}
