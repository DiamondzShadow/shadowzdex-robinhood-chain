// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {SwapIntent} from "./interfaces/IntentTypes.sol";

/// @title QuoteVerifier
/// @notice EIP-712 verification layer for Chainlink CRE attestations.
///         CRE fetches quotes off-chain, sanity-checks against Chainlink feeds,
///         then signs the intent hash. Router inherits this and calls
///         `_consumeIntent` before executing.
abstract contract QuoteVerifier is AccessControl, EIP712 {
    using ECDSA for bytes32;

    bytes32 public constant SIGNER_ADMIN_ROLE = keccak256("SIGNER_ADMIN_ROLE");

    bytes32 private constant SWAP_INTENT_TYPEHASH = keccak256(
        "SwapIntent(address user,address tokenIn,address tokenOut,uint256 amountIn,uint256 minOut,uint256 deadline,bytes32 venue,uint256 nonce,bytes extra,uint256 bridgeFeeAmount,uint8 sdmTier)"
    );

    /// @notice Addresses authorized to sign intents (CRE hot keys).
    mapping(address => bool) public isAttestor;
    /// @notice Per-user nonce consumption (replay guard).
    mapping(address => mapping(uint256 => bool)) public usedNonces;

    event AttestorUpdated(address indexed signer, bool allowed);
    event IntentConsumed(address indexed user, uint256 indexed nonce, bytes32 venue);

    error ExpiredIntent();
    error InvalidSigner();
    error NonceReused();

    constructor(string memory name_, string memory version_) EIP712(name_, version_) {}

    function setAttestor(address signer, bool allowed) external onlyRole(SIGNER_ADMIN_ROLE) {
        isAttestor[signer] = allowed;
        emit AttestorUpdated(signer, allowed);
    }

    /// @dev Returns the EIP-712 digest for an intent — exposed for off-chain
    ///      signers and tests.
    function hashIntent(SwapIntent calldata intent) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                SWAP_INTENT_TYPEHASH,
                intent.user,
                intent.tokenIn,
                intent.tokenOut,
                intent.amountIn,
                intent.minOut,
                intent.deadline,
                intent.venue,
                intent.nonce,
                keccak256(intent.extra),
                intent.bridgeFeeAmount,
                intent.sdmTier
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function _consumeIntent(SwapIntent calldata intent, bytes calldata signature) internal {
        if (block.timestamp > intent.deadline) revert ExpiredIntent();
        if (usedNonces[intent.user][intent.nonce]) revert NonceReused();

        address signer = hashIntent(intent).recover(signature);
        if (!isAttestor[signer]) revert InvalidSigner();

        usedNonces[intent.user][intent.nonce] = true;
        emit IntentConsumed(intent.user, intent.nonce, intent.venue);
    }
}
