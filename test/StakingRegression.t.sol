// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {InferToken} from "src/InferToken.sol";
import {StakedInfer} from "src/StakedInfer.sol";
import {InferDripper} from "src/InferDripper.sol";

contract ReferenceVault is ERC4626 {
    constructor(IERC20 token) ERC20("Reference", "REF") ERC4626(token) {}

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }
}

contract StakingRegressionTest is Test {
    InferToken token;
    StakedInfer vault;
    address alice = makeAddr("alice");
    address mallory = makeAddr("mallory");
    address recipient = makeAddr("recipient");

    function setUp() public {
        token = new InferToken();
        vault = new StakedInfer(token);
        token.transfer(alice, 10_000e18);
        token.transfer(mallory, 10_000e18);
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(mallory);
        token.approve(address(vault), type(uint256).max);
    }

    function _matureAlice() private returns (uint256 shares) {
        vm.prank(alice);
        shares = vault.deposit(1_000e18, alice);
        vm.roll(block.number + 10);
    }

    /// @dev b45095aca81c: the stranger's shares are held, the victim's older shares are not.
    function test_dustDepositDoesNotBlockOlderShares() public {
        uint256 oldShares = _matureAlice();
        vm.prank(mallory);
        uint256 dust = vault.deposit(1, alice);
        assertEq(vault.maxRedeem(alice), oldShares);
        assertEq(vault.maxWithdraw(alice), 1_000e18);
        assertEq(vault.lockedShares(alice), dust);
        vm.prank(alice);
        assertEq(vault.redeem(oldShares, alice, alice), 1_000e18);
        assertEq(vault.maxRedeem(alice), 0);
        vm.roll(block.number + 1);
        vm.prank(alice);
        assertEq(vault.redeem(dust, alice, alice), 1);
    }

    function test_dustMintDoesNotBlockWithdrawOrDelegatedExit() public {
        uint256 oldShares = _matureAlice();
        vm.prank(mallory);
        vault.mint(1e6, alice);
        vm.prank(alice);
        vault.approve(recipient, oldShares);
        vm.prank(recipient);
        assertEq(vault.withdraw(1_000e18, alice, alice), oldShares);
        assertEq(vault.allowance(alice, recipient), 0);
        assertEq(vault.lockedShares(alice), 1e6);
        assertEq(vault.maxRedeem(alice), 0);
    }

    function test_freshDepositToAnotherReceiverCannotBypassTheHold() public {
        vm.prank(mallory);
        uint256 shares = vault.deposit(1_000e18, recipient);
        vm.prank(recipient);
        vault.approve(mallory, shares);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, recipient, shares, 0));
        vault.redeem(shares, mallory, recipient);
        vm.prank(recipient);
        vault.transfer(mallory, shares);
        assertEq(vault.lockedShares(mallory), shares);
        assertEq(vault.lockedShares(recipient), 0);
        assertEq(vault.maxWithdraw(mallory), 0);
        vm.roll(block.number + 1);
        vm.prank(mallory);
        assertEq(vault.redeem(shares, mallory, mallory), 1_000e18);
    }

    function test_freshShareDustCannotHoldTheRecipientsOlderShares() public {
        uint256 oldShares = _matureAlice();
        vm.prank(mallory);
        uint256 shares = vault.deposit(1, mallory);
        vm.prank(mallory);
        vault.transfer(alice, shares);
        assertEq(vault.maxRedeem(alice), oldShares);
        assertEq(vault.lockedShares(alice), shares);
        vm.prank(alice);
        vault.withdraw(1_000e18, alice, alice);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.maxRedeem(alice), 0);
    }

    function test_transfersSpendUnlockedSharesFirstAndCarryOnlyTheHeldPart() public {
        uint256 oldShares = _matureAlice();
        vm.prank(alice);
        uint256 newShares = vault.deposit(100e18, alice);
        vm.prank(alice);
        vault.approve(recipient, oldShares + newShares);
        vm.prank(recipient);
        vault.transferFrom(alice, mallory, oldShares + newShares / 2);
        assertEq(vault.maxRedeem(mallory), oldShares);
        assertEq(vault.lockedShares(mallory), newShares / 2);
        assertEq(vault.lockedShares(alice), newShares / 2);
        assertEq(vault.maxRedeem(alice), 0);
        vm.prank(mallory);
        vault.transfer(recipient, oldShares);
        assertEq(vault.maxRedeem(recipient), oldShares);
        assertEq(vault.lockedShares(mallory), newShares / 2);
    }

    function test_zeroAndSelfTransfersCannotRefreshOrShedTheHold() public {
        uint256 oldShares = _matureAlice();
        uint256 stamp = vault.lastDepositBlock(alice);
        vm.startPrank(mallory);
        vault.deposit(0, alice);
        vault.mint(0, alice);
        vault.transfer(alice, 0);
        vm.stopPrank();
        assertEq(vault.lastDepositBlock(alice), stamp);
        assertEq(vault.maxRedeem(alice), oldShares);
        vm.startPrank(alice);
        uint256 fresh = vault.deposit(10e18, alice);
        vault.transfer(alice, vault.balanceOf(alice));
        vm.stopPrank();
        assertEq(vault.lockedShares(alice), fresh);
        assertEq(vault.maxRedeem(alice), oldShares);
        vm.roll(block.number + 1);
        vm.prank(alice);
        uint256 newest = vault.deposit(1, alice);
        assertEq(vault.lockedShares(alice), newest);
        assertEq(vault.maxRedeem(alice), oldShares + fresh);
    }

    function testFuzz_movingSharesPreservesTheHold(uint256 oldAssets, uint256 newAssets, uint256 moved) public {
        oldAssets = bound(oldAssets, 1, 1_000e18);
        newAssets = bound(newAssets, 1, 1_000e18);
        vm.prank(alice);
        uint256 older = vault.deposit(oldAssets, alice);
        vm.roll(block.number + 1);
        vm.prank(alice);
        uint256 fresh = vault.deposit(newAssets, alice);
        moved = bound(moved, 0, older + fresh);
        vm.prank(alice);
        vault.transfer(mallory, moved);
        assertEq(vault.lockedShares(alice) + vault.lockedShares(mallory), fresh);
        assertEq(vault.maxRedeem(alice) + vault.maxRedeem(mallory), older);
        vm.prank(mallory);
        vault.transfer(recipient, moved);
        assertEq(vault.lockedShares(alice) + vault.lockedShares(recipient), fresh);
        vm.roll(block.number + 1);
        assertEq(vault.maxRedeem(alice) + vault.maxRedeem(recipient), older + fresh);
    }

    /// @dev The local static-decimals base must retain the vendored vault's exchange rates and rounding.
    function testFuzz_matchesVendoredERC4626AfterTheHold(uint256 assets, uint256 donation, uint256 mintShares) public {
        assets = bound(assets, 1, 1_000_000e18);
        donation = bound(donation, 0, 1_000_000e18);
        ReferenceVault baseline = new ReferenceVault(token);
        token.approve(address(baseline), type(uint256).max);
        token.approve(address(vault), type(uint256).max);
        assertEq(vault.deposit(assets, address(this)), baseline.deposit(assets, address(this)));
        token.transfer(address(vault), donation);
        token.transfer(address(baseline), donation);
        mintShares = bound(mintShares, 1, vault.previewDeposit(1_000e18));
        assertEq(vault.decimals(), baseline.decimals());
        assertEq(vault.previewDeposit(assets), baseline.previewDeposit(assets));
        assertEq(vault.previewMint(mintShares), baseline.previewMint(mintShares));
        assertEq(vault.mint(mintShares, address(this)), baseline.mint(mintShares, address(this)));
        vm.roll(block.number + 1);
        uint256 take = vault.maxWithdraw(address(this)) / 2;
        assertEq(take, baseline.maxWithdraw(address(this)) / 2);
        assertEq(vault.previewWithdraw(take), baseline.previewWithdraw(take));
        assertEq(
            vault.withdraw(take, address(this), address(this)), baseline.withdraw(take, address(this), address(this))
        );
        uint256 shares = vault.maxRedeem(address(this));
        assertEq(shares, baseline.maxRedeem(address(this)));
        assertEq(
            vault.redeem(shares, address(this), address(this)), baseline.redeem(shares, address(this), address(this))
        );
        assertEq(vault.totalAssets(), baseline.totalAssets());
        assertEq(vault.totalSupply(), 0);
    }
}

contract DripperRegressionTest is Test {
    InferToken token;
    StakedInfer vault;
    InferDripper dripper;
    uint256 constant MIN_DRIP = 1_000e18;
    address keeper = makeAddr("keeper");

    function setUp() public {
        token = new InferToken();
        vault = new StakedInfer(token);
        dripper = new InferDripper(address(token), address(vault), MIN_DRIP);
        token.approve(address(vault), 10_000e18);
        vault.deposit(10_000e18, address(this));
    }

    /// @dev 75c201f59354: the exact 100k buyback now fully drains after 100 hourly steps.
    function test_smallBuybackReachesStakersAndDoesNotLeaveATail() public {
        token.transfer(address(dripper), 100_000e18);
        for (uint256 i; i < 100; ++i) {
            vm.warp(block.timestamp + 1 hours);
            assertTrue(dripper.canDrip());
            assertEq(dripper.releasable(), MIN_DRIP);
            vm.prank(keeper);
            dripper.drip();
            assertFalse(dripper.canDrip());
        }
        assertEq(token.balanceOf(address(dripper)), 0);
        assertEq(vault.totalAssets(), 109_000e18);
        assertEq(token.balanceOf(keeper), 1_000e18);
        vm.warp(block.timestamp + 365 days);
        assertFalse(dripper.canDrip());
        vm.expectRevert(abi.encodeWithSelector(InferDripper.BelowMinDrip.selector, 0, MIN_DRIP));
        dripper.drip();
    }

    function test_fullHourIsRequiredForTheFloorAndFinalDust() public {
        token.transfer(address(dripper), MIN_DRIP + 1);
        vm.warp(block.timestamp + 1 hours - 1);
        assertFalse(dripper.canDrip());
        vm.expectRevert(abi.encodeWithSelector(InferDripper.BelowMinDrip.selector, dripper.releasable(), MIN_DRIP));
        dripper.drip();
        vm.warp(block.timestamp + 1);
        vm.prank(keeper);
        dripper.drip();
        assertEq(token.balanceOf(address(dripper)), 1);
        assertFalse(dripper.canDrip());
        vm.warp(block.timestamp + 1 hours);
        assertTrue(dripper.canDrip());
        vm.prank(keeper);
        (uint256 paid, uint256 fee) = dripper.drip();
        assertEq(paid, 1);
        assertEq(fee, 0);
        assertEq(token.balanceOf(address(dripper)), 0);
    }

    function test_largeBufferKeepsItsNormalRateThenCrossesIntoTheFloor() public {
        token.transfer(address(dripper), 336_000e18);
        vm.warp(block.timestamp + 30 minutes);
        assertEq(dripper.releasable(), MIN_DRIP);
        assertTrue(dripper.canDrip());
        dripper.drip();
        uint256 balance = token.balanceOf(address(dripper));
        vm.warp(block.timestamp + 30 days);
        assertEq(dripper.releasable(), balance / 168);
        dripper.drip();
        for (uint256 i; i < 400 && token.balanceOf(address(dripper)) != 0; ++i) {
            vm.warp(block.timestamp + 1 hours);
            dripper.drip();
        }
        assertEq(token.balanceOf(address(dripper)), 0);
    }

    function testFuzz_finalBalanceIsReleasedExactlyOnce(uint256 amount) public {
        amount = bound(amount, 1, MIN_DRIP);
        token.transfer(address(dripper), amount);
        vm.warp(block.timestamp + 1 hours);
        assertEq(dripper.releasable(), amount);
        assertTrue(dripper.canDrip());
        vm.prank(keeper);
        (uint256 paid, uint256 fee) = dripper.drip();
        assertEq(paid + fee, amount);
        assertEq(fee, amount / 100);
        assertEq(token.balanceOf(address(dripper)), 0);
        assertFalse(dripper.canDrip());
        vm.expectRevert(abi.encodeWithSelector(InferDripper.BelowMinDrip.selector, 0, MIN_DRIP));
        dripper.drip();
    }

    function test_floorStillRefusesAnEmptyVault() public {
        vm.roll(block.number + 1);
        vault.redeem(vault.balanceOf(address(this)), address(this), address(this));
        token.transfer(address(dripper), 1);
        vm.warp(block.timestamp + 1 hours);
        assertFalse(dripper.canDrip());
        vm.expectRevert(InferDripper.VaultEmpty.selector);
        dripper.drip();
        assertEq(token.balanceOf(address(dripper)), 1);
    }
}
