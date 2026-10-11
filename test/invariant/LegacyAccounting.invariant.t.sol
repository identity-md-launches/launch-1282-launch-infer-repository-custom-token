// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {InferFixtures, BurnableLegacy} from "../helpers/InferFixtures.sol";
import {InferToken} from "src/InferToken.sol";
import {LegacyRedeemer} from "src/LegacyRedeemer.sol";

contract LegacyAccountingHandler is InferFixtures {
    InferToken public token;
    BurnableLegacy public a;
    BurnableLegacy public b;
    LegacyRedeemer public redeemer;
    address[4] public actors;
    uint256[4] public earned;
    uint256[2] public inputsBurned;
    uint256 public funded;
    uint256 public swept;

    constructor() {
        token = new InferToken();
        a = new BurnableLegacy();
        b = new BurnableLegacy();
        redeemer = _redeemer(token, a, b);
        funded = ALLOCATION_A + ALLOCATION_B;
        token.transfer(address(redeemer), funded);
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("legacy actor ", vm.toString(i)));
            a.mint(actors[i], 2_000_000e18);
            b.mint(actors[i], 2_000_000_000e18);
            vm.startPrank(actors[i]);
            a.approve(address(redeemer), type(uint256).max);
            b.approve(address(redeemer), type(uint256).max);
            vm.stopPrank();
        }
        // Begin with live vesting debt in both slots, rather than an invariant over an empty ledger.
        redeem(0, false, 300_000e18);
        redeem(1, true, 200_000_000e18);
    }

    function redeem(uint256 actorSeed, bool slotB, uint256 amount) public {
        uint256 i = actorSeed % actors.length;
        BurnableLegacy legacy = slotB ? b : a;
        uint256 slot = slotB ? 1 : 0;
        uint256 rate = slotB ? RATE_B : RATE_A;
        uint256 allocation = slotB ? ALLOCATION_B : ALLOCATION_A;
        if (block.timestamp >= redeemer.closesAt()) {
            vm.prank(actors[i]);
            vm.expectRevert(LegacyRedeemer.Closed.selector);
            redeemer.redeem(legacy, 1);
            return;
        }
        uint256 left = allocation - redeemer.redeemed(address(legacy));
        uint256 maxIn = ((left + 1) * 1e18 - 1) / rate;
        maxIn = min(maxIn, legacy.balanceOf(actors[i]));
        uint256 minIn = (1e18 + rate - 1) / rate;
        if (maxIn < minIn) return;
        amount = bound(amount, minIn, maxIn);
        uint256 supplyBefore = legacy.totalSupply();
        uint256 balanceBefore = legacy.balanceOf(actors[i]);
        vm.prank(actors[i]);
        uint256 out = redeemer.redeem(legacy, amount);
        // Independent rounding bounds: payout may round down by less than one wei, never up.
        assertLe(out * 1e18, amount * rate);
        assertLt(amount * rate, (out + 1) * 1e18);
        assertEq(legacy.totalSupply(), supplyBefore - amount);
        assertEq(legacy.balanceOf(actors[i]), balanceBefore - amount);
        inputsBurned[slot] += amount;
        earned[i] += out;
    }

    function claim(uint256 actorSeed) public {
        address actor = actors[actorSeed % actors.length];
        uint256 ready = redeemer.claimable(actor);
        uint256 beforeBalance = token.balanceOf(actor);
        vm.prank(actor);
        if (ready == 0) vm.expectRevert(LegacyRedeemer.NothingOut.selector);
        uint256 paid = redeemer.claim();
        if (ready != 0) {
            assertEq(paid, ready);
            assertEq(token.balanceOf(actor), beforeBalance + ready);
            assertEq(redeemer.claimable(actor), 0);
        }
    }

    function elapse(uint256 seconds_) public {
        vm.warp(block.timestamp + bound(seconds_, 0, 35 days));
    }

    function donate(uint256 amount) public {
        amount = bound(amount, 0, token.balanceOf(address(this)));
        token.transfer(address(redeemer), amount);
        funded += amount;
    }

    function upkeep(bool slotB, uint256 steps) public {
        BurnableLegacy legacy = slotB ? b : a;
        steps = bound(steps, 0, 32);
        // A separate donation pays for clock upkeep; it must never create an INFER entitlement.
        legacy.mint(address(redeemer), steps);
        redeemer.advanceClock(legacy, steps);
        assertEq(legacy.balanceOf(address(redeemer)), 0);
    }

    function sweep() public {
        if (block.timestamp < redeemer.closesAt()) {
            vm.expectRevert(abi.encodeWithSelector(LegacyRedeemer.StillOpen.selector, uint256(redeemer.closesAt())));
            redeemer.sweep();
            return;
        }
        uint256 beforeBalance = token.balanceOf(TREASURY);
        uint256 debt = redeemer.owedVesting();
        redeemer.sweep();
        swept += token.balanceOf(TREASURY) - beforeBalance;
        assertEq(token.balanceOf(address(redeemer)), debt, "sweep must preserve every vesting liability");
    }

    function assertAccounting() public view {
        uint256 debt;
        uint256 paid;
        uint256 promised;
        for (uint256 i; i < actors.length; ++i) {
            (uint128 total, uint128 claimed,) = redeemer.vestingOf(actors[i]);
            uint256 received = token.balanceOf(actors[i]);
            assertLe(claimed, total);
            assertEq(received + uint256(total) - claimed, earned[i], "wallet's lifetime entitlement lost or duplicated");
            assertLe(redeemer.claimable(actors[i]), uint256(total) - claimed);
            assertLe(redeemer.paidImmediately(address(a), actors[i]), redeemer.immediateCapA());
            assertLe(redeemer.paidImmediately(address(b), actors[i]), 930_000e18);
            debt += uint256(total) - claimed;
            paid += received;
            promised += earned[i];
        }
        assertEq(redeemer.owedVesting(), debt);
        assertGe(token.balanceOf(address(redeemer)), debt);
        assertEq(token.balanceOf(address(redeemer)) + paid + swept, funded);
        assertEq(token.balanceOf(TREASURY), swept);
        assertEq(promised, redeemer.redeemed(address(a)) + redeemer.redeemed(address(b)));
        assertLe(redeemer.redeemed(address(a)), ALLOCATION_A);
        assertLe(redeemer.redeemed(address(b)), ALLOCATION_B);
        assertEq(redeemer.burned(address(a)), inputsBurned[0]);
        assertEq(redeemer.burned(address(b)), inputsBurned[1]);
        assertEq(a.totalSupply() + inputsBurned[0], 8_000_000e18);
        assertEq(b.totalSupply() + inputsBurned[1], 8_000_000_000e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function finish() external {
        vm.warp(max(block.timestamp, uint256(redeemer.closesAt()) + 91 days));
        for (uint256 i; i < actors.length; ++i) {
            claim(i);
        }
        sweep();
        assertEq(redeemer.owedVesting(), 0);
        assertEq(token.balanceOf(address(redeemer)), 0);
        assertAccounting();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract LegacyAccountingInvariantTest is InferFixtures {
    LegacyAccountingHandler internal handler;

    function setUp() public {
        handler = new LegacyAccountingHandler();
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.redeem.selector;
        selectors[1] = handler.claim.selector;
        selectors[2] = handler.elapse.selector;
        selectors[3] = handler.donate.selector;
        selectors[4] = handler.upkeep.selector;
        selectors[5] = handler.sweep.selector;
        // Caller roles are selected inside the handler; keep the outer sender local on forks.
        targetSender(address(this));
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_legacyBurnsAndInferLiabilitiesConserveValue() public view {
        handler.assertAccounting();
    }

    function afterInvariant() public {
        handler.finish();
    }
}
