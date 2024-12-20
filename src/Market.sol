// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.20;

import "./libraries/Reserve.sol";
import "./libraries/SafeCast.sol";
import "./libraries/Transfers.sol";
import "./libraries/Units.sol";
import "./libraries/CoveredCall.sol";

import "./interfaces/callback/ICreateCallback.sol";
import "./interfaces/callback/IDepositCallback.sol";
import "./interfaces/callback/ILiquidityCallback.sol";
import "./interfaces/callback/ISwapCallback.sol";

import "./interfaces/IERC20.sol";
import "./interfaces/IMarket.sol";
import "./interfaces/IFactory.sol";

//  _   _  _   _  _    _   ____  
// | \ | || | | ||  \/  | / __ \ 
// |  \| || | | || |\/| || |  | |
// | |\  || |_| || |  | || |__| |
// |_| \_| \___/ |_|  |_| \____/  

/// @title   Market
/// @author  Robert Leifke 
/// @notice  Modified from PrimitiveEngine.sol
/// @dev     RMM-01
contract Market is IMarket {
    using Units for uint256;
    using SafeCast for uint256;
    using Reserve for mapping(bytes32 => Reserve.Data);
    using Reserve for Reserve.Data;
    using Transfers for IERC20;

    /// @inheritdoc IMarketView
    uint256 public constant override PRECISION = 10**18;
    /// @inheritdoc IMarketView
    uint256 public constant override BUFFER = 120 seconds;
    /// @inheritdoc IMarketView
    uint256 public immutable override MIN_LIQUIDITY;
    /// @inheritdoc IMarketView
    uint256 public immutable override scaleFactorQuote;
    /// @inheritdoc IMarketView
    uint256 public immutable override scaleFactorBase;
    /// @inheritdoc IMarketView
    address public immutable override factory;
    /// @inheritdoc IMarketView
    address public immutable override quote;
    /// @inheritdoc IMarketView
    address public immutable override base;
    /// @dev Reentrancy guard initialized to state
    uint256 private locked = 1;
    /// @inheritdoc IMarketView
    mapping(bytes32 => Calibration) public override calibrations;
    /// @inheritdoc IMarketView
    mapping(bytes32 => Reserve.Data) public override reserves;
    /// @inheritdoc IMarketView
    mapping(address => mapping(bytes32 => uint256)) public override liquidity;

    modifier lock() {
        if (locked != 1) revert LockedError();

        locked = 2;
        _;
        locked = 1;
    }

    /// @notice Deploys an Engine with two tokens, a 'Quote' and 'Base'
    constructor() {
        (factory, quote, base, scaleFactorQuote, scaleFactorBase, MIN_LIQUIDITY) = IFactory(msg.sender)
            .args();
    }

    function init(uint256 priceBase, uint256 amountBase, uint256 strike_)
        external
        lock
        returns (uint256 totalLiquidity_, uint256 amountY)
    {
        if (strike_ <= 1e18 || strike != 0) revert InvalidStrike();

        (totalLiquidity_, amountQuote) = prepareInit(priceBase, amountBase, strike_, sigma);

        _mint(msg.sender, totalLiquidity_ - 1000);
        _mint(address(0), 1000);
        _adjust(toInt(amountBase), toInt(amountQuote), toInt(totalLiquidity_), strike_);
        _debit(reserveBase);
        _debit(reserveQuote);

        emit Init(
            msg.sender, amountBase, amountQuote, totalLiquidity_, strike_, sigma, fee, maturity
        );
    }

    /// @return Quote token balance of this contract
    function balanceQuote() private view returns (uint256) {
        (bool success, bytes memory data) = quote.staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(this))
        );
        if (!success || data.length != 32) revert BalanceError();
        return abi.decode(data, (uint256));
    }

    /// @return Base token balance of this contract
    function balanceBase() private view returns (uint256) {
        (bool success, bytes memory data) = base.staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(this))
        );
        if (!success || data.length != 32) revert BalanceError();
        return abi.decode(data, (uint256));
    }

    /// @notice Revert if expected amount does not exceed current balance
    function checkQuoteBalance(uint256 expectedQuote) private view {
        uint256 actualQuote = balanceQuote();
        if (actualQuote < expectedQuote) revert quoteBalanceError(expectedQuote, actualQuote);
    }

    /// @notice Revert if expected amount does not exceed current balance
    function checkBaseBalance(uint256 expectedBase) private view {
        uint256 actualBase = balanceBase();
        if (actualBase < expectedBase) revert baseBalanceError(expectedBase, actualBase);
    }

    /// @return blockTimestamp casted as a uint32
    function _blockTimestamp() internal view virtual returns (uint32 blockTimestamp) {
        // solhint-disable-next-line
        blockTimestamp = uint32(block.timestamp);
    }

    /// @inheritdoc IMarketActions
    function updateLastTimestamp(bytes32 poolId) external override lock returns (uint32 lastTimestamp) {
        lastTimestamp = _updateLastTimestamp(poolId);
    }

    /// @notice Sets the lastTimestamp of `poolId` to `block.timestamp`, max value is `maturity`
    /// @return lastTimestamp of the pool, used in calculating the time until expiry
    function _updateLastTimestamp(bytes32 poolId) internal virtual returns (uint32 lastTimestamp) {
        Calibration storage cal = calibrations[poolId];
        if (cal.lastTimestamp == 0) revert UninitializedError();

        lastTimestamp = _blockTimestamp();
        uint32 maturity = cal.maturity;
        if (lastTimestamp > maturity) lastTimestamp = maturity; // if expired, set to the maturity

        cal.lastTimestamp = lastTimestamp; // set state
        emit UpdateLastTimestamp(poolId);
    }

    /// @inheritdoc IMarketActions
    function create(
        uint128 strike,
        uint32 sigma,
        uint32 maturity,
        uint32 swapFee,
        uint256 totalLiquidity,
        uint256 reserveBase,
        uint256 reserveQuote,
        bytes calldata data
    )
        external
        override
        lock
        returns (
            bytes32 poolId,
            uint256 delQuote,
            uint256 delBase
        )
    {
        (uint256 factor0, uint256 factor1) = (scaleFactorQuote, scaleFactorBase);
        poolId = keccak256(abi.encodePacked(address(this), strike, sigma, maturity, adminFee));
        if (calibrations[poolId].lastTimestamp != 0) revert PoolDuplicateError();
        if (sigma > 1e7 || sigma < 1) revert SigmaError(sigma);
        if (strike == 0) revert StrikeError(strike);
        if (delLiquidity <= MIN_LIQUIDITY) revert MinLiquidityError(delLiquidity);
        if (quotePerLp > PRECISION / factor0 || quotePerLp == 0) revert quotePerLpError(quotePerLp);
        if (adminFee > Units.PERCENTAGE || adminFee < 9000) revert SwapFeeError(swapFee);

        Calibration memory cal = Calibration({
            strike: strike,
            sigma: sigma,
            maturity: maturity,
            lastTimestamp: _blockTimestamp(),
            adminFee: adminFee
        });

        if (cal.lastTimestamp > cal.maturity) revert PoolExpiredError();
        uint32 tau = cal.maturity - cal.lastTimestamp; // time until expiry
        Reserve.Data storage reserve = reserves[poolId];
        delBase = CoveredCall.computeDeltaLYIn(
            0, 
            reserveBase, 
            reserveQuote, 
            totalliquidity, 
            swapFee, 
            strike, 
            sigma, 
            tau
        );
        delQuote = (reserveQuote * totalLiquidity) / PRECISION;
        delBase = (reserveBase * totalLiquidity) / PRECISION;
        if (delQuote == 0 || delBase == 0) revert CalibrationError(delQuote, delBase);

        calibrations[poolId] = cal; // state update
        uint256 amount = delLiquidity - MIN_LIQUIDITY;
        liquidity[msg.sender][poolId] += amount; // burn min liquidity, at cost of msg.sender
        reserves[poolId].allocate(delQuote, delBase, delLiquidity, cal.lastTimestamp); // state update

        (uint256 balQuote, uint256 balBase) = (balanceQuote(), balanceBase());
        ICreateCallback(msg.sender).createCallback(delQuote, delBase, data);
        checkQuoteBalance(balQuote + delQuote);
        checkBaseBalance(balBase + delBase);

        emit Create(msg.sender, cal.strike, cal.sigma, cal.maturity, cal.adminFee, delQuote, delBase, amount);
    }


    /// @inheritdoc IMarketActions
    function deposit(
        address recipient,
        uint256 delQuote,
        uint256 delBase,
        bytes calldata data
    ) external override lock {
        if (delQuote == 0 && delBase == 0) revert ZeroDeltasError();
        deposit(recipient, delQuote, delBase); // state update

        uint256 balQuote;
        uint256 balBase;
        if (delQuote != 0) balQuote = balanceQuote();
        if (delBase != 0) balBase = balanceBase();
        IDepositCallback(msg.sender).depositCallback(delQuote, delBase, data); // agnostic payment
        if (delQuote != 0) checkQuoteBalance(balQuote + delQuote);
        if (delBase != 0) checkBaseBalance(balBase + delBase);
        emit Deposit(msg.sender, recipient, delQuote, delBase);
    }

    /// @inheritdoc IMarketActions
    function withdraw(
        address recipient,
        uint256 delQuote,
        uint256 delBase
    ) external override lock {
        if (delQuote == 0 && delBase == 0) revert ZeroDeltasError();
        withdraw(recipient, delQuote, delBase); // state update
        if (delQuote != 0) IERC20(quote).safeTransfer(recipient, delQuote);
        if (delBase != 0) IERC20(base).safeTransfer(recipient, delBase);
        emit Withdraw(msg.sender, recipient, delQuote, delBase);
    }

    // ===== Liquidity =====

    /// @inheritdoc IMarketActions
    function allocate(
        bytes32 poolId,
        address recipient,
        uint256 delQuote,
        uint256 delBase,
        bytes calldata data
    ) external override lock returns (uint256 delLiquidity) {
        if (delQuote == 0 || delBase == 0) revert ZeroDeltasError();
        Reserve.Data storage reserve = reserves[poolId];
        if (reserve.blockTimestamp == 0) revert UninitializedError();
        uint32 timestamp = _blockTimestamp();

        uint256 liquidity0 = (delQuote * reserve.liquidity) / uint256(reserve.reserveQuote);
        uint256 liquidity1 = (delBase * reserve.liquidity) / uint256(reserve.reserveBase);
        delLiquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        if (delLiquidity == 0) revert ZeroLiquidityError();

        liquidity[recipient][poolId] += delLiquidity; // increase position liquidity
        reserve.allocate(delQuote, delBase, delLiquidity, timestamp); // increase reserves and liquidity

        emit Allocate(msg.sender, recipient, poolId, delQuote, delBase, delLiquidity);
    }

    /// @inheritdoc IMarketActions
    function remove(bytes32 poolId, uint256 delLiquidity)
        external
        override
        lock
        returns (uint256 delQuote, uint256 delBase)
    {
        if (delLiquidity == 0) revert ZeroLiquidityError();
        Reserve.Data storage reserve = reserves[poolId];
        if (reserve.blockTimestamp == 0) revert UninitializedError();
        (delQuote, delBase) = reserve.getAmounts(delLiquidity);

        liquidity[msg.sender][poolId] -= delLiquidity; // state update
        reserve.remove(delQuote, delBase, delLiquidity, _blockTimestamp());
        deposit(msg.sender, delQuote, delBase);

        emit Remove(msg.sender, poolId, delQuote, delBase, delLiquidity);
    }

    struct SwapDetails {
        address recipient;
        bool quoteForBase;
        uint32 timestamp;
        bytes32 poolId;
        uint256 deltaIn;
        uint256 deltaOut;
    }

    /// @inheritdoc IMarketActions
    function swap(
        address recipient,
        bytes32 poolId,
        bool quoteForBase,
        uint256 deltaIn,
        uint256 deltaOut,
        bytes calldata data
    ) external override lock {
        if (deltaIn == 0) revert DeltaInError();
        if (deltaOut == 0) revert DeltaOutError();

        SwapDetails memory details = SwapDetails({
            recipient: recipient,
            poolId: poolId,
            deltaIn: deltaIn,
            deltaOut: deltaOut,
            quoteForBase: quoteForBase,
            timestamp: _blockTimestamp()
        });

        uint32 lastTimestamp = _updateLastTimestamp(details.poolId); // updates lastTimestamp of `poolId`
        if (details.timestamp > lastTimestamp + BUFFER) revert PoolExpiredError(); // 120s buffer to allow final swaps
        int128 invariantX64 = invariantOf(details.poolId); // stored in memory to perform the invariant check

        {
            // swap scope, avoids stack too deep errors
            Calibration memory cal = calibrations[details.poolId];
            Reserve.Data storage reserve = reserves[details.poolId];
            uint32 tau = cal.maturity - cal.lastTimestamp;
            uint256 deltaInWithFee = (details.deltaIn * cal.adminFee) / Units.PERCENTAGE; // amount * (1 - fee %)

            uint256 adjustedQuote;
            uint256 adjustedBase;
            if (details.quoteForBase) {
                adjustedQuote = uint256(reserve.reserveQuote) + deltaInWithFee;
                adjustedBase = uint256(reserve.reserveBase) - deltaOut;
            } else {
                adjustedQuote = uint256(reserve.reserveQuote) - deltaOut;
                adjustedBase = uint256(reserve.reserveBase) + deltaInWithFee;
            }
            adjustedQuote = (adjustedQuote * PRECISION) / reserve.liquidity;
            adjustedBase = (adjustedBase * PRECISION) / reserve.liquidity;

            int128 invariantAfter = CoveredCall.calcInvariant(
                scaleFactorQuote,
                scaleFactorBase,
                adjustedQuote,
                adjustedBase,
                cal.strike,
                cal.sigma,
                tau
            );

            if (invariantX64 > invariantAfter) revert InvariantError(invariantX64, invariantAfter);
            reserve.swap(details.quoteForBase, details.deltaIn, details.deltaOut, details.timestamp); // state update
        }

        if (details.quoteForBase) {
            if (details.toMargin) {
                deposit(details.recipient, 0, details.deltaOut);
            } else {
                IERC20(base).safeTransfer(details.recipient, details.deltaOut); // optimistic transfer out
            }

            if (details.fromMargin) {
                withdraw(msg.sender, details.deltaIn, 0); // pay for swap
            } else {
                uint256 balQuote = balanceQuote();
                ISwapCallback(msg.sender).swapCallback(details.deltaIn, 0, data); // agnostic transfer in
                checkQuoteBalance(balQuote + details.deltaIn);
            }
        } else {
            if (details.toMargin) {
                deposit(details.recipient, details.deltaOut, 0);
            } else {
                IERC20(quote).safeTransfer(details.recipient, details.deltaOut); // optimistic transfer out
            }
        }

        emit Swap(
            msg.sender,
            details.recipient,
            details.poolId,
            details.quoteForBase,
            details.deltaIn,
            details.deltaOut
        );
    }

    // ===== View =====

    /// @inheritdoc IMarketView
    function invariantOf(bytes32 poolId) public view override returns (int128 invariant) {
        Calibration memory cal = calibrations[poolId];
        uint32 tau = cal.maturity - cal.lastTimestamp; // cal maturity can never be less than lastTimestamp
        (uint256 quotePerLiquidity, uint256 basePerLiquidity) = reserves[poolId].getAmounts(PRECISION); // 1e18 liquidity
        invariant = ReplicationMath.calcInvariant(
            scaleFactorQuote,
            scaleFactorBase,
            quotePerLiquidity,
            basePerLiquidity,
            cal.strike,
            cal.sigma,
            tau
        );
    }
}
