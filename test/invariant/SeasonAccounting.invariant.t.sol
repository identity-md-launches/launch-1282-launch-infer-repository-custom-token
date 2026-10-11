// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {InferFixtures} from "../helpers/InferFixtures.sol";
import {InferToken} from "src/InferToken.sol";
import {SeasonVault} from "src/SeasonVault.sol";

/// @dev The model stores inputs and observed transfers, never copies the vault's reserved/paid counters.
contract SeasonAccountingHandler is InferFixtures {
    string internal constant RULES = "bafySeasonInvariantRules";
    InferToken public token;
    SeasonVault public vault;
    address[4] public actors;

    struct Model {
        uint256 start;
        uint256 pot;
        uint256 total;
        uint256 rootAt;
        uint256 proposalEta;
        bool expired;
        uint256[4] allocation;
        uint256[4] received;
        bool[4] registered;
    }
    Model[5] internal model;
    uint256 public opened;
    uint256 public funded;
    uint256 public swept;
    uint256 public endEta;
    bool public ended;

    constructor() {
        token = new InferToken();
        vault = new SeasonVault(address(token), GOVERNOR, TREASURY);
        funded = 310_000_000e18;
        token.transfer(address(vault), funded);
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("season actor ", vm.toString(i)));
        }
        open(100_000_000e18, 0);
        open(80_000_000e18, 0);
        vm.warp(model[0].start + 13 weeks);
        propose(0, 90_000_000e18);
        vm.warp(block.timestamp + 48 hours);
        applyRoot(0);
        claim(0, 0, false);
    }

    function open(uint256 pot, uint256 gap) public {
        uint256 start = block.timestamp + 48 hours + bound(gap, 0, 7 days);
        if (opened != 0) start = max(start, model[opened - 1].start + 13 weeks);
        if (ended || endEta != 0) {
            vm.prank(GOVERNOR);
            vm.expectRevert(SeasonVault.ProgramIsEnded.selector);
            vault.openSeason(uint64(start), 4, keccak256(bytes(RULES)));
            return;
        }
        if (opened == 5) {
            vm.prank(GOVERNOR);
            vm.expectRevert(SeasonVault.AllSeasonsOpened.selector);
            vault.openSeason(uint64(start), 4, keccak256(bytes(RULES)));
            return;
        }
        if (start > block.timestamp + 365 days || vault.available() < 4) return;
        pot = bound(pot, 4, vault.available());
        vm.prank(GOVERNOR);
        uint256 s = vault.openSeason(uint64(start), pot, keccak256(bytes(RULES)));
        assertEq(s, opened);
        model[s].start = start;
        model[s].pot = pot;
        opened++;
    }

    function propose(uint256 seed, uint256 total) public {
        uint256 s = seed % opened;
        Model storage m = model[s];
        if (m.rootAt != 0 || m.expired || block.timestamp < m.start + 13 weeks) return;
        total = bound(total, 4, m.pot);
        m.total = total;
        for (uint256 i; i < 4; ++i) {
            m.allocation[i] = total / 4 + (i == 3 ? total % 4 : 0);
        }
        vm.prank(GOVERNOR);
        vault.proposeRoot(s, _root(s), total, RULES);
        m.proposalEta = block.timestamp + 48 hours;
    }

    function withdrawProposal(uint256 seed) public {
        uint256 s = seed % opened;
        Model storage m = model[s];
        vm.prank(GOVERNOR);
        if (m.proposalEta == 0) vm.expectRevert(abi.encodeWithSelector(SeasonVault.NoProposal.selector, s));
        vault.withdrawProposal(s);
        m.proposalEta = 0;
    }

    function applyRoot(uint256 seed) public {
        uint256 s = seed % opened;
        Model storage m = model[s];
        if (m.proposalEta == 0) {
            vm.expectRevert(abi.encodeWithSelector(SeasonVault.NoProposal.selector, s));
            vault.applyProposal(s);
        } else if (block.timestamp < m.proposalEta) {
            vm.expectRevert(abi.encodeWithSelector(SeasonVault.TooEarly.selector, m.proposalEta));
            vault.applyProposal(s);
        } else {
            vault.applyProposal(s);
            m.rootAt = block.timestamp;
            m.proposalEta = 0;
        }
    }

    function claim(uint256 seasonSeed, uint256 actorSeed, bool batch) public {
        uint256 s = seasonSeed % opened;
        uint256 i = actorSeed % 4;
        Model storage m = model[s];
        address actor = actors[i];
        if (m.rootAt == 0 || m.expired || block.timestamp >= m.rootAt + 26 weeks) return;
        uint256 beforeBalance = token.balanceOf(actor);
        if (batch) {
            // Repeat the same leaf inside a batch: registration and payment must both be idempotent.
            SeasonVault.Claim[] memory items = new SeasonVault.Claim[](2);
            items[0] = SeasonVault.Claim(s, actor, m.allocation[i], _proof(s, i));
            items[1] = items[0];
            vault.distribute(items);
        } else {
            vault.claim(s, actor, m.allocation[i], _proof(s, i));
        }
        m.registered[i] = true;
        m.received[i] += token.balanceOf(actor) - beforeBalance;
        assertLe(m.received[i], m.allocation[i]);
        assertEq(vault.release(s, actor), 0, "duplicate payout at the same timestamp");
    }

    function release(uint256 seasonSeed, uint256 actorSeed) public {
        uint256 s = seasonSeed % opened;
        uint256 i = actorSeed % 4;
        uint256 beforeBalance = token.balanceOf(actors[i]);
        uint256 paid = vault.release(s, actors[i]);
        assertEq(token.balanceOf(actors[i]) - beforeBalance, paid);
        model[s].received[i] += paid;
        assertEq(vault.release(s, actors[i]), 0);
    }

    function expire(uint256 seed) public {
        uint256 s = seed % opened;
        Model storage m = model[s];
        uint256 at = m.rootAt != 0 ? m.rootAt + 26 weeks : m.start + 39 weeks;
        if (m.expired) {
            vm.expectRevert(abi.encodeWithSelector(SeasonVault.AlreadyExpired.selector, s));
            vault.expire(s);
        } else if (block.timestamp < at) {
            vm.expectRevert(abi.encodeWithSelector(SeasonVault.NotYet.selector, at));
            vault.expire(s);
        } else {
            vault.expire(s);
            m.expired = true;
            if (m.rootAt == 0) m.proposalEta = 0;
        }
    }

    function controlEnd(uint256 action) public {
        action %= 4;
        if (action == 0) {
            vm.prank(GOVERNOR);
            if (ended) vm.expectRevert(SeasonVault.ProgramIsEnded.selector);
            vault.announceEnd();
            if (!ended) endEta = block.timestamp + 48 hours;
        } else if (action == 1) {
            vm.prank(GOVERNOR);
            if (ended || endEta == 0) vm.expectRevert(SeasonVault.NoEndAnnounced.selector);
            vault.withdrawEnd();
            if (!ended) endEta = 0;
        } else if (action == 2) {
            uint256 beforeBalance = token.balanceOf(TREASURY);
            if (ended) {
                vm.expectRevert(SeasonVault.ProgramIsEnded.selector);
            } else if (endEta == 0) {
                vm.expectRevert(SeasonVault.NoEndAnnounced.selector);
            } else if (block.timestamp < endEta) {
                vm.expectRevert(abi.encodeWithSelector(SeasonVault.TooEarly.selector, endEta));
            }
            vault.endProgram();
            if (endEta != 0 && block.timestamp >= endEta) ended = true;
            swept += token.balanceOf(TREASURY) - beforeBalance;
        } else {
            uint256 beforeBalance = token.balanceOf(TREASURY);
            if (!ended) vm.expectRevert(SeasonVault.NotEnded.selector);
            vault.sweep();
            swept += token.balanceOf(TREASURY) - beforeBalance;
        }
    }

    function donate(uint256 amount) public {
        amount = bound(amount, 0, token.balanceOf(address(this)));
        token.transfer(address(vault), amount);
        funded += amount;
    }

    function elapse(uint256 seconds_) public {
        vm.warp(block.timestamp + bound(seconds_, 0, 60 days));
    }

    function _root(uint256 s) internal view returns (bytes32) {
        return _pair(
            _pair(_leaf(s, actors[0], model[s].allocation[0]), _leaf(s, actors[1], model[s].allocation[1])),
            _pair(_leaf(s, actors[2], model[s].allocation[2]), _leaf(s, actors[3], model[s].allocation[3]))
        );
    }

    function _proof(uint256 s, uint256 i) internal view returns (bytes32[] memory proof) {
        proof = new bytes32[](2);
        uint256 otherPair = i < 2 ? 2 : 0;
        proof[0] = _leaf(s, actors[i ^ 1], model[s].allocation[i ^ 1]);
        proof[1] = _pair(
            _leaf(s, actors[otherPair], model[s].allocation[otherPair]),
            _leaf(s, actors[otherPair + 1], model[s].allocation[otherPair + 1])
        );
    }

    function assertAccounting() public view {
        uint256 expectedReserved;
        uint256 totalPaid;
        uint256[4] memory actorPaid;
        assertEq(vault.opened(), opened);
        assertEq(vault.ended(), ended);
        assertEq(vault.endEta(), endEta);
        for (uint256 s; s < opened; ++s) {
            Model storage m = model[s];
            SeasonVault.Season memory actual = vault.season(s);
            assertEq(actual.start, m.start);
            assertEq(actual.pot, m.pot);
            assertEq(actual.expired, m.expired);
            assertEq(actual.rootSetAt, m.rootAt);
            assertEq(actual.pendingEta, m.proposalEta);
            if (s != 0) assertGe(m.start, model[s - 1].start + 13 weeks);
            uint256 registered;
            uint256 paid;
            for (uint256 i; i < 4; ++i) {
                (uint256 entitlement, uint256 paidCounter) = vault.entitlements(s, actors[i]);
                assertEq(entitlement, m.registered[i] ? m.allocation[i] : 0);
                assertEq(paidCounter, m.received[i]);
                assertLe(m.received[i], entitlement);
                assertLe(vault.releasable(s, actors[i]), entitlement - paidCounter);
                registered += entitlement;
                paid += m.received[i];
                actorPaid[i] += m.received[i];
            }
            assertEq(actual.registered, registered);
            assertEq(actual.paid, paid);
            totalPaid += paid;
            if (m.rootAt == 0) {
                if (!m.expired) expectedReserved += m.pot;
            } else {
                assertEq(actual.root, _root(s));
                assertEq(actual.total, m.total);
                assertLe(registered, m.total);
                expectedReserved += (m.expired ? registered : m.total) - paid;
            }
        }
        for (uint256 i; i < 4; ++i) {
            assertEq(token.balanceOf(actors[i]), actorPaid[i]);
        }
        assertEq(vault.reserved(), expectedReserved, "reserved differs from unpaid entitlements and open pots");
        assertGe(token.balanceOf(address(vault)), expectedReserved);
        assertEq(vault.available() + expectedReserved, token.balanceOf(address(vault)));
        assertEq(token.balanceOf(address(vault)) + totalPaid + swept, funded);
        assertEq(token.balanceOf(TREASURY), swept);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function finish() external {
        uint256 at = block.timestamp;
        for (uint256 s; s < opened; ++s) {
            at = max(at, model[s].rootAt != 0 ? model[s].rootAt + 26 weeks : model[s].start + 39 weeks);
        }
        vm.warp(at);
        for (uint256 s; s < opened; ++s) {
            expire(s);
            for (uint256 i; i < 4; ++i) {
                release(s, i);
                if (model[s].registered[i]) assertEq(model[s].received[i], model[s].allocation[i]);
            }
        }
        if (!ended) {
            controlEnd(0);
            vm.warp(block.timestamp + 48 hours);
            controlEnd(2);
        }
        controlEnd(3);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(vault.reserved(), 0);
        assertAccounting();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract SeasonAccountingInvariantTest is InferFixtures {
    SeasonAccountingHandler internal handler;

    function setUp() public {
        handler = new SeasonAccountingHandler();
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.open.selector;
        selectors[1] = handler.propose.selector;
        selectors[2] = handler.withdrawProposal.selector;
        selectors[3] = handler.applyRoot.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.release.selector;
        selectors[6] = handler.expire.selector;
        selectors[7] = handler.controlEnd.selector;
        selectors[8] = handler.donate.selector;
        selectors[9] = handler.elapse.selector;
        // Caller roles are selected inside the handler; keep the outer sender local on forks.
        targetSender(address(this));
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_seasonReservesEqualAllOutstandingCommitments() public view {
        handler.assertAccounting();
    }

    function afterInvariant() public {
        handler.finish();
    }
}
