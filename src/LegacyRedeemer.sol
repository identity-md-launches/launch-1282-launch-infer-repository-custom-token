// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IBurnable {
    function burn(uint256 value) external;
}

interface IMoonClock {
    function moonConfig() external view returns (uint256 start, uint256 end);
}

interface IERC721Like {
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @title LegacyRedeemer
/// @notice Burn either of two older community tokens (MIYA, MXXN) for INFER at fixed rates, for one year.
/// Each token has its own INFER allocation; whatever is unredeemed when the year ends goes to the Treasury.
///
/// TWO FIXED SLOTS, NOT A LIST: a launch manifest's constructor arguments are static ABI words only, so the
/// tokens, their allocations and their rates are eight plain arguments.
///
/// It is ONE GenesisSplitter bucket: `token()` names INFER and `genesisAllocation()` is both allocations together.
/// Each token is capped at its own allocation, so one community cannot redeem the other's share.
///
/// Rates: INFER (1e18-scaled) per 1e18 of the legacy token, fixed at construction from each token's redeemable
/// supply on the day (allocation / redeemable, rounded down). A redemption that would exceed its token's
/// remaining allocation is refused rather than paid short.
///
/// The legacy tokens' quirks, handled so redemption needs nobody's key:
///   - MIYA lets a transfer or burn through only if the sender or receiver is MIYA's owner or holds an NFT from
///     its list, checked collection by collection in a fixed order. The 44th, Bonkler (0xF421…e2C5), REVERTS on
///     `balanceOf`, so any transfer that gets that far fails, and collections added with
///     `pushToWhitelist` sit after it and are never reached. So this contract HOLDS one NFT from a collection
///     checked earlier (a Milady, #1, is cheapest: every check stops there): deposits pass because the receiver
///     matches, and its own burns pass because the sender matches. It is given the NFT before
///     redemption opens; after the year, `releaseNft` returns it to `nftReturnTo`.
///   - MXXN lets a holder transfer only during a "full moon" window, which advances one cycle per transfer made
///     after it ends. Burns always pass (its owner is the zero address and a burn goes there). `advanceClock`
///     burns 1 wei of this contract's own MXXN per step so the window keeps up with the chain; redemption works
///     during windows, and outside them MXXN refuses the deposit.
///
/// LARGE REDEMPTIONS VEST. Per token, a wallet receives at once up to a fixed limit: from
/// MIYA, what 200,000 MIYA earns at its rate (`IMMEDIATE_A`); from MXXN, 930,000 INFER, 0.093% of INFER's
/// supply (`IMMEDIATE_B_INFER`, held in INFER so
/// the rate does not move it). Anything above it vests linearly over `VEST_PERIOD` (one 13-week season) and is
/// collected with `claim`. Adding to a vesting balance
/// restarts the season for everything still unvested, so a wallet cannot start its clock with dust, wait, and
/// then redeem the bulk already unlocked. INFER owed to vesting wallets is never swept.
contract LegacyRedeemer {
    using SafeERC20 for IERC20;

    uint256 public constant REDEMPTION_PERIOD = 365 days;
    uint256 public constant VEST_PERIOD = 91 days; // one season
    uint256 public constant IMMEDIATE_A = 200_000e18; // legacy A (MIYA) a wallet may redeem without vesting
    uint256 public constant IMMEDIATE_B_INFER = 930_000e18; // INFER a wallet may receive at once from legacy B (MXXN)

    IERC20 public immutable token; // INFER
    IERC20 public immutable legacyA; // MIYA
    IERC20 public immutable legacyB; // MXXN
    uint256 public immutable allocationA;
    uint256 public immutable allocationB;
    uint256 public immutable rateA; // INFER per 1e18 legacyA, 1e18-scaled
    uint256 public immutable rateB;
    address public immutable treasury;
    address public immutable nftReturnTo; // where the MIYA-unlocking NFT goes after the year
    uint64 public immutable closesAt;
    uint256 public immutable immediateCapA; // INFER a wallet may receive at once from legacy A (MIYA)
    uint256 public immutable immediateCapB; // ... and from legacy B (MXXN)

    mapping(address legacy => uint256) public redeemed; // INFER paid out, per legacy token
    mapping(address legacy => uint256) public burned; // legacy burned through redemptions

    struct Vesting {
        uint128 total; // INFER on the current schedule (unclaimed at its start, plus what was added)
        uint128 claimed; // of `total`, already paid
        uint64 start; // the schedule runs from here for VEST_PERIOD
    }

    mapping(address legacy => mapping(address holder => uint256)) public paidImmediately; // INFER paid at once, per token
    mapping(address holder => Vesting) public vestingOf;
    uint256 public owedVesting; // INFER held for vesting wallets: never swept

    event Redeemed(address indexed legacy, address indexed holder, uint256 legacyIn, uint256 inferOut);
    event Vested(address indexed holder, uint256 added, uint256 onSchedule, uint256 start);
    event Claimed(address indexed holder, uint256 amount);
    event Swept(uint256 amount);
    event NftReleased(address indexed collection, uint256 indexed tokenId, address to);

    error ZeroAddress();
    error ZeroAmount();
    error SameToken();
    error NotRedeemable(address legacy);
    error Closed();
    error StillOpen(uint256 closesAt);
    error NothingOut();
    error Exhausted(address legacy, uint256 wanted, uint256 left);

    constructor(
        address token_,
        address legacyA_,
        uint256 allocationA_,
        uint256 rateA_,
        address legacyB_,
        uint256 allocationB_,
        uint256 rateB_,
        address treasury_,
        address nftReturnTo_
    ) {
        if (
            token_ == address(0) || legacyA_ == address(0) || legacyB_ == address(0) || treasury_ == address(0)
                || nftReturnTo_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (legacyA_ == legacyB_) revert SameToken();
        if (allocationA_ == 0 || allocationB_ == 0 || rateA_ == 0 || rateB_ == 0) revert ZeroAmount();
        token = IERC20(token_);
        (legacyA, allocationA, rateA) = (IERC20(legacyA_), allocationA_, rateA_);
        (legacyB, allocationB, rateB) = (IERC20(legacyB_), allocationB_, rateB_);
        treasury = treasury_;
        nftReturnTo = nftReturnTo_;
        closesAt = uint64(block.timestamp + REDEMPTION_PERIOD);
        immediateCapA = IMMEDIATE_A * rateA_ / 1e18;
        immediateCapB = IMMEDIATE_B_INFER;
    }

    /// @notice The INFER this bucket is paid at launch: both allocations.
    function genesisAllocation() external view returns (uint256) {
        return allocationA + allocationB;
    }

    /// @notice Burn `amount` of `legacy` (MIYA or MXXN) for INFER. Approve this contract first. `out` is the whole
    /// INFER this redemption earns; the part above the wallet's remaining immediate cap for that token vests.
    function redeem(IERC20 legacy, uint256 amount) external returns (uint256 out) {
        if (block.timestamp >= closesAt) revert Closed();
        if (amount == 0) revert ZeroAmount();
        (uint256 allocation, uint256 rate) = _terms(legacy);
        out = amount * rate / 1e18;
        if (out == 0) revert NothingOut();
        uint256 left = allocation - redeemed[address(legacy)];
        if (out > left) revert Exhausted(address(legacy), out, left);
        redeemed[address(legacy)] += out;
        burned[address(legacy)] += amount;
        uint256 roomNow = immediateCap(legacy) - paidImmediately[address(legacy)][msg.sender];
        uint256 now_ = out < roomNow ? out : roomNow;
        uint256 later = out - now_;
        paidImmediately[address(legacy)][msg.sender] += now_;
        if (later != 0) _addVesting(msg.sender, later);
        legacy.safeTransferFrom(msg.sender, address(this), amount);
        IBurnable(address(legacy)).burn(amount);
        if (now_ != 0) token.safeTransfer(msg.sender, now_);
        emit Redeemed(address(legacy), msg.sender, amount, out);
    }

    /// @notice Collect the vested part of your redemptions so far.
    function claim() external returns (uint256 amount) {
        amount = claimable(msg.sender);
        if (amount == 0) revert NothingOut();
        vestingOf[msg.sender].claimed += uint128(amount);
        owedVesting -= amount;
        token.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    /// @notice INFER `holder` can collect now.
    function claimable(address holder) public view returns (uint256) {
        Vesting memory v = vestingOf[holder];
        if (v.total == 0) return 0;
        uint256 elapsed = block.timestamp - v.start;
        uint256 unlocked = elapsed >= VEST_PERIOD ? v.total : uint256(v.total) * elapsed / VEST_PERIOD;
        return unlocked - v.claimed;
    }

    /// @dev Pay out what has unlocked, then put the rest plus `added` on a fresh season from now.
    function _addVesting(address holder, uint256 added) private {
        uint256 ready = claimable(holder);
        Vesting memory v = vestingOf[holder];
        uint256 unvested = uint256(v.total) - v.claimed - ready;
        if (ready != 0) {
            owedVesting -= ready;
            token.safeTransfer(holder, ready);
            emit Claimed(holder, ready);
        }
        uint256 onSchedule = unvested + added;
        vestingOf[holder] = Vesting(uint128(onSchedule), 0, uint64(block.timestamp));
        owedVesting += added;
        emit Vested(holder, added, onSchedule, block.timestamp);
    }

    /// @notice What `amount` of `legacy` redeems for now, and how much of that token's allocation is left.
    function quote(IERC20 legacy, uint256 amount) external view returns (uint256 out, uint256 left) {
        (uint256 allocation, uint256 rate) = _terms(legacy);
        return (amount * rate / 1e18, allocation - redeemed[address(legacy)]);
    }

    /// @notice How `holder` redeeming `amount` of `legacy` would be paid: at once, and vesting over a season.
    function quoteFor(address holder, IERC20 legacy, uint256 amount)
        external
        view
        returns (uint256 now_, uint256 later)
    {
        (, uint256 rate) = _terms(legacy);
        uint256 out = amount * rate / 1e18;
        uint256 roomNow = immediateCap(legacy) - paidImmediately[address(legacy)][holder];
        now_ = out < roomNow ? out : roomNow;
        later = out - now_;
    }

    /// @notice After the year, everything left (both tokens' unredeemed INFER) goes to the Treasury. Anyone. INFER
    /// still owed to vesting wallets stays for them to claim.
    function sweep() external {
        if (block.timestamp < closesAt) revert StillOpen(closesAt);
        uint256 amount = token.balanceOf(address(this)) - owedVesting;
        token.safeTransfer(treasury, amount);
        emit Swept(amount);
    }

    /// @notice Burn 1 wei of this contract's own `legacy` balance up to `steps` times. For MXXN (legacyB), stop
    /// once its full-moon window is current or ahead; each necessary burn advances one cycle. For legacyA it
    /// only burns dust. Anyone.
    function advanceClock(IERC20 legacy, uint256 steps) external {
        _terms(legacy);
        for (uint256 i; i < steps; ++i) {
            if (legacy == legacyB) {
                (, uint256 end) = IMoonClock(address(legacy)).moonConfig();
                if (block.number <= end) break;
            }
            IBurnable(address(legacy)).burn(1);
        }
    }

    /// @notice Accept the NFT that unlocks MIYA transfers (safeTransferFrom calls this).
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /// @notice After the year, return an NFT this contract holds to `nftReturnTo`. Anyone may call it; the
    /// destination is fixed at construction.
    function releaseNft(address collection, uint256 tokenId) external {
        if (block.timestamp < closesAt) revert StillOpen(closesAt);
        IERC721Like(collection).transferFrom(address(this), nftReturnTo, tokenId);
        emit NftReleased(collection, tokenId, nftReturnTo);
    }

    /// @notice INFER a wallet may receive at once from `legacy`; above it, redemptions vest.
    function immediateCap(IERC20 legacy) public view returns (uint256) {
        if (legacy == legacyA) return immediateCapA;
        if (legacy == legacyB) return immediateCapB;
        revert NotRedeemable(address(legacy));
    }

    function _terms(IERC20 legacy) private view returns (uint256 allocation, uint256 rate) {
        if (legacy == legacyA) return (allocationA, rateA);
        if (legacy == legacyB) return (allocationB, rateB);
        revert NotRedeemable(address(legacy));
    }
}
