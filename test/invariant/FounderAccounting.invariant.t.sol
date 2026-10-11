// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {InferFixtures} from "../helpers/InferFixtures.sol";
import {InferToken} from "src/InferToken.sol";
import {FounderStream} from "src/FounderStream.sol";

contract FounderAccountingHandler is InferFixtures {
    InferToken public token;
    FounderStream public stream;
    uint256 public funded;
    uint256 public paid;
    uint256 public lastVested;
    address[3] public callers;

    constructor() {
        token = new InferToken();
        stream = new FounderStream(address(token), FOUNDER);
        for (uint256 i; i < 3; ++i) {
            callers[i] = makeAddr(string.concat("founder keeper ", vm.toString(i)));
        }
        fund(70_000_000e18);
    }

    function fund(uint256 amount) public {
        amount = bound(amount, 0, token.balanceOf(address(this)));
        token.transfer(address(stream), amount);
        funded += amount;
    }

    function elapse(uint256 seconds_) public {
        vm.warp(block.timestamp + bound(seconds_, 0, 40 days));
        assertGe(stream.vested(), lastVested);
        lastVested = stream.vested();
    }

    function release(uint256 callerSeed) public {
        address caller = callers[callerSeed % 3];
        uint256 amount = stream.releasable();
        uint256 beforeBalance = token.balanceOf(FOUNDER);
        vm.prank(caller);
        if (amount == 0) vm.expectRevert(FounderStream.NothingToRelease.selector);
        uint256 result = stream.release();
        if (amount != 0) {
            assertEq(result, amount);
            assertEq(token.balanceOf(FOUNDER), beforeBalance + result);
            paid += result;
        }
        assertEq(token.balanceOf(caller), 0, "permissionless callers cannot redirect founder payments");
        assertEq(stream.releasable(), 0);
    }

    function assertAccounting() public view {
        uint256 age = block.timestamp - stream.start();
        assertEq(stream.released(), paid);
        assertEq(token.balanceOf(FOUNDER), paid);
        assertEq(token.balanceOf(address(stream)) + paid, funded);
        assertEq(token.balanceOf(address(this)) + funded, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertLe(stream.vested(), 70_000_000e18);
        if (age < 30 days) {
            assertEq(paid, 0);
            assertEq(stream.releasable(), 0);
        } else if (age < 365 days) {
            assertLe(paid, stream.vested());
            assertLe(paid + stream.releasable(), 70_000_000e18);
        } else {
            assertEq(stream.vested(), 70_000_000e18);
            assertEq(stream.releasable(), token.balanceOf(address(stream)));
        }
    }

    function finish() external {
        vm.warp(max(block.timestamp, uint256(stream.start()) + 365 days));
        release(0);
        assertEq(token.balanceOf(address(stream)), 0);
        assertEq(paid, funded);
        assertAccounting();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract FounderAccountingInvariantTest is InferFixtures {
    FounderAccountingHandler internal handler;

    function setUp() public {
        handler = new FounderAccountingHandler();
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.elapse.selector;
        selectors[2] = handler.release.selector;
        // Caller roles are selected inside the handler; keep the outer sender local on forks.
        targetSender(address(this));
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_founderCanOnlyReceiveFundedAndVestedInfer() public view {
        handler.assertAccounting();
    }

    function afterInvariant() public {
        handler.finish();
    }
}
