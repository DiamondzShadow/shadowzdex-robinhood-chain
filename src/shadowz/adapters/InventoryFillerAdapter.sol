// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IVenueAdapter} from "../interfaces/IVenueAdapter.sol";
import {SwapIntent} from "../interfaces/IntentTypes.sol";

/// @notice Chainlink `AggregatorV3Interface` subset used for oracle pricing.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title InventoryFillerAdapter
/// @notice Oracle-priced RFQ / solver fill venue for the ShadowzDex IntentRouter.
///
///   This is the REAL day-one venue on Robinhood Chain mainnet. Public AMM
///   liquidity for the tokenized equities is nascent (the chain is days old), so
///   there is no pool deep enough to route against. As an *intent* router we do
///   not need one: the CRE attestor prices and authorizes each intent against the
///   live Chainlink equity feed, and this adapter *settles* that intent out of a
///   market-maker's inventory at the same on-chain oracle price, minus a spread.
///   That is exactly the model UniswapX / 0x / CoW use — RFQ fills, not on-chain
///   price discovery. It replaces the `FixedRatePoolAdapter` stub with a genuine,
///   trustless price (read on-chain from Chainlink, not from unsigned calldata).
///
///   Book model: one adapter instance holds a book of markets (each a Stock Token
///   listed against its Chainlink feed) sharing a single quote-token inventory
///   (USDG). Bidirectional per market — buy the stock with USDG, or sell it back.
///
///   Router integration (isAction = false): the router transfers `intent.amountIn`
///   of `tokenIn` into this adapter, then calls `execute()`. We deliver `tokenOut`
///   to the router (`msg.sender`); the router measures its own balance delta, takes
///   `min(delivered, reported)`, enforces `intent.minOut`, deducts protocol fee and
///   forwards the rest to the user. Inflow accrues as inventory; the market maker
///   tops up or withdraws via the treasurer role.
///
/// Security posture (hardened vs the testnet stub adapters, which let anyone call
/// `execute` directly and would have leaked real inventory):
///   - `execute` is `onlyRouter`: only the trusted router — which has already
///     pulled `tokenIn` — can trigger a fill. No free-drain by direct call.
///   - Price comes exclusively from the on-chain Chainlink feed with a staleness
///     guard; `adapterData` is ignored, so an unsigned caller blob cannot skew it.
///   - Withdrawals are `TREASURER_ROLE`-gated; config is `DEFAULT_ADMIN_ROLE`-gated
///     (grant both to the mainnet Safe). Pausable for incident response.
contract InventoryFillerAdapter is IVenueAdapter, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");

    /// @notice Only this router may invoke `execute` (it front-transfers tokenIn).
    address public immutable router;
    /// @notice Shared quote/settlement token for every market (USDG on RH mainnet).
    address public immutable quote;
    /// @notice Cached `quote` decimals (USDG = 6) to avoid a per-fill external call.
    uint8 public immutable quoteDecimals;

    /// @notice Ceiling on the configurable spread (10% = 1000 bps).
    uint16 public constant MAX_SPREAD_BPS = 1000;

    struct Market {
        address feed; // Chainlink USD price feed for the stock
        uint8 feedDecimals; // cached feed.decimals() (Chainlink USD = 8)
        uint8 stockDecimals; // cached stock.decimals() (RH stock tokens = 18)
        bool listed;
    }

    /// @notice Stock token => its market config. `quote` is never a key.
    mapping(address => Market) public markets;

    /// @notice Market-maker spread in bps, withheld from the oracle-fair output.
    uint16 public spreadBps;
    /// @notice Max age (seconds) of a feed's `updatedAt` before a fill is rejected.
    uint256 public maxStaleness;

    event MarketListed(address indexed stock, address indexed feed, uint8 feedDecimals, uint8 stockDecimals);
    event MarketDelisted(address indexed stock);
    event SpreadSet(uint16 spreadBps);
    event MaxStalenessSet(uint256 maxStaleness);
    event Deposited(address indexed token, address indexed from, uint256 amount);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event Filled(
        address indexed user, address indexed stock, bool buy, uint256 amountIn, uint256 amountOut, uint256 priceUsd8
    );

    error OnlyRouter();
    error UnsupportedPair();
    error BadPrice();
    error StalePrice();
    error ZeroOutput();
    error SpreadTooHigh();
    error ZeroAddress();

    error LengthMismatch();

    /// @param router_       IntentRouter allowed to call `execute`.
    /// @param quote_        Shared quote token (USDG).
    /// @param admin_        Receives DEFAULT_ADMIN_ROLE + TREASURER_ROLE (the Safe).
    /// @param spreadBps_    Initial MM spread (bps, <= MAX_SPREAD_BPS).
    /// @param maxStaleness_ Initial feed staleness ceiling (seconds).
    /// @param stocks_       Initial markets to list (parallel to feeds_); may be empty.
    /// @param feeds_        Chainlink feeds for `stocks_` (same length).
    /// @dev   Listing markets in the constructor lets a one-shot mainnet deploy
    ///        hand DEFAULT_ADMIN_ROLE straight to the Safe while still seeding the
    ///        book — the deployer never needs a role on this adapter.
    constructor(
        address router_,
        address quote_,
        address admin_,
        uint16 spreadBps_,
        uint256 maxStaleness_,
        address[] memory stocks_,
        address[] memory feeds_
    ) {
        if (router_ == address(0) || quote_ == address(0) || admin_ == address(0)) {
            revert ZeroAddress();
        }
        if (spreadBps_ > MAX_SPREAD_BPS) revert SpreadTooHigh();
        if (stocks_.length != feeds_.length) revert LengthMismatch();
        router = router_;
        quote = quote_;
        quoteDecimals = IERC20Metadata(quote_).decimals();
        spreadBps = spreadBps_;
        maxStaleness = maxStaleness_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(TREASURER_ROLE, admin_);
        emit SpreadSet(spreadBps_);
        emit MaxStalenessSet(maxStaleness_);
        for (uint256 i = 0; i < stocks_.length; i++) {
            _listMarket(stocks_[i], feeds_[i]);
        }
    }

    modifier onlyRouter() {
        if (msg.sender != router) revert OnlyRouter();
        _;
    }

    // ─────────────────────────────── Admin ────────────────────────────────

    /// @notice List (or re-point) a Stock Token market against its Chainlink feed.
    ///         Decimals are read on-chain and cached; the feed must return a sane
    ///         positive, fresh price at listing time.
    function listMarket(address stock, address feed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _listMarket(stock, feed);
    }

    function _listMarket(address stock, address feed) internal {
        if (stock == address(0) || feed == address(0)) revert ZeroAddress();
        if (stock == quote) revert UnsupportedPair();
        uint8 fdec = IAggregatorV3(feed).decimals();
        // Sanity: the feed is live and non-negative right now.
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0) revert BadPrice();
        if (block.timestamp - updatedAt > maxStaleness) revert StalePrice();
        uint8 sdec = IERC20Metadata(stock).decimals();
        markets[stock] = Market({feed: feed, feedDecimals: fdec, stockDecimals: sdec, listed: true});
        emit MarketListed(stock, feed, fdec, sdec);
    }

    function delistMarket(address stock) external onlyRole(DEFAULT_ADMIN_ROLE) {
        delete markets[stock];
        emit MarketDelisted(stock);
    }

    function setSpread(uint16 spreadBps_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (spreadBps_ > MAX_SPREAD_BPS) revert SpreadTooHigh();
        spreadBps = spreadBps_;
        emit SpreadSet(spreadBps_);
    }

    function setMaxStaleness(uint256 maxStaleness_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxStaleness = maxStaleness_;
        emit MaxStalenessSet(maxStaleness_);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ───────────────────────────── Inventory ──────────────────────────────

    /// @notice Convenience funding hook (a plain transfer works too). Permissionless
    ///         because adding inventory can only benefit the book.
    function deposit(address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(token, msg.sender, amount);
    }

    /// @notice Pull inventory out. Restricted — this is where real capital leaves.
    function withdraw(address token, uint256 amount, address to) external onlyRole(TREASURER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    function inventory(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    // ─────────────────────────────── Pricing ──────────────────────────────

    /// @notice Resolve a (tokenIn, tokenOut) pair to its stock + direction.
    /// @return stock the listed Stock Token; buy=true when quote→stock.
    function _resolve(address tokenIn, address tokenOut) internal view returns (address stock, bool buy) {
        if (tokenIn == quote && markets[tokenOut].listed) return (tokenOut, true);
        if (tokenOut == quote && markets[tokenIn].listed) return (tokenIn, false);
        revert UnsupportedPair();
    }

    function _price(Market memory m) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(m.feed).latestRoundData();
        if (answer <= 0) revert BadPrice();
        if (block.timestamp - updatedAt > maxStaleness) revert StalePrice();
        return uint256(answer);
    }

    /// @notice Oracle-fair output for `amountIn`, net of the MM spread. Same math
    ///         the on-chain fill uses, exposed for the off-chain best-ex quoter.
    ///         BUY  (quote→stock): out = amountIn · 10^(sDec+fDec) / (price · 10^qDec)
    ///         SELL (stock→quote): out = amountIn · price · 10^qDec / 10^(sDec+fDec)
    function quoteOut(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256 out) {
        (address stock, bool buy) = _resolve(tokenIn, tokenOut);
        Market memory m = markets[stock];
        uint256 price = _price(m);
        uint256 scaleStockFeed = 10 ** (uint256(m.stockDecimals) + uint256(m.feedDecimals));
        uint256 priceQuote = price * (10 ** uint256(quoteDecimals));
        out =
            buy ? Math.mulDiv(amountIn, scaleStockFeed, priceQuote) : Math.mulDiv(amountIn, priceQuote, scaleStockFeed);
        // Withhold the spread as MM margin.
        out = Math.mulDiv(out, uint256(10_000 - spreadBps), 10_000);
    }

    // ─────────────────────────────── Execute ──────────────────────────────

    /// @inheritdoc IVenueAdapter
    /// @dev `adapterData` is intentionally ignored — the price is read on-chain
    ///      from Chainlink so no caller-supplied blob can influence the fill.
    function execute(
        SwapIntent calldata intent,
        bytes calldata /* adapterData */
    )
        external
        override
        onlyRouter
        whenNotPaused
        returns (uint256 out)
    {
        (address stock, bool buy) = _resolve(intent.tokenIn, intent.tokenOut);
        Market memory m = markets[stock];
        uint256 price = _price(m);
        uint256 scaleStockFeed = 10 ** (uint256(m.stockDecimals) + uint256(m.feedDecimals));
        uint256 priceQuote = price * (10 ** uint256(quoteDecimals));
        out = buy
            ? Math.mulDiv(intent.amountIn, scaleStockFeed, priceQuote)
            : Math.mulDiv(intent.amountIn, priceQuote, scaleStockFeed);
        out = Math.mulDiv(out, uint256(10_000 - spreadBps), 10_000);
        if (out == 0) revert ZeroOutput();

        // Deliver tokenOut to the router; it enforces minOut + forwards to user.
        // Reverts on insufficient inventory (SafeERC20), failing the intent cleanly.
        IERC20(intent.tokenOut).safeTransfer(msg.sender, out);
        emit Filled(intent.user, stock, buy, intent.amountIn, out, price);
    }
}
