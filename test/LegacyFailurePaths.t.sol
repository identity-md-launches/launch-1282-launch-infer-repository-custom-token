// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {InferFixtures, BurnableLegacy} from "./helpers/InferFixtures.sol";
import {InferToken} from "src/InferToken.sol";
import {LegacyRedeemer} from "src/LegacyRedeemer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract LegacyFailurePathsTest is InferFixtures {
    InferToken internal token;
    BurnableLegacy internal a;
    BurnableLegacy internal b;
    LegacyRedeemer internal r;
    address internal alice;
    address internal bob;

    function setUp() public {
        token = new InferToken();
        a = new BurnableLegacy();
        b = new BurnableLegacy();
        r = _redeemer(token, a, b);
        alice = makeAddr("legacy failure alice");
        bob = makeAddr("legacy failure bob");
        token.transfer(address(r), 140_000_000e18);
        a.mint(alice, 5_000_000e18);
        b.mint(alice, 6_000_000_000e18);
        vm.startPrank(alice);
        a.approve(address(r), type(uint256).max);
        b.approve(address(r), type(uint256).max);
        vm.stopPrank();
    }

    function _state() internal view returns (bytes32) {
        (uint128 total, uint128 claimed, uint64 start) = r.vestingOf(alice);
        bytes32 accounting = keccak256(
            abi.encode(
                total,
                claimed,
                start,
                r.owedVesting(),
                r.redeemed(address(a)),
                r.redeemed(address(b)),
                r.burned(address(a)),
                r.burned(address(b)),
                r.paidImmediately(address(a), alice),
                r.paidImmediately(address(b), alice)
            )
        );
        return keccak256(
            abi.encode(
                accounting,
                token.balanceOf(alice),
                token.balanceOf(address(r)),
                a.balanceOf(alice),
                a.balanceOf(address(r)),
                a.totalSupply(),
                a.allowance(alice, address(r)),
                b.totalSupply()
            )
        );
    }

    function test_zeroUnknownAndSubWeiOutputsRevertWithoutAccountingChanges() public {
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(LegacyRedeemer.ZeroAmount.selector);
        r.redeem(a, 0);
        IERC20 unknown = IERC20(address(token));
        bytes memory wrongToken = abi.encodeWithSelector(LegacyRedeemer.NotRedeemable.selector, address(unknown));
        vm.expectRevert(wrongToken);
        r.quote(unknown, 1);
        vm.expectRevert(wrongToken);
        r.quoteFor(alice, unknown, 1);
        vm.expectRevert(wrongToken);
        r.immediateCap(unknown);
        vm.expectRevert(wrongToken);
        r.advanceClock(unknown, 0);
        vm.prank(alice);
        vm.expectRevert(wrongToken);
        r.redeem(unknown, 1);
        uint256 smallest = (1e18 + RATE_B - 1) / RATE_B;
        vm.prank(alice);
        vm.expectRevert(LegacyRedeemer.NothingOut.selector);
        r.redeem(b, smallest - 1);
        assertEq(_state(), beforeState);
        vm.prank(alice);
        assertEq(r.redeem(b, smallest), 1);
        vm.prank(alice);
        assertEq(r.redeem(a, 1), 29);
    }

    function test_failedBurnRollsBackDepositAutoClaimAllowanceAndNewSchedule() public {
        vm.prank(alice);
        r.redeem(a, 300_000e18);
        vm.warp(block.timestamp + 45 days);
        uint256 ready = r.claimable(alice);
        assertGt(ready, 0);
        vm.prank(alice);
        a.approve(address(r), 10_000e18);
        a.setRejectBurn(true);
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(BurnableLegacy.BurnRejected.selector);
        r.redeem(a, 10_000e18);
        assertEq(_state(), beforeState, "failed burn must roll back the earlier automatic vested payout too");
        assertEq(r.claimable(alice), ready);
        a.setRejectBurn(false);
        vm.prank(alice);
        r.redeem(a, 10_000e18);
        assertEq(r.claimable(alice), 0);
        assertEq(a.allowance(alice, address(r)), 0);
    }

    function test_transferFailureRollsBackAnExistingVestingSchedule() public {
        vm.prank(alice);
        r.redeem(a, 300_000e18);
        vm.warp(block.timestamp + 1 days);
        a.setRejectTransfer(true);
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(BurnableLegacy.TransferRejected.selector);
        r.redeem(a, 10_000e18);
        assertEq(_state(), beforeState);
    }

    function test_noAllowanceAndInsufficientLegacyBalanceCannotConsumeAllocation() public {
        vm.prank(alice);
        a.approve(address(r), 0);
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(r), 0, 1e18));
        r.redeem(a, 1e18);
        assertEq(_state(), beforeState);
        vm.prank(bob);
        a.approve(address(r), type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, 1e18));
        r.redeem(a, 1e18);
        assertEq(_state(), beforeState);
    }

    function test_fullAllocationBoundaryRefusesOneMoreRedeemWithoutTouchingOtherSlot() public {
        uint256 maxA = ((ALLOCATION_A + 1) * 1e18 - 1) / RATE_A;
        vm.prank(alice);
        r.redeem(a, maxA);
        (, uint256 left) = r.quote(a, 0);
        uint256 excess = (left + 1) * 1e18 / RATE_A + 1;
        uint256 wanted = excess * RATE_A / 1e18;
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LegacyRedeemer.Exhausted.selector, address(a), wanted, left));
        r.redeem(a, excess);
        assertEq(_state(), beforeState);
        (, uint256 leftB) = r.quote(b, 0);
        assertEq(leftB, ALLOCATION_B);
        vm.prank(alice);
        r.redeem(b, 1e18);
    }

    function test_exactClosingBoundaryAndLateVestingStayIndependent() public {
        vm.warp(uint256(r.closesAt()) - 1);
        vm.prank(alice);
        uint256 earned = r.redeem(a, 300_000e18);
        uint256 owed = r.owedVesting();
        assertGt(owed, 0);
        vm.warp(r.closesAt());
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(LegacyRedeemer.Closed.selector);
        r.redeem(a, 1);
        assertEq(_state(), beforeState);
        r.sweep();
        assertEq(token.balanceOf(address(r)), owed);
        uint256 swept = token.balanceOf(TREASURY);
        r.sweep();
        assertEq(token.balanceOf(TREASURY), swept);
        vm.warp(block.timestamp + 91 days);
        vm.prank(alice);
        r.claim();
        assertEq(token.balanceOf(alice), earned);
        assertEq(r.owedVesting(), 0);
        assertEq(token.balanceOf(address(r)), 0);
        vm.prank(alice);
        vm.expectRevert(LegacyRedeemer.NothingOut.selector);
        r.claim();
    }

    function test_redeemingUnderOtherSlotsCapDoesNotRestartExistingVesting() public {
        vm.prank(alice);
        r.redeem(a, 300_000e18);
        (uint128 total, uint128 claimed, uint64 start) = r.vestingOf(alice);
        vm.warp(block.timestamp + 45 days);
        uint256 ready = r.claimable(alice);
        vm.prank(alice);
        r.redeem(b, 1e18);
        (uint128 totalAfter, uint128 claimedAfter, uint64 startAfter) = r.vestingOf(alice);
        assertEq(totalAfter, total);
        assertEq(claimedAfter, claimed);
        assertEq(startAfter, start);
        assertEq(r.claimable(alice), ready);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_partitioningRedemptionsCannotRoundUpOrBypassImmediateCap(uint256 amount, uint256 split) public {
        amount = bound(amount, 2, 500_000e18);
        split = bound(split, 1, amount - 1);
        vm.startPrank(alice);
        uint256 first = r.redeem(a, split);
        uint256 second = r.redeem(a, amount - split);
        vm.stopPrank();
        uint256 single = amount * RATE_A / 1e18;
        assertLe(first + second, single);
        assertLe(single - first - second, 1);
        assertEq(r.burned(address(a)), amount);
        assertEq(token.balanceOf(alice) + r.owedVesting(), first + second);
        assertLe(token.balanceOf(alice), 200_000e18 * RATE_A / 1e18);
        vm.warp(block.timestamp + 91 days);
        if (r.owedVesting() != 0) {
            vm.prank(alice);
            r.claim();
        }
        assertEq(token.balanceOf(alice), first + second);
    }

    function test_upkeepFailureIsAtomicAndDoesNotBurnUserTokens() public {
        a.mint(address(r), 3);
        uint256 supply = a.totalSupply();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(r), 0, 1));
        r.advanceClock(a, 4);
        assertEq(a.totalSupply(), supply);
        assertEq(a.balanceOf(address(r)), 3);
        r.advanceClock(a, 3);
        assertEq(a.totalSupply(), supply - 3);
        assertEq(r.burned(address(a)), 0);
        assertEq(r.redeemed(address(a)), 0);
    }
}
