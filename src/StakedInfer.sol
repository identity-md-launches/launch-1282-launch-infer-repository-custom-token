// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626StaticAsset} from "./base/ERC4626StaticAsset.sol";

/// @title StakedInfer (sINFER)
/// @notice Stake INFER, receive sINFER shares. Rewards are INFER that the Treasury buys with protocol revenue and
/// feeds in through `InferDripper`: each arrival raises `totalAssets`, so every share redeems for more INFER. No
/// INFER is ever emitted for staking, no claim step, one asset, the same model as sIMD.
///
/// - Inflation attack: OpenZeppelin's virtual shares with a 6-decimal offset (shares have 24 decimals, as sIMD's).
/// - One-block hold on newly minted shares: transfers spend unlocked shares first, then carry any held shares
///   to the receiver with their hold intact. A flash-loaned deposit cannot redeem in the same block around a
///   drip, even through another receiver. Receiving dust never holds a recipient's older shares.
/// - No owner, no pause, no rescue: sIMD reached that state by renouncing; this starts there.
contract StakedInfer is ERC4626StaticAsset {
    /// @notice Block in which each holder most recently received shares subject to the one-block hold.
    mapping(address account => uint256) public lastDepositBlock;
    mapping(address account => uint256) private _lockedShares;

    error SameBlockRedeem();

    constructor(IERC20 infer) ERC20("Staked INFER", "sINFER") ERC4626StaticAsset(infer, 18) {}

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (shares > maxRedeem(owner)) revert SameBlockRedeem();
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _update(address from, address to, uint256 value) internal override {
        uint256 held;
        if (value != 0 && from != to) {
            if (from == address(0)) {
                held = value;
            } else {
                uint256 unlocked = balanceOf(from) - lockedShares(from);
                held = value > unlocked ? value - unlocked : 0;
            }
        }
        super._update(from, to, value);
        if (held != 0) {
            if (from != address(0)) _lockedShares[from] -= held;
            if (to != address(0)) {
                _lockedShares[to] = lockedShares(to) + held;
                lastDepositBlock[to] = block.number;
            }
        }
    }

    /// @notice Shares still held this block; older deposits are always available to redeem.
    function lockedShares(address owner) public view returns (uint256) {
        return block.number == lastDepositBlock[owner] ? _lockedShares[owner] : 0;
    }

    /// @dev The inherited maxWithdraw converts this unlocked share count to assets, rounding down.
    function maxRedeem(address owner) public view override returns (uint256) {
        return balanceOf(owner) - lockedShares(owner);
    }
}
