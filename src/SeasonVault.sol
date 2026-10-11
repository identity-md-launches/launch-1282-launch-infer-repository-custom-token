// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {SeasonAttestation} from "./SeasonAttestation.sol";

/// @title SeasonVault
/// @notice The 31% points allocation, paid out in up to five 13-week seasons that the governor opens one at a time:
/// season, pause, season, pause, or no further season at all. Each season's claims are paid against a Merkle root
/// of that season's points and vest linearly over 13 weeks from the root. What no season uses goes to the Treasury
/// once the program is ended.
///
/// Opening: `openSeason(startsAt, pot, formula)` by the governor, at least NOTICE (48 hours) and at most MAX_NOTICE (365 days)
/// ahead and never overlapping the season before. Every season is exactly SEASON (13 weeks) long, and once opened
/// neither its dates, its pot nor its rules can change. Pauses are the gaps between seasons, of any length; not opening another is how a
/// season is skipped, and the earlier seasons keep vesting regardless. Nothing about the schedule is in the source:
/// a season's dates and pot become public when it is opened.
///
/// Each season's points rules are a document of the governor's, committed at opening as `formula` =
/// keccak256(bytes(cid)) of its IPFS CID: the commitment reveals nothing, and the document is posted to IPFS only
/// after the season, when a panel is asked about the leaf file. Whoever submits a root names the rules CID, and it
/// must match the commitment, so the rules a season was judged by are the ones fixed before it began. The CID must
/// be computable before upload: a CIDv1 raw block (one file under 256 KiB, `ipfs add --cid-version=1
/// --raw-leaves`), see scripts/formula-cid.mjs.
///
/// Why the pot is fixed at opening: roots are permissionless (anyone may submit one with a swarm panel's YES), and
/// the formula splits a season's total in proportion to points, so a total chosen by whoever submits first would
/// let anyone claim the whole balance for one season. The governor's pot is the cap, set before any points accrue.
///
/// Who sets a season's root, once it has ended:
///   - anyone, with a swarm panel's signed YES to "does this published leaf file give exactly the allocations the
///     points formula produces for this season, with this root and total?" (`submitAttestedRoot`, verified by
///     SeasonAttestation): immediate and final; or
///   - the `governor`, as a fallback when a panel refuses, behind a 48-hour delay, during which an attested root
///     can still be submitted and the governor can withdraw its proposal.
/// The root's `total` may not exceed the season's pot; the rest of the pot is released the moment the root is set.
///
/// Paying out: claims vest linearly over SEASON from the moment the root is set, and must be registered within
/// REGISTRATION (26 weeks) of it. `claim` registers an entitlement with its proof and releases what has vested;
/// afterwards `release` needs no proof; `distribute` does either for a batch, so a keeper can push everyone's INFER.
/// After the registration deadline, `expire` releases what was never registered. A season whose root never comes
/// is released whole by `expire` once ROOT_DEADLINE (26 weeks) has passed since it ended.
///
/// Released means back in `available()`: the balance not owed or reserved, which only a later season's pot or, once
/// the program is ended, the Treasury can take.
contract SeasonVault is SeasonAttestation {
    using SafeERC20 for IERC20;

    uint256 public constant genesisAllocation = 310_000_000e18;
    uint256 public constant SEASONS = 5;
    uint256 public constant SEASON = 13 weeks;
    uint256 public constant NOTICE = 48 hours;
    uint256 public constant MAX_NOTICE = 365 days;
    uint256 public constant REGISTRATION = 26 weeks;
    uint256 public constant ROOT_DEADLINE = 26 weeks;
    uint256 public constant GOVERNOR_DELAY = 48 hours;

    IERC20 public immutable token;
    address public immutable governor;
    address public immutable treasury;

    struct Season {
        uint64 start; // 0 = not opened
        uint64 rootSetAt;
        bool expired; // its unregistered (or, rootless, whole) amount has been released
        uint256 pot; // fixed at opening
        bytes32 formula; // keccak256(bytes(cid)) of the season's rules document, fixed at opening
        bytes32 root;
        uint256 total; // sum of the root's leaves
        uint256 registered; // entitlements claimed so far
        uint256 paid;
        bytes32 pendingRoot; // governor's proposal
        uint256 pendingTotal;
        uint64 pendingEta;
    }

    struct Entitlement {
        uint256 amount;
        uint256 paid;
    }

    Season[SEASONS] private _seasons;
    uint256 public opened; // seasons opened so far
    /// @notice INFER this vault owes or holds back: open pots, unpaid entitlements, unregistered leaves before expiry.
    uint256 public reserved;
    uint64 public endEta; // governor's announced end; 0 = none
    bool public ended;
    mapping(uint256 season => mapping(address account => Entitlement)) public entitlements;

    event SeasonOpened(uint256 indexed season, uint256 start, uint256 end, uint256 pot, bytes32 formula);
    event FormulaRevealed(uint256 indexed season, string formulaCid);
    event RootSet(uint256 indexed season, bytes32 root, uint256 total, bool attested);
    event RootAttested(uint256 indexed season, bytes32 indexed requestId, string cid);
    event RootProposed(uint256 indexed season, bytes32 root, uint256 total, uint256 eta);
    event ProposalWithdrawn(uint256 indexed season);
    event Registered(uint256 indexed season, address indexed account, uint256 amount);
    event Released(uint256 indexed season, address indexed account, uint256 amount);
    event SeasonExpired(uint256 indexed season, uint256 amount);
    event EndAnnounced(uint256 eta);
    event EndWithdrawn();
    event ProgramEnded();
    event Swept(uint256 amount);

    error ZeroAddress();
    error NoSuchSeason(uint256 season);
    error NotGovernor();
    error AllSeasonsOpened();
    error ProgramIsEnded();
    error TooSoon(uint256 earliest);
    error TooFar(uint256 latest);
    error Overlaps(uint256 previousEnd);
    error ZeroPot();
    error NoFormula();
    error WrongFormula(uint256 season);
    error OverAvailable(uint256 amount, uint256 available);
    error SeasonNotOver(uint256 season);
    error RootAlreadySet(uint256 season);
    error OverPot(uint256 total, uint256 pot);
    error NoProposal(uint256 season);
    error TooEarly(uint256 eta);
    error NoRoot(uint256 season);
    error PastDeadline(uint256 season);
    error BadProof();
    error OverRemainingTotal(uint256 amount, uint256 remaining);
    error NotYet(uint256 at);
    error AlreadyExpired(uint256 season);
    error NoEndAnnounced();
    error NotEnded();

    constructor(address token_, address governor_, address treasury_) {
        if (token_ == address(0) || governor_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        token = IERC20(token_);
        governor = governor_;
        treasury = treasury_;
    }

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    // ---------------------------------------------------------------- schedule

    /// @notice Announce the next season: it runs [startsAt, startsAt + SEASON), pays out at most `pot`, and is
    /// judged by the rules document whose IPFS CID hashes to `formula` (keccak256(bytes(cid))). At least NOTICE
    /// ahead, at most MAX_NOTICE ahead, not before the previous season has ended, and never changed afterwards. Not while an end of the
    /// program is announced.
    function openSeason(uint64 startsAt, uint256 pot, bytes32 formula) external onlyGovernor returns (uint256 s) {
        if (ended || endEta != 0) revert ProgramIsEnded();
        s = opened;
        if (s == SEASONS) revert AllSeasonsOpened();
        if (startsAt < block.timestamp + NOTICE) revert TooSoon(block.timestamp + NOTICE);
        if (startsAt > block.timestamp + MAX_NOTICE) revert TooFar(block.timestamp + MAX_NOTICE);
        if (s > 0 && startsAt < endOf(s - 1)) revert Overlaps(endOf(s - 1));
        if (pot == 0) revert ZeroPot();
        if (formula == bytes32(0)) revert NoFormula();
        uint256 free = available();
        if (pot > free) revert OverAvailable(pot, free);
        Season storage x = _seasons[s];
        (x.start, x.pot, x.formula) = (startsAt, pot, formula);
        reserved += pot;
        opened = s + 1;
        emit SeasonOpened(s, startsAt, startsAt + SEASON, pot, formula);
    }

    function endOf(uint256 s) public view returns (uint256) {
        return _opened(s).start + SEASON;
    }

    /// @notice Last moment to register a claim for season `s` (0 before its root is set).
    function registrationDeadline(uint256 s) public view returns (uint256) {
        uint64 at = _opened(s).rootSetAt;
        return at == 0 ? 0 : at + REGISTRATION;
    }

    function season(uint256 s) external view returns (Season memory) {
        _check(s);
        return _seasons[s];
    }

    /// @notice INFER not owed or held back for any season: what a new season's pot, or the Treasury once the
    /// program is ended, can take.
    function available() public view returns (uint256) {
        uint256 held = token.balanceOf(address(this));
        return held > reserved ? held - reserved : 0;
    }

    // ---------------------------------------------------------------- roots

    /// @notice Set a season's root with a swarm panel's YES. Anyone; final. The leaf file at `cid` is what the
    /// panel checked, and it is what claimants build their proofs from; `formulaCid` is the season's rules document,
    /// which must be the one committed when the season was opened.
    function submitAttestedRoot(
        uint256 s,
        bytes32 root,
        uint256 total,
        string calldata cid,
        string calldata formulaCid,
        OracleAttestation calldata a,
        bytes calldata sig
    ) external {
        _checkFormula(s, formulaCid);
        _verifyYes(a, sig, _questionHash(s, root, total, cid, formulaCid, a));
        _setRoot(s, root, total, true);
        emit RootAttested(s, a.requestId, cid);
        emit FormulaRevealed(s, formulaCid);
    }

    /// @notice The question document a YES for season `s` must answer (see SeasonAttestation). Refuses a rules CID
    /// other than the one committed, so a request is never bought for a question the vault would refuse.
    function seasonQuestion(
        uint256 s,
        bytes32 root,
        uint256 total,
        string calldata cid,
        string calldata formulaCid,
        uint64 fromBlock,
        uint64 toBlock
    ) external view returns (bytes memory) {
        _checkFormula(s, formulaCid);
        return questionDocument(s, root, total, cid, formulaCid, fromBlock, toBlock);
    }

    function _window(uint256 s) internal view override returns (uint256 from, uint256 to) {
        from = _opened(s).start;
        to = from + SEASON;
    }

    /// @notice Fallback: the governor proposes a root; anyone may apply it after 48 hours. The governor reveals the
    /// season's rules document too, so the rules are public even when no panel checked the file.
    function proposeRoot(uint256 s, bytes32 root, uint256 total, string calldata formulaCid) external onlyGovernor {
        _checkFormula(s, formulaCid);
        _checkRootable(s, total);
        Season storage x = _seasons[s];
        (x.pendingRoot, x.pendingTotal, x.pendingEta) = (root, total, uint64(block.timestamp + GOVERNOR_DELAY));
        emit RootProposed(s, root, total, x.pendingEta);
        emit FormulaRevealed(s, formulaCid);
    }

    function withdrawProposal(uint256 s) external onlyGovernor {
        Season storage x = _opened(s);
        if (x.pendingEta == 0) revert NoProposal(s);
        (x.pendingRoot, x.pendingTotal, x.pendingEta) = (0, 0, 0);
        emit ProposalWithdrawn(s);
    }

    function applyProposal(uint256 s) external {
        Season storage x = _opened(s);
        if (x.pendingEta == 0) revert NoProposal(s);
        if (block.timestamp < x.pendingEta) revert TooEarly(x.pendingEta);
        _setRoot(s, x.pendingRoot, x.pendingTotal, false);
    }

    // ---------------------------------------------------------------- claims

    /// @notice Register `account`'s entitlement for season `s` and release what has vested. Anyone may call it;
    /// the INFER always goes to `account`.
    function claim(uint256 s, address account, uint256 amount, bytes32[] calldata proof) public returns (uint256) {
        _register(s, account, amount, proof);
        return _release(s, account);
    }

    /// @notice Release what has vested on an already registered entitlement. Anyone.
    function release(uint256 s, address account) public returns (uint256) {
        _opened(s);
        return _release(s, account);
    }

    struct Claim {
        uint256 season;
        address account;
        uint256 amount;
        bytes32[] proof; // empty: release only
    }

    /// @notice Push INFER to many accounts in one transaction: registers where a proof is given, then releases.
    function distribute(Claim[] calldata batch) external {
        for (uint256 i; i < batch.length; ++i) {
            Claim calldata c = batch[i];
            _opened(c.season);
            if (c.proof.length != 0 && entitlements[c.season][c.account].amount == 0) {
                _register(c.season, c.account, c.amount, c.proof);
            }
            _release(c.season, c.account);
        }
    }

    /// @notice What `account` could be released for season `s` now.
    function releasable(uint256 s, address account) public view returns (uint256) {
        Entitlement storage e = entitlements[s][account];
        return _vested(s, e.amount) - e.paid;
    }

    // ---------------------------------------------------------------- releasing and ending

    /// @notice Release what season `s` will never pay: after its registration deadline, the leaves nobody
    /// registered; or, if it never got a root, its whole pot once ROOT_DEADLINE has passed since it ended. Anyone.
    function expire(uint256 s) external {
        Season storage x = _opened(s);
        if (x.expired) revert AlreadyExpired(s);
        uint256 amount;
        if (x.rootSetAt != 0) {
            uint256 at = x.rootSetAt + REGISTRATION;
            if (block.timestamp < at) revert NotYet(at);
            amount = x.total - x.registered;
        } else {
            uint256 at = endOf(s) + ROOT_DEADLINE;
            if (block.timestamp < at) revert NotYet(at);
            amount = x.pot;
            (x.pendingRoot, x.pendingTotal, x.pendingEta) = (0, 0, 0);
        }
        x.expired = true;
        reserved -= amount;
        emit SeasonExpired(s, amount);
    }

    /// @notice Announce the end of the program: after GOVERNOR_DELAY no season can be opened and `available()` goes
    /// to the Treasury. Seasons already opened carry on and keep everything reserved for them.
    function announceEnd() external onlyGovernor {
        if (ended) revert ProgramIsEnded();
        endEta = uint64(block.timestamp + GOVERNOR_DELAY);
        emit EndAnnounced(endEta);
    }

    function withdrawEnd() external onlyGovernor {
        if (ended || endEta == 0) revert NoEndAnnounced();
        endEta = 0;
        emit EndWithdrawn();
    }

    /// @notice End the program once its announcement has run its delay, sending what is available to the
    /// Treasury. Anyone.
    function endProgram() external {
        if (ended) revert ProgramIsEnded();
        if (endEta == 0) revert NoEndAnnounced();
        if (block.timestamp < endEta) revert TooEarly(endEta);
        ended = true;
        emit ProgramEnded();
        _sweep();
    }

    /// @notice After the end, what later expiries release also goes to the Treasury. Anyone.
    function sweep() external {
        if (!ended) revert NotEnded();
        _sweep();
    }

    // ---------------------------------------------------------------- internals

    function _sweep() private {
        uint256 amount = available();
        if (amount != 0) token.safeTransfer(treasury, amount);
        emit Swept(amount);
    }

    function _check(uint256 s) private pure {
        if (s >= SEASONS) revert NoSuchSeason(s);
    }

    function _opened(uint256 s) private view returns (Season storage x) {
        _check(s);
        x = _seasons[s];
        if (x.start == 0) revert NoSuchSeason(s);
    }

    function _checkFormula(uint256 s, string calldata formulaCid) private view {
        _opened(s);
        _checkCid(formulaCid);
        if (keccak256(bytes(formulaCid)) != _seasons[s].formula) revert WrongFormula(s);
    }

    function _checkRootable(uint256 s, uint256 total) private view {
        Season storage x = _opened(s);
        if (block.timestamp < x.start + SEASON) revert SeasonNotOver(s);
        if (x.rootSetAt != 0) revert RootAlreadySet(s);
        if (x.expired) revert AlreadyExpired(s);
        if (total > x.pot) revert OverPot(total, x.pot);
    }

    function _setRoot(uint256 s, bytes32 root, uint256 total, bool attested) private {
        _checkRootable(s, total);
        Season storage x = _seasons[s];
        (x.root, x.total, x.rootSetAt) = (root, total, uint64(block.timestamp));
        (x.pendingRoot, x.pendingTotal, x.pendingEta) = (0, 0, 0);
        reserved -= x.pot - total; // the pot's unassigned part is released at once
        emit RootSet(s, root, total, attested);
    }

    function _register(uint256 s, address account, uint256 amount, bytes32[] calldata proof) private {
        Season storage x = _opened(s);
        if (x.rootSetAt == 0) revert NoRoot(s);
        if (x.expired || block.timestamp >= x.rootSetAt + REGISTRATION) revert PastDeadline(s);
        Entitlement storage e = entitlements[s][account];
        if (e.amount != 0) return; // already registered: release only
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(s, account, amount))));
        if (!MerkleProof.verifyCalldata(proof, x.root, leaf)) revert BadProof();
        uint256 remaining = x.total - x.registered;
        if (amount > remaining) revert OverRemainingTotal(amount, remaining);
        e.amount = amount;
        x.registered += amount;
        emit Registered(s, account, amount);
    }

    function _release(uint256 s, address account) private returns (uint256 amount) {
        Entitlement storage e = entitlements[s][account];
        amount = _vested(s, e.amount) - e.paid;
        if (amount == 0) return 0;
        e.paid += amount;
        _seasons[s].paid += amount;
        reserved -= amount;
        token.safeTransfer(account, amount);
        emit Released(s, account, amount);
    }

    function _vested(uint256 s, uint256 amount) private view returns (uint256) {
        uint256 from = _seasons[s].rootSetAt;
        if (from == 0 || block.timestamp <= from) return 0;
        uint256 elapsed = block.timestamp - from;
        return elapsed >= SEASON ? amount : amount * elapsed / SEASON;
    }
}
