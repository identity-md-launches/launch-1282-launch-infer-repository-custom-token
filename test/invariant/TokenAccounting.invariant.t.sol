// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {InferFixtures} from "../helpers/InferFixtures.sol";
import {InferToken} from "src/InferToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract TokenAccountingHandler is InferFixtures {
    InferToken public token;
    address[4] public actors;
    uint256[4] public balances;
    uint256[4][4] public allowances;

    constructor() {
        token = new InferToken();
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("token actor ", vm.toString(i)));
            balances[i] = SUPPLY / 4;
            token.transfer(actors[i], balances[i]);
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        uint256 from = fromSeed % 4;
        uint256 to = toSeed % 4;
        amount = bound(amount, 0, balances[from]);
        vm.prank(actors[from]);
        assertTrue(token.transfer(actors[to], amount));
        balances[from] -= amount;
        balances[to] += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) public {
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        amount = infinite ? type(uint256).max : bound(amount, 0, SUPPLY);
        vm.prank(actors[owner]);
        assertTrue(token.approve(actors[spender], amount));
        allowances[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) public {
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        uint256 to = toSeed % 4;
        uint256 allowed = allowances[owner][spender];
        amount = bound(amount, 0, min(allowed, balances[owner]));
        vm.prank(actors[spender]);
        assertTrue(token.transferFrom(actors[owner], actors[to], amount));
        balances[owner] -= amount;
        balances[to] += amount;
        if (allowed != type(uint256).max) allowances[owner][spender] -= amount;
    }

    function failTransfer(uint256 actorSeed, bool zeroRecipient) public {
        uint256 i = actorSeed % 4;
        vm.prank(actors[i]);
        if (zeroRecipient) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            token.transfer(address(0), 0);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientBalance.selector, actors[i], balances[i], balances[i] + 1
                )
            );
            token.transfer(actors[(i + 1) % 4], balances[i] + 1);
        }
    }

    function failAllowance(uint256 ownerSeed, uint256 spenderSeed) public {
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        uint256 allowed = allowances[owner][spender];
        if (allowed == type(uint256).max) return;
        vm.prank(actors[spender]);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, actors[spender], allowed, allowed + 1
            )
        );
        token.transferFrom(actors[owner], actors[spender], allowed + 1);
    }

    function assertAccounting() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            assertEq(token.balanceOf(actors[i]), balances[i]);
            sum += token.balanceOf(actors[i]);
            for (uint256 j; j < 4; ++j) {
                assertEq(token.allowance(actors[i], actors[j]), allowances[i][j]);
            }
        }
        assertEq(sum, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract TokenAccountingInvariantTest is InferFixtures {
    TokenAccountingHandler internal handler;

    function setUp() public {
        handler = new TokenAccountingHandler();
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.failTransfer.selector;
        selectors[4] = handler.failAllowance.selector;
        // Caller roles are selected inside the handler; keep the outer sender local on forks.
        targetSender(address(this));
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_fixedSupplyExactTransfersAndAllowanceLedger() public view {
        handler.assertAccounting();
    }
}
