// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {InferToken} from "src/InferToken.sol";
import {LegacyRedeemer} from "src/LegacyRedeemer.sol";

/// @dev Exact launch terms. Local legacy tokens model burning; the existing fork suite checks MIYA/MXXN quirks.
abstract contract InferFixtures is Test {
    address internal constant TREASURY = 0x6Ac8fF96Fb8DCF5d79A8eF1E59D9AC23f2BD27Bc;
    address internal constant GOVERNOR = 0xbeFd108085613662356aa26A2466Ad3426DA9C32;
    address internal constant FOUNDER = 0x5167D014a056E43883e1BBEa5530c3c0dC993281;
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant ALLOCATION_A = 100_000_000e18;
    uint256 internal constant ALLOCATION_B = 40_000_000e18;
    uint256 internal constant RATE_A = 29_417_342_782_992_946_700;
    uint256 internal constant RATE_B = 7_851_289_668_371_509;

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function _redeemer(InferToken token, BurnableLegacy a, BurnableLegacy b) internal returns (LegacyRedeemer) {
        return new LegacyRedeemer(
            address(token), address(a), ALLOCATION_A, RATE_A, address(b), ALLOCATION_B, RATE_B, TREASURY, FOUNDER
        );
    }

    function _leaf(uint256 season, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(season, account, amount))));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }
}

contract BurnableLegacy is ERC20 {
    bool public rejectBurn;
    bool public rejectTransfer;
    error BurnRejected();
    error TransferRejected();

    constructor() ERC20("Local legacy fixture", "LEGACY") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function setRejectBurn(bool value) external {
        rejectBurn = value;
    }

    function setRejectTransfer(bool value) external {
        rejectTransfer = value;
    }

    function burn(uint256 amount) external {
        if (rejectBurn) revert BurnRejected();
        _burn(msg.sender, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (rejectTransfer) revert TransferRejected();
        return super.transferFrom(from, to, amount);
    }
}
