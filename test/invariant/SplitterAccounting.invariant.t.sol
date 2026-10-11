// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {InferFixtures} from "../helpers/InferFixtures.sol";
import {InferToken} from "src/InferToken.sol";
import {LegacyRedeemer} from "src/LegacyRedeemer.sol";
import {SeasonVault} from "src/SeasonVault.sol";
import {FounderStream} from "src/FounderStream.sol";
import {StakedInfer} from "src/StakedInfer.sol";
import {InferDripper} from "src/InferDripper.sol";
import {GenesisSplitter, ILaunchRegistry} from "genesis-splitter/GenesisSplitter.sol";

/// @dev Only the external registry is a fixture. Allocation getters belong to the actual launch contracts.
contract SplitterRegistryFixture is ILaunchRegistry {
    mapping(uint64 => Artifact[]) internal records;

    function record(uint64 launch, address token, address[5] memory applications) external {
        records[launch].push(Artifact("token", "InferToken", token));
        bytes32[5] memory names =
            [bytes32("LegacyRedeemer"), "SeasonVault", "StakedInfer", "FounderStream", "InferDripper"];
        for (uint256 i; i < 5; ++i) {
            records[launch].push(Artifact("other", names[i], applications[i]));
        }
    }

    function launchOf(uint64 launch) external pure returns (Launch memory result) {
        result.kind = "custom_token";
        result.launchNumber = launch;
    }

    function artifactsOf(uint64 launch) external view returns (Artifact[] memory) {
        return records[launch];
    }
}

contract SplitterAccountingHandler is InferFixtures {
    GenesisSplitter public splitter;
    InferToken[2] public tokens;
    address[5][2] public applications;
    uint256[2] public funded;
    uint256[2] public treasuryPaid;
    bool[2] public splitDone;
    address[3] public callers;

    constructor() {
        SplitterRegistryFixture registry = new SplitterRegistryFixture();
        splitter = new GenesisSplitter(address(registry), TREASURY);
        for (uint256 i; i < 3; ++i) {
            callers[i] = makeAddr(string.concat("splitter keeper ", vm.toString(i)));
        }
        for (uint64 i; i < 2; ++i) {
            InferToken token = new InferToken();
            tokens[i] = token;
            applications[i][0] = address(
                new LegacyRedeemer(
                    address(token),
                    0xa358491CA72B793ddf21cF46C7289CC6e0ce9e5A,
                    ALLOCATION_A,
                    RATE_A,
                    0x2BBC21129E072A2A92A0Fd13DA750c1F977a25fB,
                    ALLOCATION_B,
                    RATE_B,
                    TREASURY,
                    FOUNDER
                )
            );
            applications[i][1] = address(new SeasonVault(address(token), GOVERNOR, TREASURY));
            applications[i][2] = address(new StakedInfer(token));
            applications[i][3] = address(new FounderStream(address(token), FOUNDER));
            applications[i][4] = address(new InferDripper(address(token), applications[i][2], 1_000e18));
            registry.record(i + 1, address(token), applications[i]);
            donate(i, i == 0 ? 700_000_000e18 : 100_000_000e18);
        }
    }

    function donate(uint256 tokenSeed, uint256 amount) public {
        uint256 i = tokenSeed % 2;
        amount = bound(amount, 0, tokens[i].balanceOf(address(this)));
        tokens[i].transfer(address(splitter), amount);
        funded[i] += amount;
    }

    function split(uint256 tokenSeed, uint256 callerSeed) public {
        uint256 i = tokenSeed % 2;
        InferToken token = tokens[i];
        uint256 held = token.balanceOf(address(splitter));
        vm.prank(callers[callerSeed % 3]);
        if (splitDone[i]) {
            vm.expectRevert(abi.encodeWithSelector(GenesisSplitter.AlreadySplit.selector, address(token)));
            splitter.split(uint64(i + 1));
        } else if (held < 520_000_000e18) {
            uint256 allocated =
                held < 140_000_000e18 ? 140_000_000e18 : held < 450_000_000e18 ? 450_000_000e18 : 520_000_000e18;
            vm.expectRevert(abi.encodeWithSelector(GenesisSplitter.OverAllocated.selector, allocated, held));
            splitter.split(uint64(i + 1));
        } else {
            splitter.split(uint64(i + 1));
            splitDone[i] = true;
            treasuryPaid[i] += held - 520_000_000e18;
        }
    }

    function sweep(uint256 tokenSeed, uint256 callerSeed) public {
        uint256 i = tokenSeed % 2;
        uint256 held = tokens[i].balanceOf(address(splitter));
        vm.prank(callers[callerSeed % 3]);
        if (!splitDone[i]) {
            vm.expectRevert(abi.encodeWithSelector(GenesisSplitter.NotSplit.selector, address(tokens[i])));
        }
        splitter.sweep(address(tokens[i]));
        if (splitDone[i]) treasuryPaid[i] += held;
    }

    function assertAccounting() public view {
        for (uint256 i; i < 2; ++i) {
            InferToken token = tokens[i];
            assertEq(splitter.isSplit(address(token)), splitDone[i]);
            assertEq(token.balanceOf(applications[i][0]), splitDone[i] ? 140_000_000e18 : 0);
            assertEq(token.balanceOf(applications[i][1]), splitDone[i] ? 310_000_000e18 : 0);
            assertEq(token.balanceOf(applications[i][3]), splitDone[i] ? 70_000_000e18 : 0);
            assertEq(token.balanceOf(applications[i][2]), 0);
            assertEq(token.balanceOf(applications[i][4]), 0);
            for (uint256 j; j < 5; ++j) {
                assertEq(token.balanceOf(applications[1 - i][j]), 0, "cross-launch leakage");
            }
            assertEq(token.balanceOf(TREASURY), treasuryPaid[i]);
            assertEq(
                token.balanceOf(address(splitter)) + treasuryPaid[i] + (splitDone[i] ? 520_000_000e18 : 0), funded[i]
            );
            assertEq(token.balanceOf(address(this)) + funded[i], SUPPLY);
            assertEq(token.totalSupply(), SUPPLY);
        }
    }

    function finish() external {
        for (uint256 i; i < 2; ++i) {
            if (!splitDone[i]) {
                uint256 held = tokens[i].balanceOf(address(splitter));
                if (held < 520_000_000e18) donate(i, 520_000_000e18 - held);
                split(i, i);
            }
            sweep(i, i);
            assertEq(tokens[i].balanceOf(address(splitter)), 0);
        }
        assertAccounting();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SplitterAccountingInvariantTest is InferFixtures {
    SplitterAccountingHandler internal handler;

    function setUp() public {
        handler = new SplitterAccountingHandler();
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.donate.selector;
        selectors[1] = handler.split.selector;
        selectors[2] = handler.sweep.selector;
        // Caller roles are selected inside the handler; keep the outer sender local on forks.
        targetSender(address(this));
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_splitPaysEachLaunchExactlyOnceWithoutCrossingTokens() public view {
        handler.assertAccounting();
    }

    function afterInvariant() public {
        handler.finish();
    }
}
