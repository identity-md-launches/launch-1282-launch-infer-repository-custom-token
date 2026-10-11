// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LegacyRedeemer} from "src/LegacyRedeemer.sol";

contract Plain is ERC20 {
    constructor(string memory n, address to, uint256 amount) ERC20(n, n) {
        _mint(to, amount);
    }

    function burn(uint256 value) external {
        _burn(msg.sender, value);
    }
}

contract TreasuryLike {}

/// @dev Just enough of an ERC-721 to test the NFT release.
contract MockNft {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from && msg.sender == from, "not owner");
        ownerOf[id] = to;
    }
}

/// @notice The redeemer's own logic, with plain tokens (no MIYA whitelist, no MXXN moon).
contract LegacyRedeemerTest is Test {
    address constant HOLDER = address(0xB0B);
    address constant FOUNDER = address(0xF0F0);
    uint256 constant ALLOC_A = 100_000_000e18;
    uint256 constant ALLOC_B = 40_000_000e18;
    uint256 constant RATE_A = 29.4e18; // INFER per legacy A
    uint256 constant RATE_B = 0.006e18;

    Plain infer;
    Plain a;
    Plain b;
    LegacyRedeemer r;
    TreasuryLike treasury;

    function setUp() public {
        vm.warp(1_000_000);
        treasury = new TreasuryLike();
        infer = new Plain("INFER", address(this), 1_000_000_000e18);
        a = new Plain("MIYA", HOLDER, 10_000_000e18);
        b = new Plain("MXXN", HOLDER, 9_000_000_000e18);
        r = new LegacyRedeemer(
            address(infer), address(a), ALLOC_A, RATE_A, address(b), ALLOC_B, RATE_B, address(treasury), FOUNDER
        );
        infer.transfer(address(r), r.genesisAllocation()); // what the splitter pays it
        vm.startPrank(HOLDER);
        a.approve(address(r), type(uint256).max);
        b.approve(address(r), type(uint256).max);
        vm.stopPrank();
    }

    // ---- large redemptions vest (0.5% of INFER at once per wallet, the rest over one season) ----

    function test_vest_caps() public view {
        assertEq(r.immediateCap(a), 5_880_000e18, "what 200,000 MIYA earns");
        assertEq(r.immediateCap(b), 930_000e18, "0.093% of INFER, whatever the MXXN rate");
        assertEq(r.VEST_PERIOD(), 91 days);
    }

    function test_vest_smallRedemptionIsPaidAtOnce() public {
        vm.prank(HOLDER);
        r.redeem(a, 100_000e18); // 2,940,000 INFER, under the cap
        assertEq(infer.balanceOf(HOLDER), 2_940_000e18);
        assertEq(r.claimable(HOLDER), 0);
        assertEq(r.owedVesting(), 0);
    }

    function test_vest_aboveTheCapVestsLinearlyOverASeason() public {
        vm.prank(HOLDER);
        uint256 out = r.redeem(a, 230_000e18); // 6,762,000 INFER
        assertEq(out, 6_762_000e18, "redeem reports everything earned");
        assertEq(infer.balanceOf(HOLDER), 5_880_000e18, "the cap at once");
        assertEq(r.owedVesting(), 882_000e18);
        assertEq(r.claimable(HOLDER), 0);
        vm.warp(block.timestamp + 91 days / 2);
        assertApproxEqAbs(r.claimable(HOLDER), 441_000e18, 1e18);
        vm.prank(HOLDER);
        r.claim();
        vm.warp(block.timestamp + 91 days);
        vm.prank(HOLDER);
        r.claim();
        assertEq(infer.balanceOf(HOLDER), 6_762_000e18, "all of it after the season");
        assertEq(r.owedVesting(), 0);
        vm.prank(HOLDER);
        vm.expectRevert(LegacyRedeemer.NothingOut.selector);
        r.claim();
    }

    function test_vest_eachTokenHasItsOwnCap() public {
        vm.startPrank(HOLDER);
        r.redeem(a, 200_000e18); // 5,880,000 INFER: exactly MIYA's cap, all at once
        r.redeem(b, 500_000_000e18); // 3,000,000 INFER: MXXN's own cap is 930,000
        vm.stopPrank();
        assertEq(infer.balanceOf(HOLDER), 5_880_000e18 + 930_000e18, "a full MIYA cap does not use up MXXN's");
        assertEq(r.owedVesting(), 2_070_000e18);
        assertEq(r.paidImmediately(address(a), HOLDER), 5_880_000e18);
        assertEq(r.paidImmediately(address(b), HOLDER), 930_000e18);
    }

    function test_vest_addingRestartsTheSeasonForEverythingUnvested() public {
        // Start the clock with a sliver over the cap, wait the season out, then redeem the bulk:
        // the bulk must still vest over a full season from the moment it is redeemed.
        vm.startPrank(HOLDER);
        r.redeem(a, 200_100e18); // 5,882,940: 2,940 vests
        vm.warp(block.timestamp + 91 days);
        r.redeem(a, 1_000_000e18); // 29,400,000, all above the cap
        vm.stopPrank();
        assertEq(infer.balanceOf(HOLDER), 5_880_000e18 + 2_940e18, "the old sliver paid out as it was unlocked");
        assertEq(r.claimable(HOLDER), 0, "the bulk starts a fresh season");
        (uint128 total, uint128 claimed, uint64 start) = r.vestingOf(HOLDER);
        assertEq(total, 29_400_000e18);
        assertEq(claimed, 0);
        assertEq(start, block.timestamp);
        vm.warp(block.timestamp + 91 days);
        assertEq(r.claimable(HOLDER), 29_400_000e18);
    }

    function test_vest_addingMidSeasonKeepsWhatWasAlreadyUnlocked() public {
        vm.startPrank(HOLDER);
        r.redeem(a, 230_000e18); // 882,000 vests
        vm.warp(block.timestamp + 91 days / 4);
        r.redeem(a, 10_000e18); // +294,000
        vm.stopPrank();
        // a quarter of 882,000 was unlocked and is paid out on the second redemption; the rest restarts with the new
        assertApproxEqAbs(infer.balanceOf(HOLDER), 5_880_000e18 + 220_500e18, 1e18);
        (uint128 total,,) = r.vestingOf(HOLDER);
        assertApproxEqAbs(total, 661_500e18 + 294_000e18, 1e18);
        assertApproxEqAbs(r.owedVesting(), 955_500e18, 1e18);
    }

    function test_vest_quoteForSplitsNowAndLater() public {
        (uint256 now_, uint256 later) = r.quoteFor(HOLDER, a, 230_000e18);
        assertEq(now_, 5_880_000e18);
        assertEq(later, 882_000e18);
        (now_, later) = r.quoteFor(HOLDER, a, 1_000e18);
        assertEq(now_, 29_400e18);
        assertEq(later, 0);
    }

    function test_vest_sweepLeavesWhatIsOwedToVestingWallets() public {
        vm.warp(r.closesAt() - 1 days);
        vm.prank(HOLDER);
        r.redeem(a, 230_000e18); // 882,000 vests past the close
        vm.warp(r.closesAt());
        uint256 before = infer.balanceOf(address(r));
        r.sweep();
        assertEq(infer.balanceOf(address(treasury)), before - 882_000e18);
        assertEq(infer.balanceOf(address(r)), 882_000e18);
        vm.warp(block.timestamp + 91 days);
        vm.prank(HOLDER);
        r.claim();
        assertEq(infer.balanceOf(HOLDER), 6_762_000e18, "claimable after the sweep");
        assertEq(infer.balanceOf(address(r)), 0);
    }

    function test_oneBucketForBothTokens() public view {
        assertEq(r.genesisAllocation(), 140_000_000e18);
        assertEq(address(r.token()), address(infer));
        assertEq(r.nftReturnTo(), FOUNDER);
    }

    function test_redeemsEachTokenAtItsRateAndBurnsIt() public {
        vm.startPrank(HOLDER);
        assertEq(r.redeem(a, 1_000e18), 29_400e18);
        assertEq(r.redeem(b, 1_000_000e18), 6_000e18);
        vm.stopPrank();
        assertEq(infer.balanceOf(HOLDER), 35_400e18);
        assertEq(a.totalSupply(), 10_000_000e18 - 1_000e18, "burned, not held");
        assertEq(b.totalSupply(), 9_000_000_000e18 - 1_000_000e18);
        assertEq(r.burned(address(a)), 1_000e18);
    }

    /// @dev Each community is capped at its own allocation: MIYA cannot redeem MXXN's share.
    function test_eachTokenIsCappedAtItsOwnAllocation() public {
        uint256 allOfA = ALLOC_A * 1e18 / RATE_A; // the legacy amount that exhausts A exactly (rounded down)
        vm.prank(HOLDER);
        r.redeem(a, allOfA);
        (, uint256 left) = r.quote(a, 0);
        assertLt(left, RATE_A, "A is spent to within one unit's rounding");
        vm.prank(HOLDER);
        vm.expectRevert();
        r.redeem(a, 1e18);
        vm.prank(HOLDER);
        assertEq(r.redeem(b, 1_000_000e18), 6_000e18, "B's allocation is untouched");
    }

    function test_onlyTheTwoTokens() public {
        Plain c = new Plain("OTHER", HOLDER, 1e18);
        vm.prank(HOLDER);
        vm.expectRevert(abi.encodeWithSelector(LegacyRedeemer.NotRedeemable.selector, address(c)));
        r.redeem(IERC20(address(c)), 1e18);
    }

    function test_afterOneYearClosedAndSweptToTheTreasury() public {
        vm.prank(HOLDER);
        r.redeem(a, 1_000e18);
        vm.expectRevert(abi.encodeWithSelector(LegacyRedeemer.StillOpen.selector, uint256(r.closesAt())));
        r.sweep();
        vm.warp(r.closesAt());
        vm.prank(HOLDER);
        vm.expectRevert(LegacyRedeemer.Closed.selector);
        r.redeem(a, 1e18);
        r.sweep(); // anyone
        assertEq(infer.balanceOf(address(treasury)), 140_000_000e18 - 29_400e18);
        assertEq(infer.balanceOf(address(r)), 0);
    }

    /// @dev The MIYA-unlocking NFT comes back to the founder after the year, not before.
    function test_theUnlockingNftReturnsAfterTheYear() public {
        MockNft nft = new MockNft();
        nft.mint(address(r), 7);
        vm.expectRevert(abi.encodeWithSelector(LegacyRedeemer.StillOpen.selector, uint256(r.closesAt())));
        r.releaseNft(address(nft), 7);
        vm.warp(r.closesAt());
        r.releaseNft(address(nft), 7); // anyone; the destination is fixed
        assertEq(nft.ownerOf(7), FOUNDER);
    }

    function test_dustThatRedeemsForNothingIsRefused() public {
        vm.prank(HOLDER);
        vm.expectRevert(LegacyRedeemer.NothingOut.selector);
        r.redeem(b, 1); // 1 wei of MXXN is worth 0 INFER
    }

    /// @dev df1a15ed0608: clock upkeep consumes a separate donation, never a redemption's tokens.
    function test_clockUpkeepNeedsDonatedDust() public {
        assertEq(b.balanceOf(address(r)), 0);
        vm.expectRevert();
        r.advanceClock(b, 1);
        vm.prank(HOLDER);
        b.transfer(address(r), 2);
        vm.prank(HOLDER);
        r.redeem(b, 1_000_000e18);
        assertEq(b.balanceOf(address(r)), 2, "redemption burns exactly what it receives");
        r.advanceClock(b, 2);
        assertEq(b.balanceOf(address(r)), 0);
        vm.expectRevert();
        r.advanceClock(b, 1);
    }

    function test_constructorChecks() public {
        vm.expectRevert(LegacyRedeemer.SameToken.selector);
        new LegacyRedeemer(address(infer), address(a), 1, 1, address(a), 1, 1, address(treasury), FOUNDER);
        vm.expectRevert(LegacyRedeemer.ZeroAmount.selector);
        new LegacyRedeemer(address(infer), address(a), 0, 1, address(b), 1, 1, address(treasury), FOUNDER);
    }
}

interface IMiya {
    function owner() external view returns (address);
}

interface IMilady {
    function ownerOf(uint256 id) external view returns (address);
    function transferFrom(address from, address to, uint256 id) external;
}

interface IMxxn {
    function moonConfig() external view returns (uint256 start, uint256 end);
    function burn(uint256 value) external;
}

/// @notice The two real tokens on a mainnet fork, with nothing mocked but INFER:
///   forge test --match-contract LegacyRedeemerForkTest --fork-url $MAINNET_RPC_URL
contract LegacyRedeemerForkTest is Test {
    address constant MIYA = 0xa358491CA72B793ddf21cF46C7289CC6e0ce9e5A;
    address constant MXXN = 0x2BBC21129E072A2A92A0Fd13DA750c1F977a25fB;
    address constant MXXN_HOLDER = 0x33372A300FB17200055A680CA418575455498235; // 5.47%, an EOA
    address constant MILADY = 0x5Af0D9827E0c53E4799BB226655A1de152A425a5; // MIYA's first-checked collection
    address constant FOUNDER = 0x5167D014a056E43883e1BBEa5530c3c0dC993281;
    uint256 constant CYCLE = 169_920; // MXXN's TWENTY_NINE_AND_HALF_DAY_BLOCKS
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    // Rates of the right magnitude; the launch computes its own from the redeemable supplies on the day
    // (MIYA 3,399,355.296557… = supply − dead; MXXN 5,094,704,397.563856… = all of it), rounded down.
    uint256 constant RATE_MIYA = 29_417_342_782_992_946_700; // 29.4173 INFER per MIYA
    uint256 constant RATE_MXXN = 7_851_289_668_371_509; // 0.007851 INFER per MXXN (40M, 4%)

    Plain infer;
    LegacyRedeemer r;
    address treasury;

    function setUp() public {
        if (block.chainid != 1 || MIYA.code.length == 0) vm.skip(true);
        treasury = address(new TreasuryLike());
        infer = new Plain("INFER", address(this), 1_000_000_000e18);
        r = new LegacyRedeemer(
            address(infer), MIYA, 100_000_000e18, RATE_MIYA, MXXN, 40_000_000e18, RATE_MXXN, treasury, FOUNDER
        );
        infer.transfer(address(r), r.genesisAllocation());
    }

    /// @dev The rates cannot over-promise: every redeemable unit of each token, redeemed at its rate, fits inside
    /// that token's allocation. Supplies only fall (both tokens only burn), so this holds from here on.
    function test_ratesFitTheirAllocations() public view {
        uint256 miya = IERC20(MIYA).totalSupply() - IERC20(MIYA).balanceOf(DEAD);
        uint256 mxxn = IERC20(MXXN).totalSupply();
        assertLe(miya * RATE_MIYA / 1e18, 100_000_000e18);
        assertLe(mxxn * RATE_MXXN / 1e18, 40_000_000e18);
        assertGt(miya * RATE_MIYA / 1e18, 100_000_000e18 - 1e18, "and they are not stingy: within 1 INFER");
        assertGt(mxxn * RATE_MXXN / 1e18, 40_000_000e18 - 1e18);
    }

    /// @dev A MIYA holder WITHOUT any listed NFT is refused — MIYA's check reaches Bonkler (#44), which reverts —
    /// until the redeemer holds a Milady (#1). Then the deposit passes (receiver matches) and the redeemer's own
    /// burn passes (sender matches), and MIYA's supply really falls. No pushToWhitelist anywhere.
    function test_miya_aMiladyInTheRedeemerOpensRedemption() public {
        address owner = IMiya(MIYA).owner();
        address holder = makeAddr("no-nft-holder");
        vm.prank(owner);
        IERC20(MIYA).transfer(holder, 1_000e18); // the owner may send to anyone
        vm.startPrank(holder);
        IERC20(MIYA).approve(address(r), type(uint256).max);
        vm.expectRevert();
        r.redeem(IERC20(MIYA), 1_000e18);
        vm.stopPrank();

        uint256 id = 1;
        address miladyOwner = IMilady(MILADY).ownerOf(id);
        vm.prank(miladyOwner);
        IMilady(MILADY).transferFrom(miladyOwner, address(r), id); // stands in for the operator sending one

        uint256 supplyBefore = IERC20(MIYA).totalSupply();
        vm.prank(holder);
        uint256 out = r.redeem(IERC20(MIYA), 1_000e18);
        assertEq(out, 1_000e18 * RATE_MIYA / 1e18);
        assertEq(infer.balanceOf(holder), out);
        assertEq(IERC20(MIYA).totalSupply(), supplyBefore - 1_000e18, "MIYA burned");
        assertEq(IERC20(MIYA).balanceOf(address(r)), 0);

        // It opened redemption only: MIYA trading between other non-holders is still refused.
        address other = makeAddr("other");
        vm.prank(owner);
        IERC20(MIYA).transfer(holder, 1e18);
        vm.prank(holder);
        vm.expectRevert();
        IERC20(MIYA).transfer(other, 1e18);

        vm.warp(r.closesAt());
        r.releaseNft(MILADY, id);
        assertEq(IMilady(MILADY).ownerOf(id), FOUNDER, "the Milady comes back after the year");
    }

    /// @dev MXXN: refused outside a full moon; 1-wei burns catch the clock up; redemption works inside the window;
    /// once the window passes, the redeemer advances the clock with its own dust.
    function test_mxxn_redeemsAtTheFullMoon() public {
        assertEq(IERC20(MXXN).balanceOf(address(r)), 0);
        vm.expectRevert();
        r.advanceClock(IERC20(MXXN), 1); // launch has supplied no clock-upkeep dust
        vm.startPrank(MXXN_HOLDER);
        IERC20(MXXN).approve(address(r), type(uint256).max);
        vm.expectRevert();
        r.redeem(IERC20(MXXN), 1_000_000e18); // the clock is behind: not a full moon
        // Catch the clock up the way an operator would: 1-wei burns, one cycle each.
        uint256 burns;
        (, uint256 end) = IMxxn(MXXN).moonConfig();
        while (end < block.number) {
            IMxxn(MXXN).burn(1);
            (, end) = IMxxn(MXXN).moonConfig();
            ++burns;
        }
        vm.stopPrank();
        emit log_named_uint("1-wei burns to catch the clock up", burns);
        (uint256 start,) = IMxxn(MXXN).moonConfig();
        assertGt(start, block.number, "the next full moon is ahead");

        vm.roll(start + 1); // the full moon
        vm.startPrank(MXXN_HOLDER);
        IERC20(MXXN).transfer(address(r), 1_000); // seed: dust the redeemer can burn to keep the clock
        uint256 out = r.redeem(IERC20(MXXN), 1_000_000e18);
        vm.stopPrank();
        assertEq(out, 1_000_000e18 * RATE_MXXN / 1e18);
        assertEq(infer.balanceOf(MXXN_HOLDER), out);
        assertEq(IERC20(MXXN).balanceOf(address(r)), 1_000, "only the separate dust donation remains");

        (, end) = IMxxn(MXXN).moonConfig();
        vm.roll(end + 1); // the window has passed
        vm.prank(MXXN_HOLDER);
        vm.expectRevert();
        r.redeem(IERC20(MXXN), 1_000_000e18);
        r.advanceClock(IERC20(MXXN), 1); // anyone; burns 1 wei of the redeemer's own dust
        (uint256 nextStart,) = IMxxn(MXXN).moonConfig();
        assertEq(nextStart, start + CYCLE, "one cycle on");
    }
}
