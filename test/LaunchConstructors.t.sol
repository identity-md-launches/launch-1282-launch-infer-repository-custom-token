// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {InferToken} from "src/InferToken.sol";
import {LegacyRedeemer} from "src/LegacyRedeemer.sol";
import {SeasonVault} from "src/SeasonVault.sol";
import {StakedInfer} from "src/StakedInfer.sol";
import {FounderStream} from "src/FounderStream.sol";
import {InferDripper} from "src/InferDripper.sol";

contract LaunchConstructorsTest is Test {
    address constant MIYA = 0xa358491CA72B793ddf21cF46C7289CC6e0ce9e5A;
    address constant MXXN = 0x2BBC21129E072A2A92A0Fd13DA750c1F977a25fB;
    address constant TREASURY = 0x6Ac8fF96Fb8DCF5d79A8eF1E59D9AC23f2BD27Bc;
    address constant GOVERNOR = 0xbeFd108085613662356aa26A2466Ad3426DA9C32;
    address constant FOUNDER = 0x5167D014a056E43883e1BBEa5530c3c0dC993281;

    function test_staticConstructorsCallOnlyTheEarlierVaultAsset() public {
        vm.startStateDiffRecording();
        InferToken token = new InferToken{salt: keccak256("token")}();
        LegacyRedeemer redeemer = new LegacyRedeemer{salt: keccak256("redeemer")}(
            address(token),
            MIYA,
            100_000_000e18,
            29417342782992946700,
            MXXN,
            40_000_000e18,
            7851289668371509,
            TREASURY,
            FOUNDER
        );
        SeasonVault seasons = new SeasonVault{salt: keccak256("seasons")}(address(token), GOVERNOR, TREASURY);
        StakedInfer vault = new StakedInfer{salt: keccak256("vault")}(token);
        FounderStream founder = new FounderStream{salt: keccak256("founder")}(address(token), FOUNDER);
        InferDripper dripper = new InferDripper{salt: keccak256("dripper")}(address(token), address(vault), 1_000e18);
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        uint256 reads;
        for (uint256 i; i < accesses.length; ++i) {
            VmSafe.AccountAccess memory a = accesses[i];
            assertTrue(a.kind != VmSafe.AccountAccessKind.Call, "constructor made an external call");
            assertTrue(a.kind != VmSafe.AccountAccessKind.DelegateCall && a.kind != VmSafe.AccountAccessKind.CallCode);
            assertTrue(a.kind != VmSafe.AccountAccessKind.SelfDestruct);
            if (a.kind == VmSafe.AccountAccessKind.StaticCall) {
                assertEq(a.accessor, address(dripper));
                assertEq(a.account, address(vault));
                assertEq(a.data, abi.encodeWithSignature("asset()"));
                ++reads;
            }
        }
        assertEq(reads, 1);
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
        assertEq(redeemer.genesisAllocation(), 140_000_000e18);
        assertEq(redeemer.rateA(), 29417342782992946700);
        assertEq(redeemer.rateB(), 7851289668371509);
        assertEq(seasons.genesisAllocation(), 310_000_000e18);
        assertEq(seasons.governor(), GOVERNOR);
        assertEq(founder.genesisAllocation(), 70_000_000e18);
        assertEq(founder.beneficiary(), FOUNDER);
        assertEq(vault.asset(), address(token));
        assertEq(vault.decimals(), 24);
        assertEq(dripper.minDrip(), 1_000e18);
    }

    function test_stakingConstructorDoesNotReadTokenMetadata() public {
        InferToken token = new InferToken();
        vm.expectCall(address(token), abi.encodeWithSignature("decimals()"), uint64(0));
        StakedInfer vault = new StakedInfer(token);
        assertEq(vault.asset(), address(token));
        assertEq(vault.decimals(), 24);
    }
}
