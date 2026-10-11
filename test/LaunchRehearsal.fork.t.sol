// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {GenesisSplitter, ILaunchRegistry} from "genesis-splitter/GenesisSplitter.sol";
import {LegacyRedeemer} from "src/LegacyRedeemer.sol";
import {SeasonVault} from "src/SeasonVault.sol";
import {StakedInfer} from "src/StakedInfer.sol";
import {FounderStream} from "src/FounderStream.sol";
import {InferDripper} from "src/InferDripper.sol";

import {InferToken} from "src/InferToken.sol";

/// @dev The live factory's `launchCustom` and its parameter struct (Identity-md/protocol ProjectFactory.sol).
interface IProjectFactory {
    struct CustomParams {
        uint64 launchNumber;
        bytes tokenCreationCode;
        bytes32 tokenName;
        bytes[] contractCreationCodes;
        bytes32[] contractNames;
        address[] expectedContracts;
        uint256 totalSupply;
        uint16 poolBps;
        address remainderTo;
        bytes32 merkleRoot;
        uint64 contributorLockSeconds;
        uint64 sweepDelaySeconds;
        Currency pairedCurrency;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        ILaunchRegistry.Launch record;
        uint256[] agentIds;
        address requester;
    }

    function deployer() external view returns (address);
    function registry() external view returns (address);
    function launchCustom(CustomParams calldata p) external returns (address, address[] memory, address);
    function predictToken(uint64 launchNumber, bytes calldata code) external view returns (address);
    function predictContract(uint64 launchNumber, uint256 index, bytes calldata code) external view returns (address);
}

/// @notice The INFER launch, rehearsed through the REAL mainnet ProjectFactory (impersonating its deployer, the
/// plane's key), then split by the GenesisSplitter reading the REAL registry. Measures the one transaction's gas
/// against the EIP-7825 cap.
///   forge test --match-contract LaunchRehearsal --fork-url $MAINNET_RPC_URL -vv
contract LaunchRehearsalForkTest is Test {
    IProjectFactory constant FACTORY = IProjectFactory(0xfF03410d0Fe5fa8f7F59F743de35E333D9857120);
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant MIYA = 0xa358491CA72B793ddf21cF46C7289CC6e0ce9e5A;
    address constant MXXN = 0x2BBC21129E072A2A92A0Fd13DA750c1F977a25fB;
    address constant FOUNDER = 0x5167D014a056E43883e1BBEa5530c3c0dC993281;
    address constant TREASURY = 0x6Ac8fF96Fb8DCF5d79A8eF1E59D9AC23f2BD27Bc;
    address constant GOVERNOR = 0xbeFd108085613662356aa26A2466Ad3426DA9C32;
    GenesisSplitter constant SPLITTER = GenesisSplitter(0xE95311cccF156cB18194D523Cbe44cea33AD026E);
    uint64 constant LAUNCH = 4_000_000_002;
    uint256 constant TX_GAS_CAP = 16_777_216;
    uint16 constant POOL_BPS = 2_000;
    int24 constant SPACING = 60;
    uint256 constant OPEN_FDV_IMD = 14_444_444444444444444444; // 14,444.44 IMD for the whole supply

    function setUp() public {
        if (block.chainid != 1 || address(FACTORY).code.length == 0) vm.skip(true);
    }

    function test_launchFitsOneTransactionAndSplits() public {
        emit log_named_uint("mainnet fork block", block.number);
        assertGt(address(SPLITTER).code.length, 0, "the launch's splitter must already exist");
        assertEq(address(SPLITTER.registry()), FACTORY.registry());
        assertEq(SPLITTER.treasury(), TREASURY);

        bytes memory tokenCode = type(InferToken).creationCode;
        address token = FACTORY.predictToken(LAUNCH, tokenCode);

        bytes[] memory codes = new bytes[](5);
        codes[0] = abi.encodePacked(
            type(LegacyRedeemer).creationCode,
            abi.encode(
                token,
                MIYA,
                100_000_000e18,
                29417342782992946700,
                MXXN,
                40_000_000e18,
                7851289668371509,
                TREASURY,
                FOUNDER
            )
        );
        codes[1] = abi.encodePacked(type(SeasonVault).creationCode, abi.encode(token, GOVERNOR, TREASURY));
        codes[2] = abi.encodePacked(type(StakedInfer).creationCode, abi.encode(token));
        codes[3] = abi.encodePacked(type(FounderStream).creationCode, abi.encode(token, FOUNDER));
        // $contract:StakedInfer — an earlier contract of the same launch, as the manifest allows.
        address sinfer = FACTORY.predictContract(LAUNCH, 2, codes[2]);
        codes[4] = abi.encodePacked(type(InferDripper).creationCode, abi.encode(token, sinfer, 1_000e18));
        bytes32[] memory names = new bytes32[](5);
        (names[0], names[1], names[2], names[3], names[4]) =
        ("LegacyRedeemer", "SeasonVault", "StakedInfer", "FounderStream", "InferDripper");
        address[] memory expected = new address[](5);
        for (uint256 i; i < 5; ++i) {
            expected[i] = FACTORY.predictContract(LAUNCH, i, codes[i]);
        }

        IProjectFactory.CustomParams memory p;
        p.launchNumber = LAUNCH;
        p.tokenCreationCode = tokenCode;
        p.tokenName = "InferToken";
        p.contractCreationCodes = codes;
        p.contractNames = names;
        p.expectedContracts = expected;
        p.totalSupply = 1_000_000_000e18;
        p.poolBps = POOL_BPS;
        p.remainderTo = address(SPLITTER);
        p.merkleRoot = keccak256("swarm round");
        p.contributorLockSeconds = 1 hours;
        p.sweepDelaySeconds = 365 days;
        p.pairedCurrency = Currency.wrap(IMD);
        p.tickSpacing = SPACING;
        (p.sqrtPriceX96, p.tickLower, p.tickUpper, p.liquidity) = _seed(token);
        p.record.sourceRepoUrl = "https://github.com/example/infer";
        p.requester = FOUNDER;

        vm.prank(FACTORY.deployer());
        uint256 g = gasleft();
        (address t, address[] memory contracts,) = FACTORY.launchCustom(p);
        uint256 used = g - gasleft();
        emit log_named_uint("launchCustom gas", used);
        emit log_named_uint("headroom to the 16,777,216 cap", TX_GAS_CAP - used);
        assertEq(t, token);
        assertLt(used, TX_GAS_CAP, "the launch must fit one transaction");

        uint256 inSplitter = IERC20(token).balanceOf(address(SPLITTER));
        emit log_named_uint("remainder at the splitter (INFER)", inSplitter / 1e18);
        SPLITTER.split(LAUNCH);
        assertEq(IERC20(token).balanceOf(contracts[0]), 140_000_000e18, "LegacyRedeemer");
        assertEq(IERC20(token).balanceOf(contracts[1]), 310_000_000e18, "SeasonVault");
        assertEq(IERC20(token).balanceOf(contracts[2]), 0, "StakedInfer declares nothing");
        assertEq(IERC20(token).balanceOf(contracts[3]), 70_000_000e18, "FounderStream");
        assertEq(IERC20(token).balanceOf(contracts[4]), 0, "InferDripper declares nothing");
        assertEq(InferDripper(contracts[4]).vault(), contracts[2], "the dripper feeds this launch's sINFER");
        emit log_named_uint("Treasury (INFER)", IERC20(token).balanceOf(TREASURY) / 1e18);
        assertApproxEqAbs(
            IERC20(token).balanceOf(TREASURY),
            180_000_000e18,
            2e18,
            "the rest, plus the 1 INFER the seed leaves and its rounding"
        );
    }

    /// @dev Single-sided INFER above the opening price: the pool holds only INFER until someone buys.
    function _seed(address token) private pure returns (uint160 sqrtP, int24 lo, int24 hi, uint128 liq) {
        bool inferIs0 = token < IMD;
        // Raw price = token1 per token0, both 18 decimals. Opening INFER price = FDV / supply in IMD.
        // sqrtPriceX96 = sqrt(price) * 2^96.
        uint256 priceX192 = inferIs0
            ? FullMath.mulDiv(OPEN_FDV_IMD, 1 << 192, 1_000_000_000e18)
            : FullMath.mulDiv(1_000_000_000e18, 1 << 192, OPEN_FDV_IMD);
        sqrtP = uint160(_sqrt(priceX192));
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 maxT = TickMath.MAX_TICK / SPACING * SPACING;
        uint256 amount = 200_000_000e18 - 1e18; // under the pool's allowance, rounding included
        if (inferIs0) {
            // token0 only: the range sits wholly above the price.
            lo = (tick / SPACING + 1) * SPACING;
            hi = maxT;
            uint256 a = TickMath.getSqrtPriceAtTick(lo);
            uint256 b = TickMath.getSqrtPriceAtTick(hi);
            liq = uint128(FullMath.mulDiv(amount, FullMath.mulDiv(a, b, 1 << 96), b - a));
        } else {
            // token1 only: the range sits wholly below the price.
            hi = (tick / SPACING) * SPACING;
            if (hi > tick) hi -= SPACING;
            lo = -maxT;
            uint256 a = TickMath.getSqrtPriceAtTick(lo);
            uint256 b = TickMath.getSqrtPriceAtTick(hi);
            liq = uint128(FullMath.mulDiv(amount, 1 << 96, b - a));
        }
    }

    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x >> 1) + 1;
        while (z < y) (y, z) = (z, (x / z + z) >> 1);
    }
}

contract InferTokenTest is Test {
    function test_nameSymbolSupply() public {
        InferToken t = new InferToken();
        assertEq(t.name(), "Inference Backed Endogenous Financial Reserve");
        assertEq(t.symbol(), "INFER");
        assertEq(t.decimals(), 18);
        assertEq(t.totalSupply(), 1_000_000_000e18);
        assertEq(t.balanceOf(address(this)), 1_000_000_000e18);
    }
}
