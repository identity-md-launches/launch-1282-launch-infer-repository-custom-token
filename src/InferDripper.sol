// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title InferDripper
/// @notice Holds the INFER the Treasury buys for stakers and releases it into sINFER in small steps, so the share
/// price only ever rises in increments too small to farm. sIMD's RewardDripper, without an owner.
///
/// Release per call = buffer × min(time since the last drip, MAX_CATCHUP) / DRAIN_PERIOD. With DRAIN_PERIOD 7 days
/// and MAX_CATCHUP 1 hour, the normal step releases at most 1/168 of the buffer however long nobody called: a gap is not
/// paid out in one lump (sIMD forfeits the idle time; here it simply stays in the buffer). Because the release is
/// a fraction of the buffer rather than a fixed rate, nobody has to tune it: a bigger buyback drains faster in
/// absolute terms and just as smoothly. The buffer decays with a ~7-day time constant (~63% out in a week).
///
/// Permissionless `drip()` pays its caller KEEPER_BPS of the release for gas, and refuses below `minDrip` (a
/// constructor word fixed at launch) so dust drips cannot farm the fee. After a full MAX_CATCHUP, a smaller step
/// is raised to min(balance, minDrip), including the final dust, so small buybacks cannot be stranded forever.
/// It refuses while sINFER has fewer than MIN_VAULT_SHARES real shares: with its 1e6 virtual shares,
/// this keeps the virtual share of each drip below 0.1% (apart from wei rounding), even in a dust-sized vault.
contract InferDripper {
    using SafeERC20 for IERC20;

    uint256 public constant DRAIN_PERIOD = 7 days;
    uint256 public constant MAX_CATCHUP = 1 hours;
    uint256 public constant KEEPER_BPS = 100; // 1% of each release
    uint256 public constant MIN_VAULT_SHARES = 1e9; // 1,000 times StakedInfer's 1e6 virtual shares

    IERC20 public immutable infer;
    address public immutable vault; // sINFER
    uint256 public immutable minDrip;
    uint256 public lastDripAt;

    event Dripped(uint256 toVault, uint256 toKeeper, address indexed keeper);

    error ZeroAddress();
    error WrongVault();
    error VaultEmpty();
    error BelowMinDrip(uint256 releasable, uint256 minDrip);

    constructor(address infer_, address vault_, uint256 minDrip_) {
        if (infer_ == address(0) || vault_ == address(0)) revert ZeroAddress();
        if (IERC4626Asset(vault_).asset() != infer_) revert WrongVault();
        infer = IERC20(infer_);
        vault = vault_;
        minDrip = minDrip_;
        lastDripAt = block.timestamp;
    }

    /// @notice What `drip()` would release now (vault share and keeper fee together).
    function releasable() public view returns (uint256) {
        uint256 elapsed = block.timestamp - lastDripAt;
        if (elapsed > MAX_CATCHUP) elapsed = MAX_CATCHUP;
        uint256 balance = infer.balanceOf(address(this));
        uint256 amount = balance * elapsed / DRAIN_PERIOD;
        if (elapsed == MAX_CATCHUP && amount < minDrip) {
            return balance < minDrip ? balance : minDrip;
        }
        return amount;
    }

    function canDrip() external view returns (bool) {
        return IERC20(vault).totalSupply() >= MIN_VAULT_SHARES && _ready(releasable());
    }

    function _ready(uint256 amount) private view returns (bool) {
        return amount != 0 && (amount >= minDrip || block.timestamp - lastDripAt >= MAX_CATCHUP);
    }

    /// @notice Release the next step into sINFER and pay the caller 1% of it. Anyone.
    function drip() external returns (uint256 toVault, uint256 toKeeper) {
        if (IERC20(vault).totalSupply() < MIN_VAULT_SHARES) revert VaultEmpty();
        uint256 amount = releasable();
        if (!_ready(amount)) revert BelowMinDrip(amount, minDrip);
        lastDripAt = block.timestamp;
        toKeeper = amount * KEEPER_BPS / 10_000;
        toVault = amount - toKeeper;
        infer.safeTransfer(vault, toVault);
        if (toKeeper != 0) infer.safeTransfer(msg.sender, toKeeper);
        emit Dripped(toVault, toKeeper, msg.sender);
    }
}

interface IERC4626Asset {
    function asset() external view returns (address);
}
