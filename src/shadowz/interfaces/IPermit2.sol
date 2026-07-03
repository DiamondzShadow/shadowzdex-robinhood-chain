// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPermit2 — Uniswap SignatureTransfer subset.
/// @notice Canonical address on every chain: 0x000000000022D473030F116dDEE9F6B43aC78BA3.
///         Only the witness-bound single-transfer entry point is needed by the router.
interface IPermit2 {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    /// @notice Transfers `requestedAmount` of `permit.permitted.token` from `owner`
    ///         to `transferDetails.to`, validating the user's EIP-712 signature
    ///         AND a caller-supplied witness that extends the signed typed-data.
    /// @dev    The router passes `witness = keccak256(abi.encode(IntentWitness typeHash, intentHash))`
    ///         so the signature is cryptographically bound to one specific
    ///         ShadowzDex intent — an attacker cannot replay the permit with
    ///         a different route, minOut, or recipient.
    function permitWitnessTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external;
}
