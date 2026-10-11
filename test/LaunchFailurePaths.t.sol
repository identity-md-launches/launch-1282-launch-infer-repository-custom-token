// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {InferFixtures, BurnableLegacy} from "./helpers/InferFixtures.sol";
import {InferToken} from "src/InferToken.sol";
import {LegacyRedeemer} from "src/LegacyRedeemer.sol";
import {SeasonVault} from "src/SeasonVault.sol";
import {FounderStream} from "src/FounderStream.sol";
import {StakedInfer} from "src/StakedInfer.sol";
import {InferDripper} from "src/InferDripper.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC4626StaticAsset} from "src/base/ERC4626StaticAsset.sol";

contract LaunchFailurePathsTest is InferFixtures {
    InferToken internal token;
    address internal alice;
    address internal bob;

    function setUp() public {
        token = new InferToken();
        alice = makeAddr("launch failure alice");
        bob = makeAddr("launch failure bob");
    }

    function test_allRequiredConstructorAddressesAreNonzero() public {
        BurnableLegacy a = new BurnableLegacy();
        BurnableLegacy b = new BurnableLegacy();
        address[5] memory addresses = [address(token), address(a), address(b), TREASURY, FOUNDER];
        for (uint256 i; i < 5; ++i) {
            address saved = addresses[i];
            addresses[i] = address(0);
            vm.expectRevert(LegacyRedeemer.ZeroAddress.selector);
            new LegacyRedeemer(
                addresses[0],
                addresses[1],
                ALLOCATION_A,
                RATE_A,
                addresses[2],
                ALLOCATION_B,
                RATE_B,
                addresses[3],
                addresses[4]
            );
            addresses[i] = saved;
        }
        address[3] memory seasonArgs = [address(token), GOVERNOR, TREASURY];
        for (uint256 i; i < 3; ++i) {
            address saved = seasonArgs[i];
            seasonArgs[i] = address(0);
            vm.expectRevert(SeasonVault.ZeroAddress.selector);
            new SeasonVault(seasonArgs[0], seasonArgs[1], seasonArgs[2]);
            seasonArgs[i] = saved;
        }
        vm.expectRevert(FounderStream.ZeroAddress.selector);
        new FounderStream(address(0), FOUNDER);
        vm.expectRevert(FounderStream.ZeroAddress.selector);
        new FounderStream(address(token), address(0));
        StakedInfer vault = new StakedInfer(token);
        vm.expectRevert(InferDripper.ZeroAddress.selector);
        new InferDripper(address(0), address(vault), 1_000e18);
        vm.expectRevert(InferDripper.ZeroAddress.selector);
        new InferDripper(address(token), address(0), 1_000e18);
        InferToken other = new InferToken();
        vm.expectRevert(InferDripper.WrongVault.selector);
        new InferDripper(address(other), address(vault), 1_000e18);
    }

    function test_legacySlotsRequireDistinctTokensAndNonzeroTerms() public {
        BurnableLegacy a = new BurnableLegacy();
        BurnableLegacy b = new BurnableLegacy();
        vm.expectRevert(LegacyRedeemer.SameToken.selector);
        new LegacyRedeemer(
            address(token), address(a), ALLOCATION_A, RATE_A, address(a), ALLOCATION_B, RATE_B, TREASURY, FOUNDER
        );
        uint256[4] memory terms = [ALLOCATION_A, RATE_A, ALLOCATION_B, RATE_B];
        for (uint256 i; i < 4; ++i) {
            uint256 saved = terms[i];
            terms[i] = 0;
            vm.expectRevert(LegacyRedeemer.ZeroAmount.selector);
            new LegacyRedeemer(
                address(token), address(a), terms[0], terms[1], address(b), terms[2], terms[3], TREASURY, FOUNDER
            );
            terms[i] = saved;
        }
    }

    function test_noAdministrativeOrSupplyMutationEntrypointAndFullSupplyRemainsTransferable() public {
        token.transfer(alice, SUPPLY);
        bytes[] memory calls = new bytes[](12);
        calls[0] = abi.encodeWithSignature("owner()");
        calls[1] = abi.encodeWithSignature("mint(address,uint256)", bob, 1);
        calls[2] = abi.encodeWithSignature("mint(uint256)", 1);
        calls[3] = abi.encodeWithSignature("burn(uint256)", 1);
        calls[4] = abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1);
        calls[5] = abi.encodeWithSignature("pause()");
        calls[6] = abi.encodeWithSignature("transferOwnership(address)", bob);
        calls[7] = abi.encodeWithSignature("setMinter(address)", bob);
        calls[8] = abi.encodeWithSignature("blacklist(address)", alice);
        calls[9] = abi.encodeWithSignature("setFee(uint256)", 100);
        calls[10] = abi.encodeWithSignature("initialize(address)", bob);
        calls[11] = abi.encodeWithSignature("upgradeTo(address)", bob);
        for (uint256 i; i < calls.length; ++i) {
            (bool byDeployer,) = address(token).call(calls[i]);
            vm.prank(bob);
            (bool byStranger,) = address(token).call(calls[i]);
            assertFalse(byDeployer);
            assertFalse(byStranger);
        }
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        vm.prank(alice);
        token.approve(bob, SUPPLY);
        vm.prank(bob);
        token.transferFrom(alice, bob, SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), SUPPLY);
        assertEq(token.allowance(alice, bob), 0);
        vm.startPrank(bob);
        token.transfer(bob, SUPPLY);
        token.transfer(alice, 0);
        token.transfer(alice, SUPPLY);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_maximumTokenTransferFailsWithoutArithmeticOrSupplyChange() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.transfer(alice, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_stakingFailuresRollbackAssetsSharesAndHold() public {
        StakedInfer vault = new StakedInfer(token);
        token.transfer(alice, 100e18);
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 0, 1e18)
        );
        vault.deposit(1e18, alice);
        token.approve(address(vault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vault.deposit(1e18, address(0));
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        uint256 shares = vault.deposit(100e18, alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626StaticAsset.ERC4626ExceededMaxWithdraw.selector, alice, 1, 0));
        vault.withdraw(1, alice, alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626StaticAsset.ERC4626ExceededMaxRedeem.selector, alice, 1, 0));
        vault.redeem(1, alice, alice);
        vm.stopPrank();
        assertEq(vault.lockedShares(alice), shares);
        vm.roll(block.number + 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, shares));
        vault.redeem(shares, bob, alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vault.redeem(shares, address(0), alice);
        assertEq(vault.totalAssets(), 100e18);
        assertEq(vault.balanceOf(alice), shares);
        vm.prank(alice);
        assertEq(vault.redeem(shares, bob, alice), 100e18);
        assertEq(token.balanceOf(bob), 100e18);
    }

    function test_founderCliffAndEndAreExactEvenWithLateFunding() public {
        FounderStream stream = new FounderStream(address(token), FOUNDER);
        uint256 start = stream.start();
        vm.warp(start + 30 days - 1);
        assertEq(stream.vested(), 0);
        vm.expectRevert(FounderStream.NothingToRelease.selector);
        stream.release();
        vm.warp(start + 30 days);
        assertEq(stream.vested(), uint256(70_000_000e18) * 30 / 365);
        vm.expectRevert(FounderStream.NothingToRelease.selector);
        stream.release();
        token.transfer(address(stream), 1);
        vm.prank(bob);
        assertEq(stream.release(), 1);
        token.transfer(address(stream), 70_000_000e18 - 1);
        uint256 due = uint256(70_000_000e18) * 30 / 365;
        assertEq(stream.release(), due - 1);
        vm.warp(start + 365 days - 1);
        stream.release();
        assertLt(token.balanceOf(FOUNDER), 70_000_000e18);
        vm.warp(start + 365 days);
        stream.release();
        assertEq(token.balanceOf(FOUNDER), 70_000_000e18);
        vm.expectRevert(FounderStream.NothingToRelease.selector);
        stream.release();
        token.transfer(address(stream), 1);
        assertEq(stream.release(), 1);
        assertEq(token.balanceOf(bob), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_founderPaymentsNeverDependOnReleaseFrequency(uint256 firstTime, uint256 secondTime) public {
        FounderStream stream = new FounderStream(address(token), FOUNDER);
        token.transfer(address(stream), 70_000_000e18);
        firstTime = bound(firstTime, 30 days, 365 days);
        secondTime = bound(secondTime, firstTime, 365 days);
        uint256 start = stream.start();
        vm.warp(start + firstTime);
        stream.release();
        vm.warp(start + secondTime);
        if (stream.releasable() != 0) stream.release();
        assertEq(token.balanceOf(FOUNDER), 70_000_000e18 * secondTime / 365 days);
        vm.warp(start + 365 days);
        if (stream.releasable() != 0) stream.release();
        assertEq(token.balanceOf(FOUNDER), 70_000_000e18);
        assertEq(token.balanceOf(address(stream)), 0);
    }
}
