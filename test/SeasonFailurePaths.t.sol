// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {InferFixtures} from "./helpers/InferFixtures.sol";
import {InferToken} from "src/InferToken.sol";
import {SeasonVault} from "src/SeasonVault.sol";

contract SeasonFailurePathsTest is InferFixtures {
    string internal constant RULES = "bafySeasonFailureRules";
    uint256 internal constant POT = 100e18;
    InferToken internal token;
    SeasonVault internal vault;
    address internal alice;
    address internal bob;

    function setUp() public {
        token = new InferToken();
        vault = new SeasonVault(address(token), GOVERNOR, TREASURY);
        token.transfer(address(vault), 310_000_000e18);
        alice = makeAddr("season failure alice");
        bob = makeAddr("season failure bob");
        vm.prank(GOVERNOR);
        vault.openSeason(uint64(block.timestamp + 48 hours), POT, keccak256(bytes(RULES)));
    }

    function _root(uint256 s) internal view returns (bytes32) {
        return _pair(_leaf(s, alice, 60e18), _leaf(s, bob, 40e18));
    }

    function _proof(uint256 s, bool forAlice) internal view returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = forAlice ? _leaf(s, bob, 40e18) : _leaf(s, alice, 60e18);
    }

    function _setRoot() internal {
        vm.warp(vault.endOf(0));
        vm.prank(GOVERNOR);
        vault.proposeRoot(0, _root(0), POT, RULES);
        vm.warp(block.timestamp + 48 hours);
        vault.applyProposal(0);
    }

    function test_everyGovernorEntryRejectsAnUnprivilegedCallerWithoutChangingState() public {
        bytes32 root = _root(0);
        vm.expectRevert(SeasonVault.NotGovernor.selector);
        vault.openSeason(uint64(block.timestamp + 48 hours), 1, keccak256(bytes(RULES)));
        vm.expectRevert(SeasonVault.NotGovernor.selector);
        vault.proposeRoot(0, root, POT, RULES);
        vm.expectRevert(SeasonVault.NotGovernor.selector);
        vault.withdrawProposal(0);
        vm.expectRevert(SeasonVault.NotGovernor.selector);
        vault.announceEnd();
        vm.expectRevert(SeasonVault.NotGovernor.selector);
        vault.withdrawEnd();
        assertEq(vault.opened(), 1);
        assertEq(vault.reserved(), POT);
        assertEq(vault.endEta(), 0);
        assertEq(vault.season(0).pendingEta, 0);
        assertEq(token.balanceOf(TREASURY), 0);
    }

    function test_missingSeasonAndRootFailuresAreSpecific() public {
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.NoSuchSeason.selector, 5));
        vault.season(5);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.NoSuchSeason.selector, 1));
        vault.endOf(1);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.NoSuchSeason.selector, 1));
        vault.registrationDeadline(1);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.NoSuchSeason.selector, 1));
        vault.release(1, alice);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.NoSuchSeason.selector, 1));
        vault.expire(1);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.NoRoot.selector, 0));
        vault.claim(0, alice, 60e18, new bytes32[](0));
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.NoProposal.selector, 0));
        vault.applyProposal(0);
        vm.prank(GOVERNOR);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.NoProposal.selector, 0));
        vault.withdrawProposal(0);
        vm.expectRevert(SeasonVault.NotEnded.selector);
        vault.sweep();
        vm.expectRevert(SeasonVault.NoEndAnnounced.selector);
        vault.endProgram();
        assertEq(vault.reserved(), POT);
    }

    function test_rootProposalBoundariesReplacementAndCancellation() public {
        bytes32 first = _root(0);
        bytes32 replacement = _leaf(0, alice, POT);
        vm.warp(vault.endOf(0) - 1);
        vm.prank(GOVERNOR);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.SeasonNotOver.selector, 0));
        vault.proposeRoot(0, first, POT, RULES);
        vm.warp(vault.endOf(0));
        vm.prank(GOVERNOR);
        vault.proposeRoot(0, first, POT, RULES);
        uint256 firstEta = vault.season(0).pendingEta;
        vm.warp(firstEta - 1);
        vm.prank(GOVERNOR);
        vault.proposeRoot(0, replacement, POT, RULES);
        uint256 newEta = vault.season(0).pendingEta;
        vm.warp(firstEta);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.TooEarly.selector, newEta));
        vault.applyProposal(0);
        vm.prank(GOVERNOR);
        vault.withdrawProposal(0);
        SeasonVault.Season memory season = vault.season(0);
        assertEq(season.pendingRoot, 0);
        assertEq(season.pendingTotal, 0);
        assertEq(season.pendingEta, 0);
        vm.warp(newEta);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.NoProposal.selector, 0));
        vault.applyProposal(0);
        vm.prank(GOVERNOR);
        vault.proposeRoot(0, first, POT, RULES);
        uint256 eta = vault.season(0).pendingEta;
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.TooEarly.selector, eta));
        vault.applyProposal(0);
        vm.warp(eta);
        vm.prank(bob);
        vault.applyProposal(0);
        assertEq(vault.season(0).root, first);
        vm.prank(GOVERNOR);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.RootAlreadySet.selector, 0));
        vault.proposeRoot(0, replacement, POT, RULES);
    }

    function test_expiringRootlessSeasonCancelsPendingProposalAtExactDeadline() public {
        uint256 deadline = vault.endOf(0) + 26 weeks;
        // A proposal must have time to mature before the root deadline, even if never applied.
        vm.warp(deadline - 48 hours - 1);
        vm.prank(GOVERNOR);
        vault.proposeRoot(0, _root(0), POT, RULES);
        assertEq(vault.season(0).pendingEta, deadline - 1);
        vm.warp(deadline - 1);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.NotYet.selector, deadline));
        vault.expire(0);
        vm.warp(deadline);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.PastDeadline.selector, 0));
        vault.applyProposal(0);
        vault.expire(0);
        assertEq(vault.reserved(), 0);
        assertEq(vault.season(0).pendingEta, 0);
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.NoProposal.selector, 0));
        vault.applyProposal(0);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.AlreadyExpired.selector, 0));
        vault.expire(0);
        bytes32 root = _root(0);
        vm.prank(GOVERNOR);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.AlreadyExpired.selector, 0));
        vault.proposeRoot(0, root, POT, RULES);
    }

    function test_registrationDeadlineIsExclusiveButRegisteredClaimsRemainPayable() public {
        _setRoot();
        vault.claim(0, alice, 60e18, _proof(0, true));
        uint256 deadline = vault.registrationDeadline(0);
        vm.warp(deadline - 1);
        assertEq(vault.claim(0, bob, 40e18, _proof(0, false)), 40e18);
        vm.warp(deadline);
        assertEq(vault.claim(0, alice, 60e18, _proof(0, true)), 60e18);
        vault.expire(0);
        assertEq(vault.claim(0, alice, 60e18, _proof(0, true)), 0);
        assertEq(vault.release(0, alice), 0);
        assertEq(vault.season(0).registered, POT);
        assertEq(vault.reserved(), 0);
        assertEq(token.balanceOf(alice), 60e18);
        assertEq(token.balanceOf(bob), 40e18);
    }

    function test_validUnregisteredLeafIsRefusedAtDeadlineWithoutLosingRegisteredDebt() public {
        _setRoot();
        vault.claim(0, alice, 60e18, _proof(0, true));
        vm.warp(vault.registrationDeadline(0));
        bytes32[] memory proof = _proof(0, false);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.PastDeadline.selector, 0));
        vault.claim(0, bob, 40e18, proof);
        assertEq(vault.season(0).registered, 60e18);
        assertEq(vault.reserved(), POT);
        vault.expire(0);
        assertEq(vault.reserved(), 60e18);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.PastDeadline.selector, 0));
        vault.claim(0, bob, 40e18, proof);
        assertEq(vault.claim(0, alice, 60e18, _proof(0, true)), 60e18);
        assertEq(vault.reserved(), 0);
        assertEq(token.balanceOf(alice), 60e18);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_proofBindsSeasonRecipientAndAmountAndFailureDoesNotRegister() public {
        _setRoot();
        bytes32[] memory proof = _proof(0, true);
        vm.expectRevert(SeasonVault.BadProof.selector);
        vault.claim(0, alice, 60e18 + 1, proof);
        vm.expectRevert(SeasonVault.BadProof.selector);
        vault.claim(0, bob, 60e18, proof);
        vm.expectRevert(SeasonVault.BadProof.selector);
        vault.claim(0, alice, 60e18, _proof(1, true));
        (uint256 entitlement, uint256 paid) = vault.entitlements(0, alice);
        assertEq(entitlement, 0);
        assertEq(paid, 0);
        assertEq(vault.season(0).registered, 0);
        assertEq(vault.reserved(), POT);
        vault.claim(0, alice, 60e18, proof);
        assertEq(vault.season(0).registered, 60e18);
        vault.claim(0, alice, 60e18, proof);
        assertEq(vault.season(0).registered, 60e18);
    }

    function test_badSecondBatchEntryRollsBackFirstRegistrationAndPayout() public {
        _setRoot();
        vm.warp(block.timestamp + 13 weeks);
        SeasonVault.Claim[] memory batch = new SeasonVault.Claim[](2);
        batch[0] = SeasonVault.Claim(0, alice, 60e18, _proof(0, true));
        batch[1] = SeasonVault.Claim(0, bob, 40e18 + 1, _proof(0, false));
        vm.expectRevert(SeasonVault.BadProof.selector);
        vault.distribute(batch);
        assertEq(token.balanceOf(alice), 0);
        assertEq(vault.season(0).registered, 0);
        assertEq(vault.season(0).paid, 0);
        assertEq(vault.reserved(), POT);
        batch[1].amount = 40e18;
        vault.distribute(batch);
        assertEq(token.balanceOf(alice), 60e18);
        assertEq(token.balanceOf(bob), 40e18);
        vault.distribute(batch);
        assertEq(vault.season(0).paid, POT);
        assertEq(vault.reserved(), 0);
        vault.distribute(new SeasonVault.Claim[](0));
    }

    function test_endCannotAccelerateThenReopenOrSweepReservedClaims() public {
        _setRoot();
        vault.claim(0, alice, 60e18, _proof(0, true));
        vm.prank(GOVERNOR);
        vault.announceEnd();
        uint256 eta = vault.endEta();
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.TooEarly.selector, eta));
        vault.endProgram();
        vm.warp(eta);
        vm.prank(bob);
        vault.endProgram();
        assertTrue(vault.ended());
        assertEq(token.balanceOf(address(vault)), POT);
        vault.sweep();
        assertEq(token.balanceOf(address(vault)), POT);
        vm.prank(GOVERNOR);
        vm.expectRevert(SeasonVault.NoEndAnnounced.selector);
        vault.withdrawEnd();
        vm.prank(GOVERNOR);
        vm.expectRevert(SeasonVault.ProgramIsEnded.selector);
        vault.announceEnd();
        vm.prank(GOVERNOR);
        vm.expectRevert(SeasonVault.ProgramIsEnded.selector);
        vault.openSeason(uint64(block.timestamp + 48 hours), 1, keccak256(bytes(RULES)));
        vm.expectRevert(SeasonVault.ProgramIsEnded.selector);
        vault.endProgram();
        vm.warp(vault.registrationDeadline(0));
        vault.expire(0);
        vault.sweep();
        assertEq(token.balanceOf(address(vault)), 60e18);
        vault.release(0, alice);
        assertEq(token.balanceOf(alice), 60e18);
        assertEq(token.balanceOf(address(vault)), 0);
    }
}
