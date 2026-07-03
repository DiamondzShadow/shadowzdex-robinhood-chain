// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {QuoteVerifier} from "./QuoteVerifier.sol";
import {IVenueAdapter} from "./interfaces/IVenueAdapter.sol";
import {IShadowPassLike} from "./interfaces/IShadowPassLike.sol";
import {IPermit2} from "./interfaces/IPermit2.sol";
import {SwapIntent} from "./interfaces/IntentTypes.sol";
import {FeeVault} from "./FeeVault.sol";

/// @title IntentRouter
/// @notice Entry point for ShadowzDex. Takes a CRE-attested intent, pulls
///         tokenIn from the user, dispatches to the venue adapter, enforces
///         slippage, and collects the protocol fee.
///
/// Venues come in two flavors:
///   - swap       adapter returns tokenOut to router; router forwards minus fee.
///   - action     adapter handles final disposition itself (NFT mint, bridge).
///                router does not touch tokenOut and does not take a fee
///                (the action target — e.g. V15 vault — charges its own fees).
contract IntentRouter is QuoteVerifier, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    bytes32 public constant RESCUER_ROLE = keccak256("RESCUER_ROLE");

    uint256 internal constant BPS = 10_000;
    uint256 public constant MAX_FEE_BPS = 100; // hard ceiling 1%

    /// @notice Uniswap Permit2 — same address on every chain.
    ///         Zero-address disables `executeSwapWithPermit2` for that deploy.
    IPermit2 public immutable PERMIT2;

    /// @dev EIP-712 typehash for the struct we bind into the Permit2 signature
    ///      so a single user sig commits to one specific CRE-attested intent.
    bytes32 public constant INTENT_WITNESS_TYPEHASH =
        keccak256("IntentWitness(bytes32 intentHash)");

    /// @dev Witness type string appended to Permit2's
    ///      "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,"
    ///      stub. Sub-types alphabetically ordered per EIP-712.
    string internal constant PERMIT2_WITNESS_TYPE_STRING =
        "IntentWitness witness)IntentWitness(bytes32 intentHash)TokenPermissions(address token,uint256 amount)";

    struct VenueConfig {
        address adapter;
        bool isAction;
    }

    /// @notice venue key → adapter binding.
    mapping(bytes32 => VenueConfig) public venues;

    /// @notice Protocol fee on pure swaps, charged on tokenOut.
    uint16 public feeBps;
    /// @notice Fee discount in absolute bps (subtracted from feeBps) if user holds ShadowPass.
    uint16 public passDiscountBps;
    address public feeTreasury;
    IShadowPassLike public shadowPass;

    /// @notice SDM token on this chain — used for tier verification.
    ///         Zero address disables tier checks (dev/test only).
    IERC20 public sdmToken;
    /// @notice FeeVault for bridge-fee accounting + LINK refill pipeline.
    ///         Zero address disables bridge-fee flow.
    FeeVault public feeVault;

    /// @notice Minimum SDM balance per tier. Tier 0 = no discount, no floor.
    ///         Hard-coded SDM-denominated; SDM has 18 decimals.
    ///         Keeping these on-chain blocks flash-loan tier gaming.
    uint256[6] internal _tierFloors = [
        0,
        25_000   * 1e18,
        100_000  * 1e18,
        500_000  * 1e18,
        1_000_000 * 1e18,
        5_000_000 * 1e18
    ];

    event VenueSet(bytes32 indexed venue, address adapter, bool isAction);
    event FeeConfigured(uint16 feeBps, uint16 passDiscountBps, address treasury);
    event ShadowPassSet(address nft);
    event SdmTokenSet(address token);
    event FeeVaultSet(address vault);
    event BridgeFeeCollected(address indexed user, address token, uint256 amount, uint8 tier);
    event SwapExecuted(
        address indexed user,
        bytes32 indexed venue,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee
    );
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error VenueUnknown();
    error SlippageExceeded();
    error FeeTooHigh();
    error ZeroAddress();
    error Permit2Disabled();
    error Permit2TokenMismatch();
    error Permit2AmountMismatch();
    error InvalidTier();
    error SdmBalanceInsufficient(uint256 held, uint256 required);
    error SdmTokenNotSet();
    error FeeVaultNotSet();
    error BridgeFeeExceedsAmount();

    constructor(address admin, address permit2)
        QuoteVerifier("ShadowzDex.IntentRouter", "1")
    {
        if (admin == address(0)) revert ZeroAddress();
        PERMIT2 = IPermit2(permit2); // zero-address allowed: disables Permit2 path
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(CONFIG_ROLE, admin);
        _grantRole(RESCUER_ROLE, admin);
        _grantRole(SIGNER_ADMIN_ROLE, admin);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Admin
    // ═════════════════════════════════════════════════════════════════════

    function setVenue(bytes32 venue, address adapter, bool isAction) external onlyRole(CONFIG_ROLE) {
        if (adapter == address(0)) revert ZeroAddress();
        venues[venue] = VenueConfig({adapter: adapter, isAction: isAction});
        emit VenueSet(venue, adapter, isAction);
    }

    function clearVenue(bytes32 venue) external onlyRole(CONFIG_ROLE) {
        delete venues[venue];
        emit VenueSet(venue, address(0), false);
    }

    function setFee(uint16 feeBps_, uint16 passDiscountBps_, address treasury) external onlyRole(CONFIG_ROLE) {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        if (passDiscountBps_ > feeBps_) revert FeeTooHigh();
        if (treasury == address(0)) revert ZeroAddress();
        feeBps = feeBps_;
        passDiscountBps = passDiscountBps_;
        feeTreasury = treasury;
        emit FeeConfigured(feeBps_, passDiscountBps_, treasury);
    }

    function setShadowPass(address nft) external onlyRole(CONFIG_ROLE) {
        shadowPass = IShadowPassLike(nft);
        emit ShadowPassSet(nft);
    }

    /// @notice SDM token used for tier-verification in bridge flows.
    ///         Zero address disables tier enforcement (any claim accepted).
    function setSdmToken(address token) external onlyRole(CONFIG_ROLE) {
        sdmToken = IERC20(token);
        emit SdmTokenSet(token);
    }

    /// @notice FeeVault that receives bridge fees (split 20/80 inside).
    ///         Zero address rejects any intent with bridgeFeeAmount > 0.
    function setFeeVault(address vault) external onlyRole(CONFIG_ROLE) {
        feeVault = FeeVault(vault);
        emit FeeVaultSet(vault);
    }

    /// @notice Read tier floor for UI/tests.
    function tierFloor(uint8 tier) external view returns (uint256) {
        if (tier > 5) revert InvalidTier();
        return _tierFloors[tier];
    }

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    function rescueToken(address token, address to, uint256 amount) external onlyRole(RESCUER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Execute
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Execute a CRE-attested swap intent using legacy `approve` +
    ///         `transferFrom`. Use `executeSwapWithPermit2` for signature-based
    ///         token pulls.
    /// @dev msg.sender must be `intent.user` (prevents an attacker from spending
    ///      an unspent signed intent on someone else's approval).
    function executeSwap(
        SwapIntent calldata intent,
        bytes calldata signature,
        bytes calldata adapterData
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        require(msg.sender == intent.user, "not intent user");

        VenueConfig memory v = venues[intent.venue];
        if (v.adapter == address(0)) revert VenueUnknown();

        _consumeIntent(intent, signature);
        _verifyTier(intent);

        if (intent.bridgeFeeAmount > 0) {
            if (address(feeVault) == address(0)) revert FeeVaultNotSet();
            if (intent.bridgeFeeAmount >= intent.amountIn) revert BridgeFeeExceedsAmount();
            // Pull full amountIn to router, split fee → vault, forward rest → adapter.
            IERC20(intent.tokenIn).safeTransferFrom(intent.user, address(this), intent.amountIn);
            IERC20(intent.tokenIn).safeTransfer(address(feeVault), intent.bridgeFeeAmount);
            feeVault.deposit(intent.tokenIn, intent.bridgeFeeAmount);
            IERC20(intent.tokenIn).safeTransfer(v.adapter, intent.amountIn - intent.bridgeFeeAmount);
            emit BridgeFeeCollected(intent.user, intent.tokenIn, intent.bridgeFeeAmount, intent.sdmTier);
        } else {
            // No fee: direct transfer (gas-optimal for non-bridge venues).
            IERC20(intent.tokenIn).safeTransferFrom(intent.user, v.adapter, intent.amountIn);
        }
        amountOut = _dispatch(intent, v, adapterData);
    }

    /// @notice Execute a CRE-attested swap using a **Permit2 witness signature**
    ///         instead of an ERC-20 allowance. The user signs one EIP-712
    ///         message carrying the transfer permission AND the intent hash
    ///         as witness — binding the token pull to exactly this swap.
    /// @param  permit    Permit2 PermitTransferFrom (nonce, deadline, permitted token + amount)
    /// @param  permit2Sig User's EIP-712 signature over PermitWitnessTransferFrom
    /// @dev    The router reads `intent.tokenIn / amountIn` and enforces that
    ///         `permit.permitted` matches — the signature is worthless on any
    ///         other route. `PERMIT2 == address(0)` → function reverts.
    function executeSwapWithPermit2(
        SwapIntent calldata intent,
        bytes calldata intentSignature,
        IPermit2.PermitTransferFrom calldata permit,
        bytes calldata permit2Sig,
        bytes calldata adapterData
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        if (address(PERMIT2) == address(0)) revert Permit2Disabled();
        require(msg.sender == intent.user, "not intent user");
        if (permit.permitted.token != intent.tokenIn) revert Permit2TokenMismatch();
        if (permit.permitted.amount < intent.amountIn) revert Permit2AmountMismatch();

        VenueConfig memory v = venues[intent.venue];
        if (v.adapter == address(0)) revert VenueUnknown();

        _consumeIntent(intent, intentSignature);
        _verifyTier(intent);

        bytes32 intentHash = hashIntent(intent);
        bytes32 witness = keccak256(abi.encode(INTENT_WITNESS_TYPEHASH, intentHash));

        // For fee-bearing intents, pull to router first then split; for free
        // swaps, pull direct to adapter (same behavior as executeSwap).
        address pullTarget = intent.bridgeFeeAmount > 0 ? address(this) : v.adapter;
        if (intent.bridgeFeeAmount > 0) {
            if (address(feeVault) == address(0)) revert FeeVaultNotSet();
            if (intent.bridgeFeeAmount >= intent.amountIn) revert BridgeFeeExceedsAmount();
        }

        // Pull tokenIn. Permit2 verifies:
        //   • intent.user owns `amountIn` of tokenIn
        //   • the user has an ERC-20 approval to Permit2
        //   • the permit2Sig is valid for this (token, amount, nonce, deadline, witness)
        // Any mismatch → Permit2 reverts, protecting the user.
        PERMIT2.permitWitnessTransferFrom(
            permit,
            IPermit2.SignatureTransferDetails({to: pullTarget, requestedAmount: intent.amountIn}),
            intent.user,
            witness,
            PERMIT2_WITNESS_TYPE_STRING,
            permit2Sig
        );

        if (intent.bridgeFeeAmount > 0) {
            IERC20(intent.tokenIn).safeTransfer(address(feeVault), intent.bridgeFeeAmount);
            feeVault.deposit(intent.tokenIn, intent.bridgeFeeAmount);
            IERC20(intent.tokenIn).safeTransfer(v.adapter, intent.amountIn - intent.bridgeFeeAmount);
            emit BridgeFeeCollected(intent.user, intent.tokenIn, intent.bridgeFeeAmount, intent.sdmTier);
        }

        amountOut = _dispatch(intent, v, adapterData);
    }

    /// @notice Keeper-friendly variant of `executeSwapWithPermit2`.
    ///         Drops the `msg.sender == intent.user` restriction so a relayer
    ///         (or scheduled bot, e.g. shadowz-keeperz' DCA + limit-order
    ///         runners) can submit on a user's behalf. Security model is
    ///         unchanged because the Permit2 witness binds the transfer to
    ///         exactly this intent hash:
    ///           • intent signature must come from a registered ATTESTOR
    ///             (same _consumeIntent path as user-facing executeSwap*)
    ///           • permit2Sig must come from `intent.user` (Permit2 verifies)
    ///           • permit.permitted.token == intent.tokenIn (this function
    ///             enforces — no replay across different intents)
    ///           • Permit2 nonce single-use (Permit2 enforces)
    ///         Together: only the user could have authorized this exact pull,
    ///         only the attestor could have authorized this exact route.
    ///         msg.sender just pays gas.
    /// @dev    NFT/token deliverable always goes to `intent.user` via the
    ///         adapter, NOT msg.sender — keepers can't redirect output.
    function executeSwapWithPermit2Keeper(
        SwapIntent calldata intent,
        bytes calldata intentSignature,
        IPermit2.PermitTransferFrom calldata permit,
        bytes calldata permit2Sig,
        bytes calldata adapterData
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        if (address(PERMIT2) == address(0)) revert Permit2Disabled();
        if (permit.permitted.token != intent.tokenIn) revert Permit2TokenMismatch();
        if (permit.permitted.amount < intent.amountIn) revert Permit2AmountMismatch();

        VenueConfig memory v = venues[intent.venue];
        if (v.adapter == address(0)) revert VenueUnknown();

        _consumeIntent(intent, intentSignature);
        _verifyTier(intent);

        bytes32 intentHash = hashIntent(intent);
        bytes32 witness = keccak256(abi.encode(INTENT_WITNESS_TYPEHASH, intentHash));

        address pullTarget = intent.bridgeFeeAmount > 0 ? address(this) : v.adapter;
        if (intent.bridgeFeeAmount > 0) {
            if (address(feeVault) == address(0)) revert FeeVaultNotSet();
            if (intent.bridgeFeeAmount >= intent.amountIn) revert BridgeFeeExceedsAmount();
        }

        PERMIT2.permitWitnessTransferFrom(
            permit,
            IPermit2.SignatureTransferDetails({to: pullTarget, requestedAmount: intent.amountIn}),
            intent.user,
            witness,
            PERMIT2_WITNESS_TYPE_STRING,
            permit2Sig
        );

        if (intent.bridgeFeeAmount > 0) {
            IERC20(intent.tokenIn).safeTransfer(address(feeVault), intent.bridgeFeeAmount);
            feeVault.deposit(intent.tokenIn, intent.bridgeFeeAmount);
            IERC20(intent.tokenIn).safeTransfer(v.adapter, intent.amountIn - intent.bridgeFeeAmount);
            emit BridgeFeeCollected(intent.user, intent.tokenIn, intent.bridgeFeeAmount, intent.sdmTier);
        }

        amountOut = _dispatch(intent, v, adapterData);
    }

    /// @notice On-chain tier verification — blocks flash-loan tier gaming.
    ///         Attestor claims tier in signed intent; router re-checks
    ///         actual SDM balance at execute time. Mismatch → revert.
    function _verifyTier(SwapIntent calldata intent) internal view {
        if (intent.sdmTier > 5) revert InvalidTier();
        if (intent.sdmTier == 0) return; // no claim, no check
        if (address(sdmToken) == address(0)) revert SdmTokenNotSet();
        uint256 bal = sdmToken.balanceOf(intent.user);
        uint256 floor = _tierFloors[intent.sdmTier];
        if (bal < floor) revert SdmBalanceInsufficient(bal, floor);
    }

    function _dispatch(SwapIntent calldata intent, VenueConfig memory v, bytes calldata adapterData)
        internal
        returns (uint256 amountOut)
    {
        if (v.isAction) {
            amountOut = IVenueAdapter(v.adapter).execute(intent, adapterData);
            if (amountOut < intent.minOut) revert SlippageExceeded();
            emit SwapExecuted(
                intent.user, intent.venue, intent.tokenIn, intent.tokenOut,
                intent.amountIn, amountOut, 0
            );
            return amountOut;
        }

        uint256 before = IERC20(intent.tokenOut).balanceOf(address(this));
        uint256 reported = IVenueAdapter(v.adapter).execute(intent, adapterData);
        uint256 delivered = IERC20(intent.tokenOut).balanceOf(address(this)) - before;

        amountOut = delivered < reported ? delivered : reported;
        if (amountOut < intent.minOut) revert SlippageExceeded();

        uint256 fee = _quoteFee(intent.user, amountOut);
        if (fee > 0) IERC20(intent.tokenOut).safeTransfer(feeTreasury, fee);
        IERC20(intent.tokenOut).safeTransfer(intent.user, amountOut - fee);

        emit SwapExecuted(
            intent.user, intent.venue, intent.tokenIn, intent.tokenOut,
            intent.amountIn, amountOut - fee, fee
        );
    }

    /// @notice Fee in tokenOut for a given user and gross amount.
    function _quoteFee(address user, uint256 gross) internal view returns (uint256) {
        uint16 bps = feeBps;
        if (bps == 0) return 0;
        if (address(shadowPass) != address(0) && shadowPass.balanceOf(user) > 0) {
            uint16 discount = passDiscountBps;
            bps = discount >= bps ? 0 : bps - discount;
        }
        return (gross * bps) / BPS;
    }

    /// @notice Public view for UIs to show effective fee without executing.
    function effectiveFeeBps(address user) external view returns (uint16) {
        uint16 bps = feeBps;
        if (address(shadowPass) != address(0) && shadowPass.balanceOf(user) > 0) {
            uint16 discount = passDiscountBps;
            bps = discount >= bps ? 0 : bps - discount;
        }
        return bps;
    }
}
