// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {FounderStream} from "src/FounderStream.sol";
import {StakedInfer} from "src/StakedInfer.sol";
import {SeasonVault} from "src/SeasonVault.sol";
import {SeasonAttestation} from "src/SeasonAttestation.sol";
import {InferDripper} from "src/InferDripper.sol";
import {LegacyRedeemer} from "src/LegacyRedeemer.sol";
import {GenesisSplitter, ILaunchRegistry} from "genesis-splitter/GenesisSplitter.sol";

contract Infer is ERC20 {
    constructor(address to) ERC20("INFER", "INFER") {
        _mint(to, 1_000_000_000e18);
    }
}

contract FounderStreamTest is Test {
    Infer infer;
    FounderStream stream;
    address constant FOUNDER = address(0xF0);

    function setUp() public {
        infer = new Infer(address(this));
        stream = new FounderStream(address(infer), FOUNDER);
        infer.transfer(address(stream), 70_000_000e18);
    }

    function test_nothingBeforeTheCliffThenTheStraightLine() public {
        vm.warp(block.timestamp + 30 days - 1);
        assertEq(stream.releasable(), 0);
        vm.expectRevert(FounderStream.NothingToRelease.selector);
        stream.release();
        vm.warp(block.timestamp + 1); // day 30: a month's worth at once
        stream.release();
        assertEq(infer.balanceOf(FOUNDER), uint256(70_000_000e18) * 30 days / 365 days);
        vm.warp(stream.start() + 182.5 days);
        stream.release();
        assertEq(infer.balanceOf(FOUNDER), 35_000_000e18);
    }

    function test_allOfItAtAYearAndNothingStranded() public {
        vm.warp(stream.start() + 365 days);
        infer.transfer(address(stream), 5e18); // sent by mistake
        vm.prank(address(0xBEEF)); // anyone
        stream.release();
        assertEq(infer.balanceOf(FOUNDER), 70_000_005e18);
        assertEq(infer.balanceOf(address(stream)), 0);
    }

    function test_neverPaysMoreThanItHolds() public {
        FounderStream unfunded = new FounderStream(address(infer), FOUNDER);
        vm.warp(block.timestamp + 100 days);
        assertEq(unfunded.releasable(), 0);
        infer.transfer(address(unfunded), 1e18);
        assertEq(unfunded.releasable(), 1e18);
    }
}

contract StakingTest is Test {
    Infer infer;
    StakedInfer sinfer;
    InferDripper dripper;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address keeper = address(0xCEE);

    function setUp() public {
        infer = new Infer(address(this));
        sinfer = new StakedInfer(IERC20(address(infer)));
        dripper = new InferDripper(address(infer), address(sinfer), 1e18);
        infer.transfer(alice, 1_000_000e18);
        infer.transfer(bob, 1_000_000e18);
        vm.prank(alice);
        infer.approve(address(sinfer), type(uint256).max);
        vm.prank(bob);
        infer.approve(address(sinfer), type(uint256).max);
    }

    function _buyback(uint256 amount) private {
        infer.transfer(address(dripper), amount); // what the Treasury does with revenue-bought INFER
    }

    function test_neverDripsIntoAnEmptyVault() public {
        _buyback(100_000e18);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(InferDripper.VaultEmpty.selector);
        dripper.drip();
    }

    function test_oneCallReleasesAtMostAnHoursSliceOfTheBuffer() public {
        vm.prank(alice);
        sinfer.deposit(1_000e18, alice);
        _buyback(168_000e18);
        vm.warp(block.timestamp + 30 days); // nobody dripped for a month
        assertEq(dripper.releasable(), 1_000e18, "1/168 of the buffer, not a month's lump");
        vm.prank(keeper);
        (uint256 toVault, uint256 toKeeper) = dripper.drip();
        assertEq(toVault + toKeeper, 1_000e18);
        assertEq(toKeeper, 10e18, "1% to whoever called");
        vm.expectRevert(abi.encodeWithSelector(InferDripper.BelowMinDrip.selector, 0, 1e18));
        dripper.drip(); // same second: nothing more
    }

    function test_stakersEarnByTimeHeldAndTheBufferDrainsOverAboutAWeek() public {
        vm.prank(alice);
        uint256 shares = sinfer.deposit(1_000e18, alice);
        _buyback(10_000e18);
        for (uint256 i; i < 168; ++i) {
            // a keeper dripping hourly for a week
            vm.warp(block.timestamp + 1 hours);
            dripper.drip();
        }
        uint256 left = infer.balanceOf(address(dripper));
        assertApproxEqRel(left, 10_000e18 * 3679 / 10_000, 0.01e18, "~e^-1 of the buffer remains after one period");
        vm.roll(block.number + 1);
        vm.prank(alice);
        uint256 out = sinfer.redeem(shares, alice, alice);
        assertApproxEqRel(out, 1_000e18 + (10_000e18 - left) * 99 / 100, 1e12, "everything dripped, less keeper fees");
    }

    function test_aDepositRightBeforeADripGainsOnlyThatSlice() public {
        vm.prank(alice);
        sinfer.deposit(100_000e18, alice);
        _buyback(168_000e18);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(bob);
        uint256 bobShares = sinfer.deposit(100_000e18, bob); // sandwich attempt
        dripper.drip();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, bob, bobShares, 0));
        sinfer.redeem(bobShares, bob, bob); // the hold: maxRedeem is 0 in the deposit block
        vm.roll(block.number + 1);
        vm.prank(bob);
        uint256 out = sinfer.redeem(bobShares, bob, bob);
        assertLe(out, 100_000e18 + 495e18 + 1e18, "half of one hourly slice (990 to the vault), nothing more");
    }

    function test_theHoldTravelsWithSharesAndCannotBeUsedToGrief() public {
        vm.prank(alice);
        uint256 shares = sinfer.deposit(1_000e18, alice);
        vm.prank(alice);
        sinfer.transfer(bob, shares); // same block: bob inherits alice's hold
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, bob, shares, 0));
        sinfer.redeem(shares, bob, bob);

        vm.roll(block.number + 1);
        vm.prank(bob);
        sinfer.deposit(1, address(0xD00D)); // a stranger "stamps" alice? no: dust MINT stamps only its receiver
        vm.prank(bob);
        sinfer.transfer(alice, 1); // a dust transfer carries bob's (older) stamp, never a new one
        assertEq(sinfer.maxRedeem(alice), 1, "alice can still exit this block");
    }

    function test_inflationAttackDoesNotPay() public {
        vm.prank(alice);
        sinfer.deposit(1, alice);
        vm.prank(alice);
        infer.transfer(address(sinfer), 100_000e18);
        vm.prank(bob);
        uint256 bobShares = sinfer.deposit(1_000e18, bob);
        vm.roll(block.number + 1);
        vm.prank(bob);
        assertGt(sinfer.redeem(bobShares, bob, bob), 1_000e18 * 999 / 1000);
    }

    function test_neitherDeclaresAGenesisShare() public {
        (bool a,) = address(sinfer).staticcall(abi.encodeWithSignature("genesisAllocation()"));
        (bool b,) = address(dripper).staticcall(abi.encodeWithSignature("genesisAllocation()"));
        assertFalse(a || b, "no staking emission");
    }
}

contract SeasonVaultHarness is SeasonVault {
    address private immutable signer;

    constructor(address t, address g, address tr, address s) SeasonVault(t, g, tr) {
        signer = s;
    }

    function _attester() internal view override returns (address) {
        return signer;
    }
}

contract SeasonVaultTest is Test {
    Infer infer;
    SeasonVault seasons;
    uint256 constant KEY = 0xA77E57;
    string constant CID = "bafkreigh2akiscaildcqabsyg3dfr6chu3fgpregiymsck7e7aqa4s52zy";
    /// @dev A season's rules document, by CID; the vault is given only keccak256(bytes(RULES)) at opening.
    string constant RULES = "bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku";
    uint256 nonce;
    address constant GOVERNOR = address(0x60F);
    address constant TREASURY = address(0x7EA);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        infer = new Infer(address(this));
        seasons = new SeasonVaultHarness(address(infer), GOVERNOR, TREASURY, vm.addr(KEY));
        infer.transfer(address(seasons), 310_000_000e18);
    }

    /// @dev A panel's signed YES to season `s`'s question about (root, total, CID), as the plane would sign it.
    function _att(uint256 s, bytes32 root, uint256 total)
        internal
        returns (SeasonAttestation.OracleAttestation memory a, bytes memory sig)
    {
        a.requestId = keccak256(abi.encode("request", ++nonce));
        a.chainId = 1;
        a.answerType = 0;
        a.answer = abi.encode(true);
        a.figure = 1;
        (a.fromBlock, a.toBlock) = (100, 200);
        a.panelJobId = keccak256("panel");
        (a.panelSize, a.quorum, a.agreed) = (60, 20, 20);
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 hours);
        a.questionHash = keccak256(seasons.seasonQuestion(s, root, total, CID, RULES, a.fromBlock, a.toBlock));
        sig = _sign(a);
    }

    function _sign(SeasonAttestation.OracleAttestation memory a) internal view returns (bytes memory) {
        bytes32 h = keccak256(
            bytes.concat(
                abi.encode(
                    seasons.ATTESTATION_TYPEHASH(),
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
        (uint8 v, bytes32 r, bytes32 ss) =
            vm.sign(KEY, keccak256(abi.encodePacked("\x19\x01", seasons.DOMAIN_SEPARATOR(), h)));
        return abi.encodePacked(r, ss, v);
    }

    function _submit(uint256 s, bytes32 root, uint256 total) internal {
        (SeasonAttestation.OracleAttestation memory a, bytes memory sig) = _att(s, root, total);
        seasons.submitAttestedRoot(s, root, total, CID, RULES, a, sig);
    }

    function _leaf(uint256 s, address a, uint256 amt) private pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(s, a, amt))));
    }

    function _pair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// @dev A two-leaf tree: alice `a`, bob `b`.
    function _tree(uint256 s, uint256 a, uint256 b)
        private
        view
        returns (bytes32 root, bytes32[] memory pa, bytes32[] memory pb)
    {
        bytes32 la = _leaf(s, alice, a);
        bytes32 lb = _leaf(s, bob, b);
        root = _pair(la, lb);
        pa = new bytes32[](1);
        pa[0] = lb;
        pb = new bytes32[](1);
        pb[0] = la;
    }

    uint256 constant POT = 100_000_000e18;

    /// @dev The governor opens the next season `NOTICE` from now with `pot`; returns its index.
    function _open(uint256 pot) internal returns (uint256 s) {
        vm.prank(GOVERNOR);
        s = seasons.openSeason(uint64(block.timestamp + 48 hours), pot, keccak256(bytes(RULES)));
    }

    /// @dev Open season `s`'s successor right after it ends (no pause).
    function _openAfter(uint256 s, uint256 pot) internal returns (uint256) {
        vm.warp(seasons.endOf(s) - 48 hours);
        return _open(pot);
    }

    // ---------------------------------------------------------------- opening

    function test_nothingIsScheduledUntilTheGovernorOpensASeason() public {
        assertEq(seasons.opened(), 0);
        assertEq(seasons.available(), 310_000_000e18);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.NoSuchSeason.selector, 0));
        seasons.endOf(0);
        vm.expectRevert(SeasonVault.NotGovernor.selector);
        seasons.openSeason(uint64(block.timestamp + 48 hours), POT, keccak256(bytes(RULES)));
    }

    function test_openingNeedsNoticeAFixed13WeeksAndNoOverlap() public {
        vm.startPrank(GOVERNOR);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.TooSoon.selector, block.timestamp + 48 hours));
        seasons.openSeason(uint64(block.timestamp + 48 hours - 1), POT, keccak256(bytes(RULES)));
        vm.expectRevert(SeasonVault.ZeroPot.selector);
        seasons.openSeason(uint64(block.timestamp + 48 hours), 0, keccak256(bytes(RULES)));
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.OverAvailable.selector, 310_000_001e18, 310_000_000e18));
        seasons.openSeason(uint64(block.timestamp + 48 hours), 310_000_001e18, keccak256(bytes(RULES)));

        uint64 t0 = uint64(block.timestamp + 48 hours);
        assertEq(seasons.openSeason(t0, POT, keccak256(bytes(RULES))), 0);
        assertEq(seasons.endOf(0), t0 + 13 weeks);
        assertEq(seasons.available(), 310_000_000e18 - POT, "the pot is reserved at opening");
        // The next season may not start before this one ends, however much notice is given.
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.Overlaps.selector, t0 + 13 weeks));
        seasons.openSeason(t0 + 13 weeks - 1, 1e18, keccak256(bytes(RULES)));
        assertEq(seasons.openSeason(t0 + 13 weeks, 1e18, keccak256(bytes(RULES))), 1, "back to back is allowed");
        vm.stopPrank();
    }

    function test_atMostFiveSeasons() public {
        uint256 s = _open(1e18);
        for (uint256 i; i < 4; ++i) {
            s = _openAfter(s, 1e18);
        }
        assertEq(s, 4);
        vm.warp(seasons.endOf(4));
        vm.prank(GOVERNOR);
        vm.expectRevert(SeasonVault.AllSeasonsOpened.selector);
        seasons.openSeason(uint64(block.timestamp + 48 hours), 1e18, keccak256(bytes(RULES)));
    }

    function test_pausesAndSkips_theEarlierSeasonVestsRegardless() public {
        (bytes32 root, bytes32[] memory pa,) = _tree(0, 60_000_000e18, 64_000_000e18);
        _open(POT);
        vm.warp(seasons.endOf(0));
        _submit(0, root, POT);
        seasons.claim(0, alice, 60_000_000e18, pa);
        // No season 1 is opened: a pause of any length. Season 0 still vests over its 13 weeks.
        vm.warp(seasons.endOf(0) + 13 weeks);
        seasons.release(0, alice);
        assertEq(infer.balanceOf(alice), 60_000_000e18);
        // A year later the governor opens the next one.
        vm.warp(block.timestamp + 365 days);
        assertEq(_open(80_600_000e18), 1);
    }

    // ---------------------------------------------------------------- roots and vesting

    function test_vestingRunsFromTheRootSoALateRootCostsNothing() public {
        (bytes32 root, bytes32[] memory pa,) = _tree(0, 60_000_000e18, 64_000_000e18);
        _open(POT);
        (SeasonAttestation.OracleAttestation memory early, bytes memory earlySig) = _att(0, root, POT);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.SeasonNotOver.selector, 0));
        seasons.submitAttestedRoot(0, root, POT, CID, RULES, early, earlySig);

        vm.warp(seasons.endOf(0) + 3 weeks); // the root is three weeks late
        _submit(0, root, POT);
        assertEq(seasons.claim(0, alice, 60_000_000e18, pa), 0, "registered; nothing vested yet");
        vm.warp(block.timestamp + 13 weeks / 2);
        seasons.release(0, alice);
        assertEq(infer.balanceOf(alice), 30_000_000e18);
        vm.warp(block.timestamp + 13 weeks);
        seasons.release(0, alice);
        assertEq(infer.balanceOf(alice), 60_000_000e18);
    }

    function test_vestingOfOneSeasonOverlapsTheNext() public {
        (bytes32 r0, bytes32[] memory p0,) = _tree(0, 10e18, 10e18);
        (bytes32 r1, bytes32[] memory p1,) = _tree(1, 6e18, 6e18);
        _open(20e18);
        _openAfter(0, 12e18);
        vm.warp(seasons.endOf(0));
        _submit(0, r0, 20e18); // season 1 is running while season 0 vests
        seasons.claim(0, alice, 10e18, p0);
        vm.warp(seasons.endOf(1));
        _submit(1, r1, 12e18);
        seasons.claim(1, alice, 6e18, p1);
        vm.warp(seasons.endOf(1) + 13 weeks);
        seasons.release(0, alice);
        seasons.release(1, alice);
        assertEq(infer.balanceOf(alice), 16e18);
    }

    function test_rootCannotPromiseMoreThanThePot() public {
        _open(POT);
        vm.warp(seasons.endOf(0));
        (SeasonAttestation.OracleAttestation memory a, bytes memory sig) = _att(0, bytes32(uint256(1)), POT + 1);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.OverPot.selector, POT + 1, POT));
        seasons.submitAttestedRoot(0, bytes32(uint256(1)), POT + 1, CID, RULES, a, sig);
    }

    function test_theUnassignedPartOfAPotIsReleasedAtTheRoot() public {
        _open(POT);
        vm.warp(seasons.endOf(0));
        _submit(0, bytes32(uint256(1)), 90_000_000e18);
        assertEq(seasons.available(), 310_000_000e18 - 90_000_000e18);
        assertEq(seasons.reserved(), 90_000_000e18);
    }

    // ---------------------------------------------------------------- the attestation itself

    function test_aYesToAnotherQuestionIsRefused() public {
        _open(POT);
        _openAfter(0, 1e18);
        vm.warp(seasons.endOf(0));
        (SeasonAttestation.OracleAttestation memory a, bytes memory sig) = _att(0, bytes32(uint256(1)), 5e18);
        bytes32 expected = keccak256(seasons.seasonQuestion(0, bytes32(uint256(2)), 5e18, CID, RULES, 100, 200));
        vm.expectRevert(abi.encodeWithSelector(SeasonAttestation.WrongQuestion.selector, expected, a.questionHash));
        seasons.submitAttestedRoot(0, bytes32(uint256(2)), 5e18, CID, RULES, a, sig); // signed for root 1, submitted with 2
        vm.expectRevert();
        seasons.submitAttestedRoot(0, bytes32(uint256(1)), 6e18, CID, RULES, a, sig); // another total
        vm.expectRevert();
        seasons.submitAttestedRoot(0, bytes32(uint256(1)), 5e18, "bafyother", RULES, a, sig); // another file
        vm.warp(seasons.endOf(1));
        vm.expectRevert();
        seasons.submitAttestedRoot(1, bytes32(uint256(1)), 5e18, CID, RULES, a, sig); // another season
    }

    function test_theQuestionNamesTheSeasonsOwnDates() public {
        _open(POT);
        uint256 t0 = seasons.season(0).start;
        bytes memory doc = seasons.seasonQuestion(0, keccak256("root"), 123e18, CID, RULES, 100, 200);
        bytes memory want =
            bytes(string.concat("(unix time ", vm.toString(t0), " to ", vm.toString(t0 + 13 weeks), ")"));
        assertTrue(_contains(doc, want), "the window is the season's opened dates");
    }

    function _contains(bytes memory hay, bytes memory needle) private pure returns (bool) {
        for (uint256 i; i + needle.length <= hay.length; ++i) {
            bool m = true;
            for (uint256 j; j < needle.length && m; ++j) {
                m = hay[i + j] == needle[j];
            }
            if (m) return true;
        }
        return false;
    }

    function test_aNoOrAThinPanelOrAStrangersSignatureIsRefused() public {
        _open(POT);
        vm.warp(seasons.endOf(0));
        (SeasonAttestation.OracleAttestation memory a, bytes memory sig) = _att(0, bytes32(uint256(1)), 5e18);
        a.answer = abi.encode(false);
        sig = _sign(a);
        vm.expectRevert(SeasonAttestation.NotYes.selector);
        seasons.submitAttestedRoot(0, bytes32(uint256(1)), 5e18, CID, RULES, a, sig);
        a.answer = abi.encode(true);
        a.agreed = 14;
        sig = _sign(a);
        vm.expectRevert(SeasonAttestation.NotEnoughAgreement.selector);
        seasons.submitAttestedRoot(0, bytes32(uint256(1)), 5e18, CID, RULES, a, sig);
        a.agreed = 20;
        a.panelSize = 24;
        sig = _sign(a);
        vm.expectRevert(SeasonAttestation.PanelTooSmall.selector);
        seasons.submitAttestedRoot(0, bytes32(uint256(1)), 5e18, CID, RULES, a, sig);
        a.panelSize = 60;
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(0xBAD, keccak256("anything"));
        vm.expectRevert(SeasonAttestation.InvalidSignature.selector);
        seasons.submitAttestedRoot(0, bytes32(uint256(1)), 5e18, CID, RULES, a, abi.encodePacked(r, ss, v));
    }

    function test_anExpiredOrReplayedYesIsRefused() public {
        _open(POT);
        _openAfter(0, 1e18);
        vm.warp(seasons.endOf(0));
        (SeasonAttestation.OracleAttestation memory a, bytes memory sig) = _att(0, bytes32(uint256(1)), 5e18);
        seasons.submitAttestedRoot(0, bytes32(uint256(1)), 5e18, CID, RULES, a, sig);
        vm.expectRevert(SeasonAttestation.Replayed.selector);
        seasons.submitAttestedRoot(0, bytes32(uint256(1)), 5e18, CID, RULES, a, sig);
        vm.warp(seasons.endOf(1));
        (a, sig) = _att(1, bytes32(uint256(3)), 5e17);
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(SeasonAttestation.Expired.selector);
        seasons.submitAttestedRoot(1, bytes32(uint256(3)), 5e17, CID, RULES, a, sig);
    }

    function test_aCidThatWouldBreakTheJsonIsRefused() public {
        _open(POT);
        vm.warp(seasons.endOf(0));
        (SeasonAttestation.OracleAttestation memory a, bytes memory sig) = _att(0, bytes32(uint256(1)), 5e18);
        vm.expectRevert(SeasonAttestation.BadCid.selector);
        seasons.submitAttestedRoot(0, bytes32(uint256(1)), 5e18, 'x","v":2', RULES, a, sig);
    }

    function test_printQuestionDocument() public {
        _open(POT);
        emit log_bytes(seasons.seasonQuestion(0, keccak256("root"), 123e18, CID, RULES, 100, 200));
    }

    function test_governorFallbackWaits48hAndTheAttestorCanStillWin() public {
        (bytes32 root,,) = _tree(0, 1e18, 1e18);
        _open(POT);
        vm.warp(seasons.endOf(0));
        vm.expectRevert(SeasonVault.NotGovernor.selector);
        seasons.proposeRoot(0, root, 2e18, RULES);
        vm.prank(GOVERNOR);
        seasons.proposeRoot(0, bytes32(uint256(7)), 2e18, RULES);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.TooEarly.selector, block.timestamp + 48 hours));
        seasons.applyProposal(0);

        _submit(0, root, 2e18); // a panel answers in the meantime: final, and it clears the proposal
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.NoProposal.selector, 0));
        seasons.applyProposal(0);
        assertEq(seasons.season(0).root, root);
    }

    function test_governorRootAppliesAfterTheDelay() public {
        (bytes32 root,,) = _tree(0, 1e18, 1e18);
        _open(POT);
        vm.warp(seasons.endOf(0));
        vm.prank(GOVERNOR);
        seasons.proposeRoot(0, root, 2e18, RULES);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(address(0xBEEF)); // anyone applies
        seasons.applyProposal(0);
        assertEq(seasons.season(0).root, root);
    }

    // ---------------------------------------------------------------- claims

    function test_unregisteredLeavesAreReleasedAfterTheRegistrationDeadline() public {
        (bytes32 root, bytes32[] memory pa,) = _tree(0, 60_000_000e18, 30_000_000e18);
        _open(POT);
        vm.warp(seasons.endOf(0));
        _submit(0, root, 90_000_000e18);
        seasons.claim(0, alice, 60_000_000e18, pa); // bob never registers
        uint256 deadline = seasons.registrationDeadline(0);
        assertEq(deadline, block.timestamp + 26 weeks);

        vm.expectRevert(abi.encodeWithSelector(SeasonVault.NotYet.selector, deadline));
        seasons.expire(0);
        vm.warp(deadline);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.PastDeadline.selector, 0));
        seasons.claim(0, bob, 30_000_000e18, pa);
        uint256 before = seasons.available();
        seasons.expire(0);
        assertEq(seasons.available() - before, 30_000_000e18, "bob's share is free again");
        seasons.release(0, alice); // registered before the deadline: still paid in full
        assertEq(infer.balanceOf(alice), 60_000_000e18);
        assertEq(seasons.reserved(), 0);
    }

    function test_aSeasonWhoseRootNeverComesIsReleasedWhole() public {
        _open(POT);
        vm.warp(seasons.endOf(0) + 26 weeks - 1);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.NotYet.selector, seasons.endOf(0) + 26 weeks));
        seasons.expire(0);
        vm.warp(seasons.endOf(0) + 26 weeks);
        seasons.expire(0);
        assertEq(seasons.available(), 310_000_000e18);
        // And no root can be set for it afterwards.
        vm.prank(GOVERNOR);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.AlreadyExpired.selector, 0));
        seasons.proposeRoot(0, bytes32(uint256(1)), 1e18, RULES);
    }

    function test_distributePushesABatch() public {
        (bytes32 root, bytes32[] memory pa, bytes32[] memory pb) = _tree(0, 2e18, 4e18);
        _open(POT);
        vm.warp(seasons.endOf(0));
        _submit(0, root, 6e18);
        vm.warp(block.timestamp + 1 weeks);
        SeasonVault.Claim[] memory batch = new SeasonVault.Claim[](2);
        batch[0] = SeasonVault.Claim(0, alice, 2e18, pa);
        batch[1] = SeasonVault.Claim(0, bob, 4e18, pb);
        seasons.distribute(batch);
        assertEq(infer.balanceOf(bob), uint256(4e18) * 1 weeks / 13 weeks);
        vm.warp(block.timestamp + 26 weeks); // fully vested; registration closed, release still works
        batch[0].proof = new bytes32[](0);
        batch[1].proof = new bytes32[](0);
        seasons.distribute(batch);
        assertEq(infer.balanceOf(alice), 2e18);
        assertEq(infer.balanceOf(bob), 4e18);
        seasons.distribute(batch); // idempotent
        assertEq(infer.balanceOf(bob), 4e18);
    }

    function test_aForgedLeafIsRefused() public {
        (bytes32 root, bytes32[] memory pa,) = _tree(0, 2e18, 4e18);
        _open(POT);
        vm.warp(seasons.endOf(0));
        _submit(0, root, 6e18);
        vm.expectRevert(SeasonVault.BadProof.selector);
        seasons.claim(0, alice, 3e18, pa);
    }

    // ---------------------------------------------------------------- the season's rules

    function test_aSeasonNeedsARulesCommitmentAndItHidesTheDocument() public {
        vm.prank(GOVERNOR);
        vm.expectRevert(SeasonVault.NoFormula.selector);
        seasons.openSeason(uint64(block.timestamp + 48 hours), POT, bytes32(0));
        _open(POT);
        assertEq(seasons.season(0).formula, keccak256(bytes(RULES)), "only a hash of the CID is on chain");
        // scripts/formula-cid.mjs printed this commitment for the same CID (the empty file's): the two agree.
        assertEq(keccak256(bytes(RULES)), 0x16ef3a8329661a680a98384119f1a7cbac072b985c5cecea7f3a9c7b77dd5952);
    }

    function test_rootsMustNameTheRulesCommittedAtOpening() public {
        string memory other = "bafkreiother0rules0document0that0was0not0committed0at0openingx";
        _open(POT);
        vm.warp(seasons.endOf(0));
        // Nobody can even build the question for other rules, so no request is bought for a question we refuse.
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.WrongFormula.selector, 0));
        seasons.seasonQuestion(0, bytes32(uint256(1)), 5e18, CID, other, 100, 200);
        (SeasonAttestation.OracleAttestation memory a, bytes memory sig) = _att(0, bytes32(uint256(1)), 5e18);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.WrongFormula.selector, 0));
        seasons.submitAttestedRoot(0, bytes32(uint256(1)), 5e18, CID, other, a, sig);
        vm.prank(GOVERNOR);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.WrongFormula.selector, 0));
        seasons.proposeRoot(0, bytes32(uint256(1)), 5e18, other);
        // The committed rules work, and are revealed on chain with the root.
        vm.expectEmit(true, false, false, true, address(seasons));
        emit SeasonVault.FormulaRevealed(0, RULES);
        seasons.submitAttestedRoot(0, bytes32(uint256(1)), 5e18, CID, RULES, a, sig);
    }

    function test_theQuestionNamesTheSeasonsRules() public {
        _open(POT);
        bytes memory doc = seasons.seasonQuestion(0, keccak256("root"), 123e18, CID, RULES, 100, 200);
        assertTrue(_contains(doc, bytes(string.concat("ipfs://", RULES))), "the panel is pointed at the rules document");
    }

    // ---------------------------------------------------------------- ending

    function test_endingSendsOnlyWhatIsAvailableAndOwedClaimsStillPay() public {
        (bytes32 root, bytes32[] memory pa,) = _tree(0, 60_000_000e18, 30_000_000e18);
        _open(POT);
        vm.warp(seasons.endOf(0));
        _submit(0, root, 90_000_000e18);
        seasons.claim(0, alice, 60_000_000e18, pa);

        vm.expectRevert(SeasonVault.NotGovernor.selector);
        seasons.announceEnd();
        vm.expectRevert(SeasonVault.NoEndAnnounced.selector);
        seasons.endProgram();
        vm.prank(GOVERNOR);
        seasons.announceEnd();
        vm.prank(GOVERNOR);
        vm.expectRevert(SeasonVault.ProgramIsEnded.selector);
        seasons.openSeason(uint64(block.timestamp + 48 hours), 1e18, keccak256(bytes(RULES))); // no opening while an end is announced
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.TooEarly.selector, block.timestamp + 48 hours));
        seasons.endProgram();

        vm.warp(block.timestamp + 48 hours);
        seasons.endProgram();
        assertEq(infer.balanceOf(TREASURY), 220_000_000e18, "everything but season 0's 90M");
        // Alice and (until the deadline) bob are still paid.
        vm.warp(seasons.season(0).rootSetAt + 26 weeks);
        seasons.release(0, alice);
        assertEq(infer.balanceOf(alice), 60_000_000e18);
        seasons.expire(0);
        seasons.sweep();
        assertEq(infer.balanceOf(TREASURY), 250_000_000e18, "bob's unregistered 30M follows");
        assertEq(infer.balanceOf(address(seasons)), 0);
    }

    function test_anAnnouncedEndCanBeWithdrawn() public {
        vm.startPrank(GOVERNOR);
        seasons.announceEnd();
        seasons.withdrawEnd();
        assertEq(seasons.openSeason(uint64(block.timestamp + 48 hours), 1e18, keccak256(bytes(RULES))), 0);
        vm.stopPrank();
        vm.expectRevert(SeasonVault.NoEndAnnounced.selector);
        seasons.endProgram();
    }

    /// @dev Whatever happens, the vault never holds less than it owes.
    function test_reservedNeverExceedsTheBalance() public {
        (bytes32 root, bytes32[] memory pa, bytes32[] memory pb) = _tree(0, 3e18, 4e18);
        _open(10e18);
        _openAfter(0, 20e18);
        assertEq(seasons.reserved(), 30e18);
        vm.warp(seasons.endOf(0));
        _submit(0, root, 7e18);
        assertEq(seasons.reserved(), 27e18);
        seasons.claim(0, alice, 3e18, pa);
        seasons.claim(0, bob, 4e18, pb);
        vm.warp(block.timestamp + 13 weeks);
        seasons.release(0, alice);
        seasons.release(0, bob);
        assertEq(seasons.reserved(), 20e18, "only season 1's pot");
        assertLe(seasons.reserved(), infer.balanceOf(address(seasons)));
    }

    /// @dev aee37e82cc12: an inconsistent governor root must not spend the next season's reserves.
    function test_governorLeafAboveTotalCannotRaidAnotherSeason() public {
        _open(POT);
        _openAfter(0, 210_000_000e18);
        vm.warp(seasons.endOf(0));
        bytes32 root = _leaf(0, alice, 150_000_000e18);
        vm.prank(GOVERNOR);
        seasons.proposeRoot(0, root, 1e18, RULES);
        vm.warp(block.timestamp + 48 hours);
        seasons.applyProposal(0);
        vm.warp(block.timestamp + 13 weeks);

        vm.expectRevert(abi.encodeWithSelector(SeasonVault.OverRemainingTotal.selector, 150_000_000e18, 1e18));
        seasons.claim(0, alice, 150_000_000e18, new bytes32[](0));
        assertEq(infer.balanceOf(alice), 0);
        assertEq(seasons.season(0).registered, 0);
        assertEq(seasons.reserved(), 210_000_001e18);

        vm.warp(seasons.registrationDeadline(0));
        seasons.expire(0); // no underflow: the whole declared total is unregistered
        assertEq(seasons.reserved(), 210_000_000e18);
        vm.warp(seasons.endOf(1) + 26 weeks);
        seasons.expire(1);
        assertEq(seasons.available(), 310_000_000e18);
    }

    function test_attestedLeavesAreCappedCumulativelyEvenAfterPayment() public {
        (bytes32 root, bytes32[] memory pa, bytes32[] memory pb) = _tree(0, 60_000_000e18, 64_000_000e18);
        _open(POT);
        _openAfter(0, 210_000_000e18);
        vm.warp(seasons.endOf(0));
        _submit(0, root, POT);
        vm.warp(block.timestamp + 13 weeks);
        seasons.claim(0, alice, 60_000_000e18, pa);
        seasons.claim(0, alice, 60_000_000e18, pa); // registered once, paid once
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.OverRemainingTotal.selector, 64_000_000e18, 40_000_000e18));
        seasons.claim(0, bob, 64_000_000e18, pb);
        assertEq(seasons.season(0).registered, 60_000_000e18);
        assertEq(seasons.reserved(), 250_000_000e18);
        assertEq(infer.balanceOf(alice), 60_000_000e18);
        vm.warp(seasons.registrationDeadline(0));
        seasons.expire(0);
        assertEq(seasons.reserved(), 210_000_000e18);
    }

    function test_distributeCannotRegisterBeyondTotalAndRollsBackTheBatch() public {
        (bytes32 root, bytes32[] memory pa, bytes32[] memory pb) = _tree(0, 2e18, 4e18);
        _open(POT);
        vm.warp(seasons.endOf(0));
        _submit(0, root, 5e18);
        vm.warp(block.timestamp + 13 weeks);
        SeasonVault.Claim[] memory batch = new SeasonVault.Claim[](2);
        batch[0] = SeasonVault.Claim(0, alice, 2e18, pa);
        batch[1] = SeasonVault.Claim(0, bob, 4e18, pb);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.OverRemainingTotal.selector, 4e18, 3e18));
        seasons.distribute(batch);
        assertEq(seasons.season(0).registered, 0);
        assertEq(seasons.reserved(), 5e18);
        assertEq(infer.balanceOf(alice), 0);
    }

    function testFuzz_registrationConservesTheDeclaredTotal(uint256 a, uint256 b, uint256 total) public {
        a = bound(a, 1, POT);
        b = bound(b, 1, POT);
        total = bound(total, 0, POT);
        (bytes32 root, bytes32[] memory pa, bytes32[] memory pb) = _tree(0, a, b);
        _open(POT);
        vm.warp(seasons.endOf(0));
        _submit(0, root, total);
        uint256 registered;
        if (a > total) {
            vm.expectRevert(abi.encodeWithSelector(SeasonVault.OverRemainingTotal.selector, a, total));
        } else {
            registered = a;
        }
        seasons.claim(0, alice, a, pa);
        if (b > total - registered) {
            vm.expectRevert(abi.encodeWithSelector(SeasonVault.OverRemainingTotal.selector, b, total - registered));
        } else {
            registered += b;
        }
        seasons.claim(0, bob, b, pb);
        assertEq(seasons.season(0).registered, registered);
        vm.warp(seasons.registrationDeadline(0));
        seasons.expire(0);
        assertEq(seasons.reserved(), registered);
        seasons.release(0, alice);
        seasons.release(0, bob);
        assertEq(seasons.reserved(), 0);
        assertEq(infer.balanceOf(address(seasons)), 310_000_000e18 - registered);
    }

    /// @dev af98e48a8ef8: milliseconds cannot reserve the allocation for tens of thousands of years.
    function test_millisecondStartIsRefusedWithoutReservingThePot() public {
        vm.warp(1_760_000_000);
        vm.prank(GOVERNOR);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.TooFar.selector, block.timestamp + 365 days));
        seasons.openSeason(1_760_000_000_000, 310_000_000e18, keccak256(bytes(RULES)));
        assertEq(seasons.opened(), 0);
        assertEq(seasons.reserved(), 0);
        assertEq(seasons.available(), 310_000_000e18);
        _open(POT);
    }

    function test_startHorizonIsInclusiveAndRelativeToOpening() public {
        uint256 latest = block.timestamp + 365 days;
        vm.prank(GOVERNOR);
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.TooFar.selector, latest));
        seasons.openSeason(uint64(latest + 1), POT, keccak256(bytes(RULES)));
        vm.prank(GOVERNOR);
        seasons.openSeason(uint64(latest), POT, keccak256(bytes(RULES)));
        assertEq(seasons.endOf(0), latest + 13 weeks);
        vm.warp(seasons.endOf(0) + 5 * 365 days); // long pauses are still permitted
        _open(POT);
        assertEq(seasons.opened(), 2);
    }
}

/// @dev The whole genesis: a launch with all three buckets plus sINFER, split by the GenesisSplitter.
contract GenesisSplitIntegrationTest is Test {
    function test_theBucketsAndTheTreasury() public {
        address factory = address(0xFAC7);
        address treasury = address(0x7EA);
        Infer infer = new Infer(factory);
        RegistryStub registry = new RegistryStub();
        GenesisSplitter splitter = new GenesisSplitter(address(registry), treasury);

        SeasonVault seasons = new SeasonVault(address(infer), address(0x60F), treasury);
        StakedInfer sinfer = new StakedInfer(IERC20(address(infer)));
        LegacyRedeemer redeemer = new LegacyRedeemer(
            address(infer), address(0xA1), 100_000_000e18, 1, address(0xB1), 40_000_000e18, 1, treasury, address(0xF0)
        );
        FounderStream stream = new FounderStream(address(infer), address(0xF0));

        ILaunchRegistry.Artifact[] memory a = new ILaunchRegistry.Artifact[](5);
        a[0] = ILaunchRegistry.Artifact("token", "INFER", address(infer));
        a[1] = ILaunchRegistry.Artifact("other", "SeasonVault", address(seasons));
        a[2] = ILaunchRegistry.Artifact("other", "StakedInfer", address(sinfer));
        a[3] = ILaunchRegistry.Artifact("other", "LegacyRedeemer", address(redeemer));
        a[4] = ILaunchRegistry.Artifact("other", "FounderStream", address(stream));
        registry.record(1, a);
        vm.prank(factory);
        infer.transfer(address(splitter), 700_000_000e18); // 1B − 20% pool − 10% swarm

        splitter.split(1);
        assertEq(infer.balanceOf(address(seasons)), 310_000_000e18);
        assertEq(infer.balanceOf(address(redeemer)), 140_000_000e18);
        assertEq(infer.balanceOf(address(stream)), 70_000_000e18);
        assertEq(infer.balanceOf(address(sinfer)), 0);
        assertEq(infer.balanceOf(treasury), 180_000_000e18);
    }
}

contract RegistryStub {
    mapping(uint64 => ILaunchRegistry.Artifact[]) private _a;

    function record(uint64 n, ILaunchRegistry.Artifact[] memory a) external {
        for (uint256 i; i < a.length; ++i) {
            _a[n].push(a[i]);
        }
    }

    function launchOf(uint64 n) external pure returns (ILaunchRegistry.Launch memory l) {
        (l.kind, l.launchNumber) = ("custom_token", n);
    }

    function artifactsOf(uint64 n) external view returns (ILaunchRegistry.Artifact[] memory) {
        return _a[n];
    }
}
