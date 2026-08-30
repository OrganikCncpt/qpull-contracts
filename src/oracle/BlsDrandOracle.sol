// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IDrandOracle } from "../interfaces/IDrandOracle.sol";

/// @title  BlsDrandOracle — trustless on-chain drand verification
/// @notice Verifies drand **quicknet** beacons (scheme `bls-unchained-g1-rfc9380`) fully on-chain
///         using the EIP-2537 BLS12-381 precompiles (confirmed live on RH, spec §13.2). Anyone may
///         submit a beacon; only a signature that passes the pairing check against the drand group
///         key is accepted — no relayers, no trust. The sole IDrandOracle implementation the protocol
///         deploys (the committee/DERP alternates were removed as unused and non-time-locked).
///
/// @dev    quicknet: sigs on G1 (48-byte compressed → submitted uncompressed, 128 bytes), pubkey on
///         G2, period 3s. Verify: e(H(m), pk) == e(sig, G2) where m = sha256(round_be8) and H is
///         RFC-9380 hash-to-G1. Stored randomness = keccak256(sig) — deterministic from the verified
///         signature and recomputable by anyone from the public drand beacon.
///
///         The verifier (hash-to-curve + pairing) was validated against a real beacon (round 1000)
///         via py_ecc-generated vectors in the test suite. Still: this is specialist crypto — get a
///         dedicated cryptographic review before mainnet.
contract BlsDrandOracle is IDrandOracle {
    // precompiles
    address internal constant MODEXP = address(0x05);
    address internal constant BLS_G1ADD = address(0x0b);
    address internal constant BLS_PAIRING = address(0x0f);
    address internal constant BLS_MAP_FP_TO_G1 = address(0x10);

    // BLS12-381 field modulus p (48 bytes)
    bytes internal constant P =
        hex"1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab";

    // DST for bls-unchained-g1-rfc9380, with the trailing length byte (RFC 9380 DST_prime)
    bytes internal constant DST_PRIME =
        hex"424c535f5349475f424c53313233383147315f584d443a5348412d3235365f535357555f524f5f4e554c5f2b";

    // drand quicknet group public key (G2, 256-byte EIP-2537 uncompressed)
    bytes internal constant PK =
        hex"000000000000000000000000000000000d1fec758c921cc22b0e17e63aaf4bcb5ed66304de9cf809bd274ca73bab4af5a6e9c76a4bc09e76eae8991ef5ece45a0000000000000000000000000000000003cf0f2896adee7eb8b5f01fcad3912212c437e0073e911fb90022d3e760183c8c4b450b6a0a6c3ac6a5776a2d106451000000000000000000000000000000000e5db2b6bfbb01c867749cadffca88b36c24f3012ba09fc4d3022c5c37dce0f977d3adb5d183c7477c442b1f045152730000000000000000000000000000000001a714f2edb74119a2f2b0d5a7c75ba902d163700a61bc224ededd8e63aef7be1aaf8e93d7a9718b047ccddb3eb5d68b";

    // negated G2 generator (256-byte EIP-2537 uncompressed) — for the product-equals-one pairing check
    bytes internal constant NEG_G2 =
        hex"00000000000000000000000000000000024aa2b2f08f0a91260805272dc51051c6e47ad4fa403b02b4510b647ae3d1770bac0326a805bbefd48056c8c121bdb80000000000000000000000000000000013e02b6052719f607dacd3a088274f65596bd0d09920b61ab5da61bbdc7f5049334cf11213945d57e5ac7d055d042b7e000000000000000000000000000000000d1b3cc2c7027888be51d9ef691d77bcb679afda66c73f17f9ee3837a55024f78c71363275a75d75d86bab79f74782aa0000000000000000000000000000000013fa4d4a0ad8b1ce186ed5061789213d993923066dddaf1040bc3ff59f825c78df74f2d75467e25e0f55f8a00fa030ed";

    uint256 public immutable drandGenesis; // 1692803367 for quicknet
    uint256 public immutable drandPeriod; // 3 for quicknet

    mapping(uint64 => bytes32) internal _rand;
    mapping(uint64 => bool) internal _ok;

    event BeaconVerified(uint64 indexed round, bytes32 randomness);

    error BadSigLength();
    error InvalidBeacon();
    error PrecompileFailed();
    error TimestampBeforeGenesis();

    error BadDrandParams();

    constructor(uint256 drandGenesis_, uint256 drandPeriod_) {
        // audit H-6/L-11: pin the drand SCHEDULE constants to quicknet, exactly like the crypto constants
        // (PK/DST/NEG_G2/P) are hardcoded. A wrong genesis/period doesn't revert anything — beacons still
        // verify — but silently shifts every reveal window, making draws predictable. period==0 also panics.
        if (drandGenesis_ != 1_692_803_367 || drandPeriod_ != 3) revert BadDrandParams();
        drandGenesis = drandGenesis_;
        drandPeriod = drandPeriod_;
    }

    /// @notice Permissionless: submit round `round`'s uncompressed (128-byte) drand signature. Stores
    ///         randomness only if the BLS pairing verifies against the drand group key.
    function submitBeacon(uint64 round, bytes calldata sig) external {
        if (sig.length != 128) revert BadSigLength();
        if (_ok[round]) return; // idempotent

        bytes32 m = sha256(abi.encodePacked(round)); // round as 8-byte big-endian
        bytes memory h = _hashToG1(m);

        // e(H, PK) * e(sig, -G2) == 1
        bytes memory input = bytes.concat(h, PK, sig, NEG_G2);
        (bool success, bytes memory out) = BLS_PAIRING.staticcall(input);
        if (!success || out.length != 32 || out[31] != 0x01) revert InvalidBeacon();

        bytes32 rnd = keccak256(sig);
        _rand[round] = rnd;
        _ok[round] = true;
        emit BeaconVerified(round, rnd);
    }

    // ─── RFC 9380 hash-to-G1 (expand_message_xmd + map_to_curve ×2 + add) ─────

    function _hashToG1(bytes32 m) internal view returns (bytes memory) {
        bytes memory b = _expandMessageXmd(m); // 128 bytes
        bytes memory q0 = _mapToG1(_toFp(b, 0));
        bytes memory q1 = _mapToG1(_toFp(b, 64));
        (bool s, bytes memory h) = BLS_G1ADD.staticcall(bytes.concat(q0, q1));
        if (!s || h.length != 128) revert PrecompileFailed();
        return h;
    }

    /// expand_message_xmd(SHA-256), len=128 → ell=4.
    function _expandMessageXmd(bytes32 m) internal pure returns (bytes memory) {
        bytes memory zpad = new bytes(64); // s_in_bytes zeros
        bytes32 b0 = sha256(bytes.concat(zpad, m, hex"0080", hex"00", DST_PRIME));
        bytes32 b1 = sha256(bytes.concat(b0, hex"01", DST_PRIME));
        bytes32 b2 = sha256(bytes.concat(b0 ^ b1, hex"02", DST_PRIME));
        bytes32 b3 = sha256(bytes.concat(b0 ^ b2, hex"03", DST_PRIME));
        bytes32 b4 = sha256(bytes.concat(b0 ^ b3, hex"04", DST_PRIME));
        return bytes.concat(b1, b2, b3, b4);
    }

    /// 64-byte chunk of `b` at `off` → field element mod p, EIP-2537 Fp (16 zero pad + 48-byte value).
    function _toFp(bytes memory b, uint256 off) internal view returns (bytes memory) {
        bytes memory chunk = new bytes(64);
        for (uint256 i; i < 64; ++i) {
            chunk[i] = b[off + i];
        }
        // modexp(chunk, 1, p) = chunk mod p (48-byte output)
        bytes memory input =
            bytes.concat(bytes32(uint256(64)), bytes32(uint256(1)), bytes32(uint256(48)), chunk, hex"01", P);
        (bool s, bytes memory res) = MODEXP.staticcall(input);
        if (!s || res.length != 48) revert PrecompileFailed();
        return bytes.concat(new bytes(16), res); // pad to 64
    }

    function _mapToG1(bytes memory fp) internal view returns (bytes memory) {
        (bool s, bytes memory q) = BLS_MAP_FP_TO_G1.staticcall(fp);
        if (!s || q.length != 128) revert PrecompileFailed();
        return q;
    }

    // ─── IDrandOracle ────────────────────────────────────────────────────────

    function isAvailable(uint64 round) external view returns (bool) {
        return _ok[round];
    }

    function randomness(uint64 round) external view returns (bytes32) {
        require(_ok[round], "unavailable");
        return _rand[round];
    }

    function roundAt(uint256 timestamp) external view returns (uint64) {
        // audit L-16: REVERT rather than fail open. A timestamp at/before drand genesis (Aug 2023) would
        // otherwise bind a draw to round 1 — a beacon public for years — making that draw resolvable the
        // instant it is created. Unreachable in normal use (every consumer's cutoff is the 2026 protocol
        // genesis plus a lag, far past drandGenesis), so reverting closes a latent fail-open with no cost.
        if (timestamp <= drandGenesis) revert TimestampBeforeGenesis();
        // First round whose scheduled publish time is at/AFTER `timestamp` (CEIL), per IDrandOracle.
        // A FLOOR here would bind a draw to the round that publishes up to (period-1)s BEFORE the cutoff,
        // so the settling beacon could be public while entries/snapshots for that draw are still open
        // (audit-2 root cause). Ceil guarantees reveal(roundAt(cutoff)) >= cutoff.
        return uint64((timestamp - drandGenesis + drandPeriod - 1) / drandPeriod) + 1;
    }
}
