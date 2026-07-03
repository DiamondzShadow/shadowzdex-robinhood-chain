// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title FeeVault
/// @notice Collects bridge fees from IntentRouter in any ERC-20 tokenIn.
///         Splits each deposit internally 20 / 80:
///            - 20 %  → earmarked for TREASURY withdrawal (Safe)
///            - 80 %  → earmarked for KEEPER withdrawal (to fund LINK refills)
///         Off-chain keeper swaps the 80 % slice to LINK via 0x and deposits
///         into the relevant CCIPSendAdapter on each chain.
///
/// The split is accounting-only — all tokens sit in this contract until one of
/// the two withdraw paths is called. The split ratio is hard-coded to avoid
/// governance drift; change requires redeploy.
contract FeeVault is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant TREASURY_BPS = 2_000; // 20 %
    uint16 public constant KEEPER_BPS   = 8_000; // 80 %
    uint16 public constant BPS_DENOM    = 10_000;

    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE"); // IntentRouter
    bytes32 public constant TREASURY_ROLE  = keccak256("TREASURY_ROLE");  // Safe
    bytes32 public constant KEEPER_ROLE    = keccak256("KEEPER_ROLE");    // Refill bot
    bytes32 public constant RESCUER_ROLE   = keccak256("RESCUER_ROLE");

    /// @notice Per-token balance owed to the treasury side (not yet withdrawn).
    mapping(address => uint256) public treasuryBalance;
    /// @notice Per-token balance owed to the keeper side (not yet withdrawn).
    mapping(address => uint256) public keeperBalance;

    event Deposited(address indexed token, uint256 amount, uint256 toTreasury, uint256 toKeeper);
    event TreasuryWithdraw(address indexed token, address indexed to, uint256 amount);
    event KeeperWithdraw(address indexed token, address indexed to, uint256 amount);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error OnlyDepositor();
    error InsufficientShare(uint256 requested, uint256 available);
    error ZeroAddress();
    error ZeroAmount();

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TREASURY_ROLE, admin);
        _grantRole(RESCUER_ROLE, admin);
        // DEPOSITOR_ROLE and KEEPER_ROLE are granted post-deploy to the router
        // and keeper bot, respectively.
    }

    /// @notice Called by IntentRouter AFTER it has transferred `amount` of
    ///         `token` into this contract. Updates internal accounting to
    ///         split 20/80 between treasury and keeper sides.
    /// @dev    Router is expected to `safeTransfer` first, then call `deposit`.
    ///         We intentionally do not pull in `transferFrom` to avoid a second
    ///         allowance-tracking surface.
    function deposit(address token, uint256 amount)
        external
        onlyRole(DEPOSITOR_ROLE)
    {
        if (amount == 0) revert ZeroAmount();
        uint256 toTreasury = (amount * TREASURY_BPS) / BPS_DENOM;
        uint256 toKeeper   = amount - toTreasury; // no rounding loss
        treasuryBalance[token] += toTreasury;
        keeperBalance[token]   += toKeeper;
        emit Deposited(token, amount, toTreasury, toKeeper);
    }

    function withdrawTreasury(address token, address to, uint256 amount)
        external
        onlyRole(TREASURY_ROLE)
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        uint256 avail = treasuryBalance[token];
        if (amount > avail) revert InsufficientShare(amount, avail);
        treasuryBalance[token] = avail - amount;
        IERC20(token).safeTransfer(to, amount);
        emit TreasuryWithdraw(token, to, amount);
    }

    function withdrawKeeper(address token, address to, uint256 amount)
        external
        onlyRole(KEEPER_ROLE)
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        uint256 avail = keeperBalance[token];
        if (amount > avail) revert InsufficientShare(amount, avail);
        keeperBalance[token] = avail - amount;
        IERC20(token).safeTransfer(to, amount);
        emit KeeperWithdraw(token, to, amount);
    }

    /// @notice Emergency: admin sweeps tokens that bypassed `deposit` (direct
    ///         transfers, mistakes). Does NOT touch the tracked balances.
    function rescueToken(address token, address to, uint256 amount)
        external
        onlyRole(RESCUER_ROLE)
    {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }
}
