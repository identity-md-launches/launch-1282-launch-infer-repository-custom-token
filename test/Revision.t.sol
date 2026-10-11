// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {InferToken} from "src/InferToken.sol";
import {StakedInfer} from "src/StakedInfer.sol";
import {InferDripper} from "src/InferDripper.sol";
import {SeasonVault} from "src/SeasonVault.sol";
import {SeasonAttestation} from "src/SeasonAttestation.sol";
import {SeasonVaultHarness} from "./Buckets.t.sol";

contract DripperDustRevisionTest is Test {
    InferToken token;
    StakedInfer vault;
    InferDripper dripper;
    address keeper = address(0xBEEF);
    uint256 constant MIN_SHARES = 1e9;

    function setUp() public {
        token = new InferToken();
        vault = new StakedInfer(token);
        dripper = new InferDripper(address(token), address(vault), 1_000e18);
        token.approve(address(vault), type(uint256).max);
        token.transfer(address(dripper), 1_000_000e18);
        vm.warp(block.timestamp + 1 hours);
    }

    function _refused() private {
        uint256 balance = token.balanceOf(address(dripper));
        uint256 assets = vault.totalAssets();
        uint256 last = dripper.lastDripAt();
        assertFalse(dripper.canDrip());
        vm.prank(keeper);
        vm.expectRevert(InferDripper.VaultEmpty.selector);
        dripper.drip();
        assertEq(token.balanceOf(address(dripper)), balance);
        assertEq(token.balanceOf(keeper), 0);
        assertEq(vault.totalAssets(), assets);
        assertEq(dripper.lastDripAt(), last);
    }

    function test_oneWeiCannotEnableDripsEvenAfterADonation() public {
        assertEq(vault.deposit(1, address(this)), 1e6);
        _refused();
        token.transfer(address(vault), 10_000e18);
        _refused(); // asset backing alone does not dilute the virtual shares
    }

    function test_thresholdBoundaryAndWithdrawalsRecheckTheGuard() public {
        vault.mint(MIN_SHARES - 1, address(this));
        _refused();
        vault.mint(1, address(this));
        assertTrue(dripper.canDrip());
        vm.roll(block.number + 1);
        uint256 before = vault.maxWithdraw(address(this));
        vm.prank(keeper);
        (uint256 paid,) = dripper.drip();
        uint256 captured = paid - (vault.maxWithdraw(address(this)) - before);
        assertLe(captured, (paid + 1000) / 1001);

        vault.redeem(1, address(this), address(this));
        vm.warp(block.timestamp + 1 hours);
        assertFalse(dripper.canDrip());
        vm.expectRevert(InferDripper.VaultEmpty.selector);
        dripper.drip();
    }

    function test_dustVaultResumesAfterRealStakeArrives() public {
        vault.deposit(1, address(this));
        _refused();
        vault.deposit(10_000e18, address(this));
        assertTrue(dripper.canDrip());
        vm.prank(keeper);
        (uint256 paid,) = dripper.drip();
        vm.roll(block.number + 1);
        vault.redeem(vault.balanceOf(address(this)), address(this), address(this));
        assertLt(vault.totalAssets(), paid / 1000);
        vm.warp(block.timestamp + 1 hours);
        assertFalse(dripper.canDrip());
    }

    function testFuzz_virtualCaptureIsBounded(uint256 shares, uint256 buffer) public {
        shares = bound(shares, MIN_SHARES, 1e28);
        buffer = bound(buffer, 1_000e18, 1_000_000e18);
        // Use a separate buffer so both the hourly floor and ordinary decay are exercised.
        InferDripper funded = new InferDripper(address(token), address(vault), 1_000e18);
        token.transfer(address(funded), buffer);
        vault.mint(shares, address(this));
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 1);
        uint256 before = vault.maxWithdraw(address(this));
        (uint256 paid,) = funded.drip();
        uint256 captured = paid - (vault.maxWithdraw(address(this)) - before);
        assertLe(captured, (paid + 1000) / 1001); // < 0.1%, with at most one wei rounding
    }
}

contract SeasonRevisionTest is Test {
    InferToken token;
    SeasonVault vault;
    address constant GOVERNOR = address(0x60F);
    address constant TREASURY = address(0x7EA);
    address constant ALICE = address(0xA11CE);
    uint256 constant KEY = 0xA77E57;
    uint256 constant POT = 60_000_000e18;
    uint256 constant AWARD = 1_000e18;
    string constant CID = "bafkreiabc";
    bytes32 root;

    function setUp() public {
        token = new InferToken();
        vault = new SeasonVaultHarness(address(token), GOVERNOR, TREASURY, vm.addr(KEY));
        token.transfer(address(vault), vault.genesisAllocation());
        root = keccak256(bytes.concat(keccak256(abi.encode(uint256(0), ALICE, AWARD))));
        vm.roll(1000);
    }

    function _open() private returns (uint256 deadline) {
        vm.prank(GOVERNOR);
        vault.openSeason(uint64(block.timestamp + 48 hours), POT, keccak256(bytes(CID)));
        return vault.endOf(0) + vault.ROOT_DEADLINE();
    }

    function _propose() private {
        vm.prank(GOVERNOR);
        vault.proposeRoot(0, root, AWARD, CID);
    }

    function _attestation() private view returns (SeasonAttestation.OracleAttestation memory a, bytes memory sig) {
        a.requestId = keccak256("revision");
        a.chainId = 1;
        a.answer = abi.encode(true);
        a.fromBlock = 100;
        a.toBlock = 200;
        a.panelSize = 25;
        a.quorum = 15;
        a.agreed = 15;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 hours);
        a.questionHash = keccak256(vault.seasonQuestion(0, root, AWARD, CID, CID, a.fromBlock, a.toBlock));
        bytes32 h = keccak256(
            bytes.concat(
                abi.encode(
                    vault.ATTESTATION_TYPEHASH(),
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock
                ),
                abi.encode(
                    a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(KEY, keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), h)));
        sig = abi.encodePacked(r, s, v);
    }

    function test_governorProposalNeedsTimeToMatureBeforeExpiry() public {
        uint256 deadline = _open();
        vm.warp(deadline - 1 hours);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.PastDeadline.selector, 0));
        _propose();
        vm.warp(deadline - 48 hours);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.PastDeadline.selector, 0));
        _propose();
        assertEq(vault.season(0).pendingEta, 0);
        assertEq(vault.reserved(), POT);
    }

    function test_lastTimelyGovernorProposalCanApply() public {
        uint256 deadline = _open();
        vm.warp(deadline - 48 hours - 1);
        _propose();
        vm.warp(deadline - 1);
        vault.applyProposal(0);
        assertEq(vault.season(0).root, root);
        assertEq(vault.reserved(), AWARD);
    }

    function test_unappliedProposalCannotRaceExpiryAtDeadline() public {
        uint256 deadline = _open();
        vm.warp(vault.endOf(0));
        _propose();
        vm.warp(deadline);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.PastDeadline.selector, 0));
        vault.applyProposal(0);
        vault.expire(0);
        assertEq(vault.season(0).pendingEta, 0);
        assertEq(vault.reserved(), 0);
        assertEq(vault.available(), vault.genesisAllocation());
    }

    function test_attestedRootCannotRaceExpiryAtDeadline() public {
        uint256 deadline = _open();
        vm.warp(deadline);
        (SeasonAttestation.OracleAttestation memory a, bytes memory sig) = _attestation();
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.PastDeadline.selector, 0));
        vault.submitAttestedRoot(0, root, AWARD, CID, CID, a, sig);
        assertFalse(vault.usedRequests(a.requestId));
        vault.expire(0);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.AlreadyExpired.selector, 0));
        vault.submitAttestedRoot(0, root, AWARD, CID, CID, a, sig);
    }

    function test_lastTimelyAttestedRootIsImmediateAndFinal() public {
        uint256 deadline = _open();
        vm.warp(deadline - 1);
        (SeasonAttestation.OracleAttestation memory a, bytes memory sig) = _attestation();
        vault.submitAttestedRoot(0, root, AWARD, CID, CID, a, sig);
        assertEq(vault.season(0).rootSetAt, block.timestamp);
        vm.prank(GOVERNOR);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.NoProposal.selector, 0));
        vault.withdrawProposal(0);
        vm.prank(GOVERNOR);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.RootAlreadySet.selector, 0));
        vault.proposeRoot(0, bytes32(uint256(1)), AWARD, CID);
        vm.warp(block.timestamp + vault.SEASON());
        assertEq(vault.claim(0, ALICE, AWARD, new bytes32[](0)), AWARD);
    }

    function _register() private returns (uint256 deadline) {
        _open();
        vm.warp(vault.endOf(0));
        _propose();
        vm.warp(block.timestamp + 48 hours);
        vault.applyProposal(0);
        vault.claim(0, ALICE, AWARD, new bytes32[](0));
        return vault.registrationDeadline(0);
    }

    function test_registeredClaimStillPaysAtRegistrationDeadline() public {
        vm.warp(_register());
        assertEq(vault.releasable(0, ALICE), AWARD);
        assertEq(vault.claim(0, ALICE, AWARD, new bytes32[](0)), AWARD);
        assertEq(vault.claim(0, ALICE, AWARD, new bytes32[](0)), 0);
        assertEq(token.balanceOf(ALICE), AWARD);
        assertEq(vault.reserved(), 0);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.PastDeadline.selector, 0));
        vault.claim(0, address(0xB0B), AWARD, new bytes32[](0));
    }

    function test_registeredClaimStillPaysAfterExpiryWithoutReregistering() public {
        vm.warp(_register());
        vault.expire(0);
        // The stored entitlement, not the repeat call's amount or proof, determines the payment.
        assertEq(vault.claim(0, ALICE, type(uint256).max, new bytes32[](0)), AWARD);
        assertEq(vault.claim(0, ALICE, 0, new bytes32[](0)), 0);
        assertEq(vault.season(0).registered, AWARD);
        assertEq(token.balanceOf(ALICE), AWARD);
        assertEq(vault.reserved(), 0);
    }

    function test_governorCanEndWithoutOpeningAnySeason() public {
        vm.prank(GOVERNOR);
        vault.announceEnd();
        vm.warp(block.timestamp + 48 hours);
        vault.endProgram();
        assertEq(token.balanceOf(TREASURY), 310_000_000e18);
    }

    function test_timeAloneCannotReleaseThePointsAllocation() public {
        vm.warp(block.timestamp + 100 * 365 days);
        vm.expectRevert(SeasonVault.NotGovernor.selector);
        vault.openSeason(uint64(block.timestamp + 48 hours), POT, keccak256(bytes(CID)));
        vm.expectRevert(SeasonVault.NoEndAnnounced.selector);
        vault.endProgram();
        vm.expectRevert(SeasonVault.NotEnded.selector);
        vault.sweep();
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.NoSuchSeason.selector, 0));
        vault.expire(0);
        assertEq(vault.available(), 310_000_000e18);
        assertEq(token.balanceOf(address(vault)), 310_000_000e18);
    }
}
