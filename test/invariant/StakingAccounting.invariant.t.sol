// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {InferFixtures} from "../helpers/InferFixtures.sol";
import {InferToken} from "src/InferToken.sol";
import {StakedInfer} from "src/StakedInfer.sol";
import {InferDripper} from "src/InferDripper.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract StakingAccountingHandler is InferFixtures {
    InferToken public token;
    StakedInfer public vault;
    InferDripper public dripper;
    address[4] public actors;
    uint256 public deposited;
    uint256 public withdrawn;
    uint256 public donated;
    uint256 public buffered;
    uint256 public rewards;
    uint256 public fees;
    uint256 public mintedShares;
    uint256 public burnedShares;
    uint256 public lastRate;
    uint256 public heldAtBlock;
    uint256 public heldThisBlock;

    constructor() {
        token = new InferToken();
        vault = new StakedInfer(token);
        dripper = new InferDripper(address(token), address(vault), 1_000e18);
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("staking actor ", vm.toString(i)));
            token.transfer(actors[i], 10_000_000e18);
            vm.prank(actors[i]);
            token.approve(address(vault), type(uint256).max);
        }
        deposit(0, 0, 10_000e18);
        deposit(1, 1, 20_000e18);
        fund(1_000_000e18, true);
    }

    function _observe() internal {
        // Virtual shares/assets are part of the exchange rate; raw assets/supply need not be monotone.
        uint256 rate = vault.convertToAssets(1e24);
        assertGe(rate, lastRate, "an action reduced the redeemable value of an existing share");
        lastRate = rate;
        uint256 held;
        for (uint256 i; i < actors.length; ++i) {
            held += vault.lockedShares(actors[i]);
        }
        assertEq(held, block.number == heldAtBlock ? heldThisBlock : 0, "hold lost or extended by a transfer");
    }

    function _newShares(uint256 shares) internal {
        if (block.number != heldAtBlock) {
            heldAtBlock = block.number;
            heldThisBlock = 0;
        }
        heldThisBlock += shares;
        mintedShares += shares;
    }

    function deposit(uint256 payerSeed, uint256 receiverSeed, uint256 assets) public {
        address payer = actors[payerSeed % 4];
        address receiver = actors[receiverSeed % 4];
        assets = bound(assets, 0, token.balanceOf(payer));
        uint256 beforeShares = vault.balanceOf(receiver);
        uint256 preview = vault.previewDeposit(assets);
        vm.prank(payer);
        uint256 shares = vault.deposit(assets, receiver);
        assertEq(shares, preview);
        assertEq(vault.balanceOf(receiver), beforeShares + shares);
        deposited += assets;
        _newShares(shares);
        _observe();
    }

    function mint(uint256 payerSeed, uint256 receiverSeed, uint256 shares) public {
        address payer = actors[payerSeed % 4];
        address receiver = actors[receiverSeed % 4];
        shares = bound(shares, 0, vault.previewDeposit(token.balanceOf(payer)));
        uint256 preview = vault.previewMint(shares);
        uint256 beforeShares = vault.balanceOf(receiver);
        vm.prank(payer);
        uint256 assets = vault.mint(shares, receiver);
        assertEq(assets, preview);
        assertEq(vault.balanceOf(receiver), beforeShares + shares);
        if (shares != 0) assertGt(assets, 0, "free shares");
        deposited += assets;
        _newShares(shares);
        _observe();
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 shares, bool delegated) public {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        shares = bound(shares, 0, vault.balanceOf(from));
        uint256 unlockedBefore = vault.maxRedeem(from) + (from == to ? 0 : vault.maxRedeem(to));
        if (delegated) {
            address spender = actors[(fromSeed % 4 + 1) % 4];
            vm.prank(from);
            vault.approve(spender, shares);
            vm.prank(spender);
            vault.transferFrom(from, to, shares);
            assertEq(vault.allowance(from, spender), 0);
        } else {
            vm.prank(from);
            vault.transfer(to, shares);
        }
        assertEq(vault.maxRedeem(from) + (from == to ? 0 : vault.maxRedeem(to)), unlockedBefore);
        _observe();
    }

    function exit(uint256 ownerSeed, uint256 receiverSeed, uint256 amount, bool byAssets, bool delegated) public {
        address owner = actors[ownerSeed % 4];
        address receiver = actors[receiverSeed % 4];
        address caller = delegated ? actors[(ownerSeed % 4 + 1) % 4] : owner;
        amount = bound(amount, 0, byAssets ? vault.maxWithdraw(owner) : vault.maxRedeem(owner));
        uint256 expectedShares = byAssets ? vault.previewWithdraw(amount) : amount;
        uint256 expectedAssets = byAssets ? amount : vault.previewRedeem(amount);
        uint256 beforeBalance = token.balanceOf(receiver);
        if (delegated) {
            vm.prank(owner);
            vault.approve(caller, expectedShares);
        }
        vm.prank(caller);
        if (byAssets) assertEq(vault.withdraw(amount, receiver, owner), expectedShares);
        else assertEq(vault.redeem(amount, receiver, owner), expectedAssets);
        assertEq(token.balanceOf(receiver), beforeBalance + expectedAssets);
        withdrawn += expectedAssets;
        burnedShares += expectedShares;
        if (delegated) assertEq(vault.allowance(owner, caller), 0);
        _observe();
    }

    function unauthorizedExit(uint256 ownerSeed) public {
        address owner = actors[ownerSeed % 4];
        address caller = actors[(ownerSeed % 4 + 1) % 4];
        uint256 shares = vault.maxRedeem(owner);
        if (shares == 0) return;
        vm.prank(owner);
        vault.approve(caller, 0);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, caller, 0, shares));
        vault.redeem(shares, caller, owner);
    }

    function fund(uint256 amount, bool toDripper) public {
        amount = bound(amount, 0, token.balanceOf(address(this)));
        token.transfer(toDripper ? address(dripper) : address(vault), amount);
        if (toDripper) buffered += amount;
        else donated += amount;
        _observe();
    }

    function drip(uint256 keeperSeed) public {
        address keeper = actors[keeperSeed % 4];
        uint256 amount = dripper.releasable();
        uint256 last = dripper.lastDripAt();
        uint256 bufferBefore = token.balanceOf(address(dripper));
        uint256 vaultBefore = token.balanceOf(address(vault));
        uint256 keeperBefore = token.balanceOf(keeper);
        bool ready = dripper.canDrip();
        if (vault.totalSupply() == 0) {
            assertFalse(ready);
            vm.expectRevert(InferDripper.VaultEmpty.selector);
            dripper.drip();
        } else if (amount == 0 || (amount < 1_000e18 && block.timestamp - last < 1 hours)) {
            assertFalse(ready);
            vm.expectRevert(abi.encodeWithSelector(InferDripper.BelowMinDrip.selector, amount, 1_000e18));
            dripper.drip();
        } else {
            assertTrue(ready);
            vm.prank(keeper);
            (uint256 toVault, uint256 toKeeper) = dripper.drip();
            assertEq(toVault + toKeeper, amount);
            assertEq(toKeeper, amount / 100);
            assertLe(amount, bufferBefore);
            assertLe(amount, max(bufferBefore / 168, min(bufferBefore, 1_000e18)));
            assertEq(token.balanceOf(keeper), keeperBefore + toKeeper);
            assertEq(token.balanceOf(address(vault)), vaultBefore + toVault);
            assertEq(dripper.lastDripAt(), block.timestamp);
            assertFalse(dripper.canDrip(), "same-timestamp repeat must not release again");
            rewards += toVault;
            fees += toKeeper;
            _observe();
            return;
        }
        assertEq(dripper.lastDripAt(), last);
        assertEq(token.balanceOf(address(dripper)), bufferBefore);
        assertEq(token.balanceOf(address(vault)), vaultBefore);
    }

    function elapse(uint256 seconds_, uint256 blocks_) public {
        vm.warp(block.timestamp + bound(seconds_, 0, 2 hours));
        vm.roll(block.number + bound(blocks_, 0, 3));
        _observe();
    }

    function roundTrip(uint256 actorSeed, uint256 amount, uint256 cycles) public {
        address actor = actors[actorSeed % 4];
        amount = bound(amount, 0, min(token.balanceOf(actor), 1_000e18));
        cycles = bound(cycles, 1, 4);
        uint256 startBalance = token.balanceOf(actor);
        uint256 startShares = vault.balanceOf(actor);
        for (uint256 i; i < cycles; ++i) {
            vm.prank(actor);
            uint256 shares = vault.deposit(amount, actor);
            deposited += amount;
            _newShares(shares);
            _observe();
            vm.roll(block.number + 1);
            vm.prank(actor);
            uint256 returned = vault.redeem(shares, actor, actor);
            withdrawn += returned;
            burnedShares += shares;
            assertLe(returned, amount);
            _observe();
            amount = min(amount, token.balanceOf(actor));
        }
        assertLe(token.balanceOf(actor), startBalance, "repeated deposit/redeem manufactured INFER");
        assertEq(vault.balanceOf(actor), startShares);
    }

    function assertAccounting() public view {
        uint256 shares;
        uint256 assetsOwed;
        uint256 circulating =
            token.balanceOf(address(this)) + token.balanceOf(address(vault)) + token.balanceOf(address(dripper));
        for (uint256 i; i < 4; ++i) {
            shares += vault.balanceOf(actors[i]);
            circulating += token.balanceOf(actors[i]);
            assetsOwed += vault.convertToAssets(vault.balanceOf(actors[i]));
            assertLe(vault.lockedShares(actors[i]), vault.balanceOf(actors[i]));
            assertEq(vault.maxRedeem(actors[i]) + vault.lockedShares(actors[i]), vault.balanceOf(actors[i]));
            assertLe(vault.previewWithdraw(vault.maxWithdraw(actors[i])), vault.maxRedeem(actors[i]));
        }
        assertEq(shares, vault.totalSupply());
        assertEq(shares + burnedShares, mintedShares);
        assertLe(assetsOwed, vault.totalAssets());
        assertEq(vault.totalAssets() + withdrawn, deposited + donated + rewards);
        assertEq(token.balanceOf(address(dripper)) + rewards + fees, buffered);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(circulating, SUPPLY);
    }

    function finish() external {
        vm.roll(block.number + 1);
        for (uint256 i; i < 4; ++i) {
            exit(i, i, type(uint256).max, false, false);
        }
        assertEq(vault.totalSupply(), 0, "every share must be redeemable after its hold");
        assertAccounting();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract StakingAccountingInvariantTest is InferFixtures {
    StakingAccountingHandler internal handler;

    function setUp() public {
        handler = new StakingAccountingHandler();
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.mint.selector;
        selectors[2] = handler.transfer.selector;
        selectors[3] = handler.exit.selector;
        selectors[4] = handler.fund.selector;
        selectors[5] = handler.drip.selector;
        selectors[6] = handler.elapse.selector;
        selectors[7] = handler.roundTrip.selector;
        selectors[8] = handler.unauthorizedExit.selector;
        // Caller roles are selected inside the handler; keep the outer sender local on forks.
        targetSender(address(this));
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_sharesAssetsRewardsAndHoldsAreConserved() public view {
        handler.assertAccounting();
    }

    function afterInvariant() public {
        handler.finish();
    }
}
