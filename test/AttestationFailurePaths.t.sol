// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {InferFixtures} from "./helpers/InferFixtures.sol";
import {InferToken} from "src/InferToken.sol";
import {SeasonVault} from "src/SeasonVault.sol";
import {SeasonAttestation} from "src/SeasonAttestation.sol";

/// @dev Signing fixture only: production signer is separately checked below and is never changed.
contract SignedSeasonFixture is SeasonVault {
    address internal immutable signer;

    constructor(address token, address governor, address treasury, address signer_)
        SeasonVault(token, governor, treasury)
    {
        signer = signer_;
    }

    function _attester() internal view override returns (address) {
        return signer;
    }
}

contract AttestationFailurePathsTest is InferFixtures {
    uint256 internal constant SIGNING_KEY = 0xA771570123;
    uint256 internal constant POT = 100e18;
    string internal constant CID = "bafyLeavesForAttestationTest";
    string internal constant RULES = "bafyRulesForAttestationTest";
    InferToken internal token;
    SeasonVault internal vault;
    bytes32 internal root;

    function setUp() public {
        vm.chainId(1);
        vm.roll(max(block.number, 500));
        token = new InferToken();
        vault = new SignedSeasonFixture(address(token), GOVERNOR, TREASURY, vm.addr(SIGNING_KEY));
        token.transfer(address(vault), 310_000_000e18);
        root = _leaf(0, makeAddr("attested recipient"), POT);
        vm.prank(GOVERNOR);
        vault.openSeason(uint64(block.timestamp + 48 hours), POT, keccak256(bytes(RULES)));
        vm.warp(vault.endOf(0));
    }

    function _attestation(SeasonVault target, uint256 total)
        internal
        view
        returns (SeasonAttestation.OracleAttestation memory a)
    {
        a.requestId = keccak256("local attestation fixture request");
        a.chainId = 1;
        a.answerType = 0;
        a.answer = abi.encode(true);
        a.figure = 1;
        a.fromBlock = 100;
        a.toBlock = 200;
        a.blockHash = keccak256("fixture block");
        a.panelJobId = keccak256("fixture panel");
        a.panelSize = 25;
        a.quorum = 15;
        a.agreed = 15;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 hours);
        a.questionHash = keccak256(target.seasonQuestion(0, root, total, CID, RULES, a.fromBlock, a.toBlock));
    }

    function _signature(SeasonAttestation.OracleAttestation memory a, bytes32 domain)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(
                    vault.ATTESTATION_TYPEHASH(),
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock
                ),
                abi.encode(
                    a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(SIGNING_KEY, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _submit(SeasonAttestation.OracleAttestation memory a, bytes memory sig) internal {
        vault.submitAttestedRoot(0, root, POT, CID, RULES, a, sig);
    }

    function _unchanged(bytes32 requestId) internal view {
        assertFalse(vault.usedRequests(requestId));
        assertEq(vault.season(0).rootSetAt, 0);
        assertEq(vault.reserved(), POT);
        assertEq(token.balanceOf(address(vault)), 310_000_000e18);
    }

    function test_productionContractRejectsTheFixtureSigner() public {
        SeasonVault production = new SeasonVault(address(token), GOVERNOR, TREASURY);
        token.transfer(address(production), POT);
        vm.prank(GOVERNOR);
        production.openSeason(uint64(block.timestamp + 48 hours), POT, keccak256(bytes(RULES)));
        vm.warp(production.endOf(0));
        SeasonAttestation.OracleAttestation memory a = _attestation(production, POT);
        bytes memory sig = _signature(a, production.DOMAIN_SEPARATOR());
        vm.expectRevert(SeasonAttestation.InvalidSignature.selector);
        production.submitAttestedRoot(0, root, POT, CID, RULES, a, sig);
        assertFalse(production.usedRequests(a.requestId));
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_signedInvalidAttestationFieldsAreRefused(uint8 branch) public {
        branch = uint8(bound(branch, 0, 10));
        SeasonAttestation.OracleAttestation memory a = _attestation(vault, POT);
        bytes4 expected;
        if (branch == 0) {
            a.chainId = 2;
            expected = SeasonAttestation.WrongChain.selector;
        } else if (branch == 1) {
            a.answerType = 1;
            expected = SeasonAttestation.NotYes.selector;
        } else if (branch == 2) {
            a.answer = abi.encode(false);
            expected = SeasonAttestation.NotYes.selector;
        } else if (branch == 3) {
            a.answer = hex"01";
            expected = SeasonAttestation.NotYes.selector;
        } else if (branch == 4) {
            a.panelSize = 24;
            expected = SeasonAttestation.PanelTooSmall.selector;
        } else if (branch == 5) {
            a.agreed = 14;
            expected = SeasonAttestation.NotEnoughAgreement.selector;
        } else if (branch == 6) {
            a.agreed = 26;
            expected = SeasonAttestation.NotEnoughAgreement.selector;
        } else if (branch == 7) {
            a.issuedAt = uint64(block.timestamp + 1);
            expected = SeasonAttestation.InvalidTimestamp.selector;
        } else if (branch == 8) {
            a.expiresAt = uint64(block.timestamp - 1);
            expected = SeasonAttestation.Expired.selector;
        } else if (branch == 9) {
            a.fromBlock = 201;
            expected = SeasonAttestation.BadWindow.selector;
        } else {
            a.toBlock = uint64(block.number + 1);
            expected = SeasonAttestation.BadWindow.selector;
        }
        a.questionHash = keccak256(vault.seasonQuestion(0, root, POT, CID, RULES, a.fromBlock, a.toBlock));
        bytes memory sig = _signature(a, vault.DOMAIN_SEPARATOR());
        vm.expectRevert(expected);
        _submit(a, sig);
        _unchanged(a.requestId);
    }

    function test_expiryAndPanelThresholdAreInclusiveAndRequestIsSingleUse() public {
        SeasonAttestation.OracleAttestation memory a = _attestation(vault, POT);
        a.expiresAt = uint64(block.timestamp);
        bytes memory sig = _signature(a, vault.DOMAIN_SEPARATOR());
        vm.prank(makeAddr("permissionless root submitter"));
        vault.submitAttestedRoot(0, root, POT, CID, RULES, a, sig);
        assertTrue(vault.usedRequests(a.requestId));
        assertEq(vault.season(0).root, root);
        vm.expectRevert(SeasonAttestation.Replayed.selector);
        _submit(a, sig);
    }

    function test_signatureCannotCrossConsumersOrChains() public {
        SeasonAttestation.OracleAttestation memory a = _attestation(vault, POT);
        SeasonVault other = new SignedSeasonFixture(address(token), GOVERNOR, TREASURY, vm.addr(SIGNING_KEY));
        bytes memory wrongConsumer = _signature(a, other.DOMAIN_SEPARATOR());
        vm.expectRevert(SeasonAttestation.InvalidSignature.selector);
        _submit(a, wrongConsumer);
        bytes32 wrongChainDomain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("IdentityMD Oracle"),
                keccak256("2"),
                uint256(2),
                address(vault)
            )
        );
        bytes memory wrongChain = _signature(a, wrongChainDomain);
        vm.expectRevert(SeasonAttestation.InvalidSignature.selector);
        _submit(a, wrongChain);
        _unchanged(a.requestId);
        _submit(a, _signature(a, vault.DOMAIN_SEPARATOR()));
    }

    function test_signatureRejectsHighSInvalidVAndZeroRecovery() public {
        SeasonAttestation.OracleAttestation memory a = _attestation(vault, POT);
        bytes memory sig = _signature(a, vault.DOMAIN_SEPARATOR());
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        uint256 order = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        bytes memory highS = abi.encodePacked(r, bytes32(order - uint256(s)), uint8(v == 27 ? 28 : 27));
        vm.expectRevert(SeasonAttestation.InvalidSignature.selector);
        _submit(a, highS);
        vm.expectRevert(SeasonAttestation.InvalidSignature.selector);
        _submit(a, abi.encodePacked(r, s, uint8(0)));
        vm.expectRevert(SeasonAttestation.InvalidSignature.selector);
        _submit(a, abi.encodePacked(bytes32(0), bytes32(0), uint8(27)));
        _unchanged(a.requestId);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_invalidSignatureLengths(uint256 length) public {
        length = bound(length, 0, 130);
        if (length == 65) length = 66;
        SeasonAttestation.OracleAttestation memory a = _attestation(vault, POT);
        vm.expectRevert(SeasonAttestation.InvalidSignature.selector);
        _submit(a, new bytes(length));
        _unchanged(a.requestId);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_signatureBindsFieldsEvenWhenAllValidityGuardsStillPass(uint8 field) public {
        field = uint8(bound(field, 0, 8));
        SeasonAttestation.OracleAttestation memory a = _attestation(vault, POT);
        bytes memory sig = _signature(a, vault.DOMAIN_SEPARATOR());
        if (field == 0) a.requestId = keccak256("tampered request");
        else if (field == 1) a.figure++;
        else if (field == 2) a.blockHash = keccak256("tampered block");
        else if (field == 3) a.panelJobId = keccak256("tampered panel");
        else if (field == 4) a.panelSize++;
        else if (field == 5) a.quorum++;
        else if (field == 6) a.agreed++;
        else if (field == 7) a.issuedAt--;
        else a.expiresAt++;
        vm.expectRevert(SeasonAttestation.InvalidSignature.selector);
        _submit(a, sig);
        _unchanged(a.requestId);
    }

    function test_rootValidationFailureDoesNotConsumeAnOtherwiseValidRequest() public {
        SeasonAttestation.OracleAttestation memory a = _attestation(vault, POT + 1);
        bytes memory sig = _signature(a, vault.DOMAIN_SEPARATOR());
        vm.expectRevert(abi.encodeWithSelector(SeasonVault.OverPot.selector, POT + 1, POT));
        vault.submitAttestedRoot(0, root, POT + 1, CID, RULES, a, sig);
        _unchanged(a.requestId);
        a = _attestation(vault, POT);
        _submit(a, _signature(a, vault.DOMAIN_SEPARATOR()));
        assertTrue(vault.usedRequests(a.requestId));
    }

    function test_questionCidsAndWindowArePartOfTheSignedQuestion() public {
        SeasonAttestation.OracleAttestation memory a = _attestation(vault, POT);
        bytes memory sig = _signature(a, vault.DOMAIN_SEPARATOR());
        bytes32 original = a.questionHash;
        a.fromBlock++;
        a.questionHash = keccak256(vault.seasonQuestion(0, root, POT, CID, RULES, a.fromBlock, a.toBlock));
        assertNotEq(a.questionHash, original);
        vm.expectRevert(SeasonAttestation.InvalidSignature.selector);
        _submit(a, sig);
        a = _attestation(vault, POT);
        bytes32 expected =
            keccak256(vault.seasonQuestion(0, root, POT, "bafyDifferentLeaves", RULES, a.fromBlock, a.toBlock));
        vm.expectRevert(abi.encodeWithSelector(SeasonAttestation.WrongQuestion.selector, expected, a.questionHash));
        vault.submitAttestedRoot(0, root, POT, "bafyDifferentLeaves", RULES, a, sig);
        _unchanged(a.requestId);
    }

    function test_emptyOversizedAndEscapedCidsAreRejected() public {
        SeasonAttestation.OracleAttestation memory a = _attestation(vault, POT);
        bytes memory sig = _signature(a, vault.DOMAIN_SEPARATOR());
        string[5] memory bad = [string(""), string(new bytes(129)), "bafy/leaf", "bafy\nleaf", "bafy\\leaf"];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(SeasonAttestation.BadCid.selector);
            vault.submitAttestedRoot(0, root, POT, bad[i], RULES, a, sig);
            vm.prank(GOVERNOR);
            vm.expectRevert(SeasonAttestation.BadCid.selector);
            vault.proposeRoot(0, root, POT, bad[i]);
        }
        _unchanged(a.requestId);
    }
}
