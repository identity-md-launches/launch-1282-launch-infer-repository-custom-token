// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title SeasonAttestation
/// @notice Verifies an IdentityMD oracle attestation that a swarm panel answered YES to: "does this published leaf
/// file give exactly the allocations the points formula produces for this season, with this Merkle root and this
/// total?" The verify-not-compute shape: agreeing on a yes is far easier for a panel than agreeing on 32 bytes.
/// @dev Inherited by SeasonVault, so no second contract and no circular link.
///
/// What binds the answer to OUR question, and why each piece is needed:
///   - the signer is the plane's attester, a SOURCE CONSTANT (a manifest cannot substitute it);
///   - the EIP-712 domain names this contract and this chain, so an attestation bought for any other consumer
///     cannot be replayed here (the requester names `consumer` = this contract);
///   - the signed `questionHash` must equal the hash of the question document this contract rebuilds from the
///     season, its timestamps, the root, the total, the leaf file's CID and the season's rules document CID (which
///     must match the commitment made when the season was opened). Pinned text and the answer type are constants;
///     only those values and the window are spliced in. A yes to any other question — another root, another file,
///     other rules, another season — hashes differently and is refused;
///   - the answer must be the bool `true`, from a panel of at least MIN_PANEL_SIZE with at least MIN_AGREED
///     agreeing, unexpired, never used before.
///
/// The document is the plane's `questionDocument` (packages/protocol/src/schemas/oracle.ts) in its canonical
/// form: keys sorted, no whitespace — answerType, chainId, definitions, evidence, question, v, window.
/// `questionDocument()` is public so the exact bytes can be checked against the plane's canonicaliser for free
/// before a request is paid for.
abstract contract SeasonAttestation {
    struct OracleAttestation {
        bytes32 requestId;
        uint256 chainId;
        bytes32 questionHash;
        uint8 answerType;
        bytes answer;
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        bytes32 blockHash;
        bytes32 panelJobId;
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    uint16 public constant MIN_PANEL_SIZE = 25;
    uint16 public constant MIN_AGREED = 15;
    uint256 public constant DATA_CHAIN_ID = 1; // the points data is on Ethereum mainnet
    uint8 private constant ANSWER_BOOL = 0; // plane ORACLE_ANSWER_TYPE_CODES.bool

    /// The points formula is not a constant: each season names its own rules document, committed when the season
    /// is opened (the keccak256 of its IPFS CID, which reveals nothing) and posted to IPFS after the season, when the
    /// panel is asked. See SeasonVault.openSeason.

    bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );
    bytes32 public immutable DOMAIN_SEPARATOR;
    uint256 private constant _HALF_CURVE_ORDER = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    mapping(bytes32 requestId => bool) public usedRequests;

    error WrongChain();
    error NotYes();
    error PanelTooSmall();
    error NotEnoughAgreement();
    error Expired();
    error InvalidTimestamp();
    error Replayed();
    error InvalidSignature();
    error WrongQuestion(bytes32 expected, bytes32 given);
    error BadWindow();
    error BadCid();

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("IdentityMD Oracle"),
                keccak256("2"),
                block.chainid,
                address(this)
            )
        );
    }

    /// @dev The plane's oracle attester. Virtual only so tests can sign with their own key.
    function _attester() internal view virtual returns (address) {
        return 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    }

    /// @notice The exact question document a YES for this season must have been asked about.
    /// `formulaCid` is the season's rules document, `cid` the leaf file. The season's dates come from the vault.
    function questionDocument(
        uint256 season,
        bytes32 root,
        uint256 total,
        string calldata cid,
        string calldata formulaCid,
        uint64 fromBlock,
        uint64 toBlock
    ) public view returns (bytes memory) {
        return bytes.concat(_head(season, cid, formulaCid), _tail(root, total, fromBlock, toBlock));
    }

    /// @dev The season's [start, end) in unix time.
    function _window(uint256 season) internal view virtual returns (uint256 from, uint256 to);

    /// @dev The document up to the season's dates. Split from `_tail` only to stay within the stack.
    function _head(uint256 season, string calldata cid, string calldata formulaCid)
        private
        view
        returns (bytes memory)
    {
        (uint256 from, uint256 to) = _window(season);
        return abi.encodePacked(
            '{"answerType":"bool","chainId":1,"definitions":{"formula":"The INFER points formula for this season, ipfs://',
            formulaCid,
            '"},"evidence":"panel","question":"Does the file at ipfs://',
            cid,
            " give, for INFER points season index ",
            _decimal(season),
            " (unix time ",
            _decimal(from),
            " to ",
            _decimal(to)
        );
    }

    function _tail(bytes32 root, uint256 total, uint64 fromBlock, uint64 toBlock) private pure returns (bytes memory) {
        return abi.encodePacked(
            "), exactly the allocations that definitions.formula produces from Ethereum mainnet for that period, ",
            "as a standard Merkle tree whose leaves are keccak256(keccak256(abi.encode(season, account, amount))) ",
            "with root 0x",
            _hex(root),
            " and amounts summing to ",
            _decimal(total),
            ' wei of INFER?","v":1,"window":{"fromBlock":',
            _decimal(fromBlock),
            ',"toBlock":',
            _decimal(toBlock),
            "}}"
        );
    }

    /// @dev The hash of the question a YES must answer, over the attestation's own window. Checks both CIDs first.
    function _questionHash(
        uint256 season,
        bytes32 root,
        uint256 total,
        string calldata cid,
        string calldata formulaCid,
        OracleAttestation calldata a
    ) internal view returns (bytes32) {
        _checkCid(cid);
        _checkCid(formulaCid);
        return keccak256(questionDocument(season, root, total, cid, formulaCid, a.fromBlock, a.toBlock));
    }

    /// @dev Refuses unless `a` is a valid, unused YES whose signed question hash is `expected`. Marks it used.
    function _verifyYes(OracleAttestation calldata a, bytes calldata sig, bytes32 expected) internal {
        if (a.chainId != DATA_CHAIN_ID) revert WrongChain();
        if (a.answerType != ANSWER_BOOL || keccak256(a.answer) != keccak256(abi.encode(true))) revert NotYes();
        if (a.panelSize < MIN_PANEL_SIZE) revert PanelTooSmall();
        if (a.agreed < MIN_AGREED || a.agreed > a.panelSize) revert NotEnoughAgreement();
        if (block.timestamp > a.expiresAt) revert Expired();
        if (a.issuedAt > block.timestamp || a.issuedAt > a.expiresAt) revert InvalidTimestamp();
        if (usedRequests[a.requestId]) revert Replayed();
        if (a.toBlock < a.fromBlock || (block.chainid == DATA_CHAIN_ID && a.toBlock > block.number)) {
            revert BadWindow();
        }
        if (a.questionHash != expected) revert WrongQuestion(expected, a.questionHash);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, _attestationHash(a)));
        if (_recover(digest, sig) != _attester()) revert InvalidSignature();
        usedRequests[a.requestId] = true;
    }

    /// @dev A CID goes inside a JSON string, so only characters that need no escaping: base32/base58 letters and
    /// digits. Also keeps the document's bytes unambiguous.
    function _checkCid(string calldata cid) internal pure {
        bytes calldata b = bytes(cid);
        if (b.length == 0 || b.length > 128) revert BadCid();
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (!((c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9"))) revert BadCid();
        }
    }

    function _attestationHash(OracleAttestation calldata a) private pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                abi.encode(
                    ATTESTATION_TYPEHASH,
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
    }

    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address signer) {
        if (sig.length != 65) revert InvalidSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (uint256(s) > _HALF_CURVE_ORDER || (v != 27 && v != 28)) revert InvalidSignature();
        signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert InvalidSignature();
    }

    function _decimal(uint256 value) private pure returns (bytes memory out) {
        if (value == 0) return "0";
        uint256 digits;
        for (uint256 v = value; v != 0; v /= 10) {
            ++digits;
        }
        out = new bytes(digits);
        for (uint256 v = value; v != 0; v /= 10) {
            out[--digits] = bytes1(uint8(48 + (v % 10)));
        }
    }

    function _hex(bytes32 value) private pure returns (bytes memory out) {
        bytes16 symbols = "0123456789abcdef";
        out = new bytes(64);
        for (uint256 i; i < 32; ++i) {
            out[2 * i] = symbols[uint8(value[i]) >> 4];
            out[2 * i + 1] = symbols[uint8(value[i]) & 0x0f];
        }
    }
}
