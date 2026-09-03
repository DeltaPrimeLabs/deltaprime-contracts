// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "./DeploymentConstants.sol";
import "./DiamondStorageLib.sol";
import "../interfaces/ITokenManager.sol";
import {IGmxReader} from "../interfaces/gmx-v2/IGmxReader.sol";
import "./DiamondMethodsAccess.sol";
import {GmxGlvUnifiedHelper} from "./GmxGlvUnifiedHelper.sol";
import {GmxBenchmarkMath} from "./GmxBenchmarkMath.sol";

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../interfaces/gmx-v2/EventUtils.sol";
import "../interfaces/gmx-v2/IDepositUtils.sol";
import "../interfaces/gmx-v2/IWithdrawalUtils.sol";
import "../interfaces/gmx-v2/IGmxV2Router.sol";
import "../interfaces/gmx-v2/BasicMulticall.sol";

abstract contract GmxV2FeesHelper is DiamondMethodsAccess, GmxGlvUnifiedHelper {

    /// @dev 10% performance fee (1e17 of 1e18). The shared fee math lives in
    /// `GmxBenchmarkMath.deductibleFeeInGmTokens`; this constant is still read by
    /// `_processFeeCollection` / `_getGmAnnualisedPerformance`, which apply the same
    /// percentage to their own perf-USD calculations.
    uint256 public constant FEE_PERCENTAGE = 1e17;

    


    struct GmxPositionDetails {
        uint256 gmTokenPriceUsd; // in 1e8 format
        uint256 underlyingLongTokenAmount; // in longTokenDecimals format
        uint256 underlyingShortTokenAmount; // in shortTokenDecimals format
        uint256 longTokenPriceUsd; // in 1e8 format
        uint256 shortTokenPriceUsd; // in 1e8 format
        uint256 benchmarkTimeStamp; // timestamp of when the benchmark was set
        address longTokenAddress;
        address shortTokenAddress;
    }

    

    struct FeeCalculationData {
        uint256 currentBalance;
        uint256 currentValueUsd;
        uint256 longTokenValueUsd;
        uint256 shortTokenValueUsd;
        uint256 gmPerformanceUsd;
    }

    struct TokenSupplyData {
        uint256 totalGmSupply;
        uint256 totalLongTokens;
        uint256 totalShortTokens;
    }

    

    // EVENTS
    event BenchmarkCreated(
        address indexed gmMarket,
        uint256 indexed benchmarkValueUsd,
        uint256 longTokenAmount,
        uint256 shortTokenAmount,
        address longTokenAddress,
        address shortTokenAddress,
        uint256 gmTokenPriceUsd,
        uint256 longTokenPriceUsd,
        uint256 shortTokenPriceUsd,
        uint256 timestamp
    );

    event BenchmarkUpdated(
        address indexed gmMarket,
        uint256 indexed newBenchmarkValueUsd,
        uint256 newLongTokenAmount,
        uint256 newShortTokenAmount,
        uint256 gmTokenPriceUsd,
        uint256 longTokenPriceUsd,
        uint256 shortTokenPriceUsd,
        uint256 timestamp
    );

    event FeesCollected(
        address indexed gmMarket,
        uint256 indexed feeInGmTokens,
        uint256 performanceUsd,
        uint256 currentBalance,
        uint256 timestamp
    );

    event BenchmarkInitiated(
        address indexed gmMarket,
        address indexed initiator,
        bool isPlusMarket,
        uint256 timestamp
    );

    // Unified function that replaces both _getGmxTokenPricesAndAddresses and _getGmxPlusTokenPricesAndAddresses
    function _getUnifiedGmxTokenPricesAndAddresses(address gmMarket) internal view returns (UnifiedGmxTokenPricesAndAddresses memory) {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        bool isPlusMarket = tokenManager.isGmxPlusMarket(gmMarket);
        
        address gmxReader = DeploymentConstants.getGmxReaderAddress();
        address dataStore = DeploymentConstants.getGmxDataStoreAddress();
        IGmxReader.MarketProps memory marketProps = IGmxReader(gmxReader).getMarket(dataStore, gmMarket);
        
        address longToken;
        address shortToken;
        
        if (isPlusMarket) {
            // Plus markets: both long and short are the same token
            longToken = marketProps.longToken;
            shortToken = longToken; // Same token for both
            if (longToken == address(0)) revert GmxPlusMarketTokenNotFound();
        } else {
            // Regular GM markets: different long and short tokens
            longToken = marketProps.longToken;
            shortToken = marketProps.shortToken;
            if (longToken == address(0) || shortToken == address(0)) revert GmxMarketTokensNotFound();
        }
        
        // Get prices - only request unique symbols to avoid duplicate price requests for Plus markets
        bytes32[] memory symbols;
        if (isPlusMarket) {
            symbols = new bytes32[](2); // Only need GM token and the single underlying token
            symbols[0] = tokenManager.tokenAddressToSymbol(gmMarket);
            symbols[1] = tokenManager.tokenAddressToSymbol(longToken);
        } else {
            symbols = new bytes32[](3); // Need GM token, long token, and short token
            symbols[0] = tokenManager.tokenAddressToSymbol(gmMarket);
            symbols[1] = tokenManager.tokenAddressToSymbol(longToken);
            symbols[2] = tokenManager.tokenAddressToSymbol(shortToken);
        }
        
        uint256[] memory prices = getPrices(symbols);
        
        return UnifiedGmxTokenPricesAndAddresses({
            gmTokenPrice: prices[0],
            longTokenPrice: prices[1],
            shortTokenPrice: isPlusMarket ? 0 : prices[2], // 0 for Plus markets to avoid double counting
            longToken: longToken,
            shortToken: shortToken,
            isPlusMarket: isPlusMarket
        });
    }


    // Backward compatibility function that returns only prices
    function _getGmxTokenPrices(address gmMarket) internal view returns (GmxTokenPrices memory) {
        UnifiedGmxTokenPricesAndAddresses memory unified = _getUnifiedGmxTokenPricesAndAddresses(gmMarket);
        return GmxTokenPrices({
            gmTokenPrice: unified.gmTokenPrice,
            longTokenPrice: unified.longTokenPrice,
            shortTokenPrice: unified.shortTokenPrice
        });
    }

    function _getUnderlyingTokenDetails(address gmMarket, GmxTokenPrices memory gmTokenPrices, address longToken, address shortToken) internal view returns (uint256 longTokenAmount, uint256 shortTokenAmount) {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();

        uint256 totalGmSupply = IERC20Metadata(gmMarket).totalSupply();
        uint256 gmTokenAmount = IERC20Metadata(gmMarket).balanceOf(address(this));

        // The GM market contract is the owner of the underlying tokens
        uint256 totalLongTokens = IERC20Metadata(longToken).balanceOf(gmMarket);
        uint256 totalShortTokens;
        if(tokenManager.isGmxPlusMarket(gmMarket)) {
            ///@dev totalShortTokens set to zero for plus markets, which snowballs into shortTokenAmount being zero.
            ///@dev less code duplication this way: second addition in totalUnderlyingWorth calculation will also be zero
            totalShortTokens = 0;
        } else {
            totalShortTokens = IERC20Metadata(shortToken).balanceOf(gmMarket);
        }

        uint256 totalGmWorth = totalGmSupply * gmTokenPrices.gmTokenPrice / 1e8;
        uint256 totalUnderlyingWorth = totalLongTokens * gmTokenPrices.longTokenPrice / 1e8 * 1e18 / 10 ** IERC20Metadata(longToken).decimals()
            + totalShortTokens * gmTokenPrices.shortTokenPrice / 1e8 * 1e18 / 10 ** IERC20Metadata(shortToken).decimals();

        uint256 ratio = totalGmWorth * 1e18 / totalUnderlyingWorth;

        // Calculate this position's pro-rata share of the underlying tokens
        longTokenAmount = (ratio * gmTokenAmount * totalLongTokens) / (1e18 * totalGmSupply);
        shortTokenAmount = (ratio * gmTokenAmount * totalShortTokens) / (1e18 * totalGmSupply);
    }

    /**
     * @notice Additively extend an existing benchmark with a new GM-token contribution
     *         made through `AssetsOperationsFacet.fund()`.
     * @dev Unlike `_createOrUpdatePositionBenchmark`, this does NOT recompute the benchmark
     *      from the current total balance. Instead it preserves the existing cost basis and
     *      layers on the newly-funded amount at its current market value.
     *
     *      Recomputing from the total balance would let a user holding a GM position with
     *      unrealized gains call fund() with a dust amount of GM tokens and have the
     *      benchmark rewritten to `totalBalance * currentPrice`, erasing the prior cost
     *      basis and resetting performance fee accrual to zero.
     *
     * @param gmMarket  The GM market whose benchmark is being updated.
     * @param positionDetails  Underlying token deltas attributable *only* to the newly-funded
     *        amount, current prices, and token addresses. Underlying amounts MUST be computed
     *        from the funded GM amount (not the total balance).
     * @param fundedGmAmount  The GM-token amount just transferred into the PrimeAccount.
     */
    function _addToBenchmarkFromFunding(
        address gmMarket,
        GmxPositionDetails memory positionDetails,
        uint256 fundedGmAmount
    ) internal {
        // Nothing funded, nothing to benchmark. fund() clamps its amount to the caller's balance
        // and does not reject zero, so without this a fund() of a token the caller holds none of
        // would write a benchmark with zero underlying legs. _calculateFeeData derives the cost
        // basis from those legs, and _sweepFees only early-returns on a MISSING benchmark, not a
        // zero-valued one — so an account already holding that GM from another route would have
        // its entire position read as appreciation and charged the performance fee on principal.
        // Leaving the benchmark absent is both correct and safe: _sweepFees skips it, and the
        // next real fund or GMX deposit creates a properly sized basis.
        if (fundedGmAmount == 0) {
            return;
        }

        DiamondStorageLib.GmxPositionBenchmark memory existing = DiamondStorageLib.getGmxPositionBenchmark(gmMarket);
        uint256 addedValueUsd = (fundedGmAmount * positionDetails.gmTokenPriceUsd) / 1e8;

        if (!existing.exists) {
            // First-time benchmark creation for this market. This branch only became reachable
            // for GM markets once fund() stopped reverting with Panic(0x12) on a missing
            // benchmark, and its original assumption — "the funded amount IS the entire
            // position" — does not survive that. GM market tokens are ordinary ERC20s and benchmarks are never deleted
            // (setGmxPositionBenchmark is the only writer), so `!exists` means "never tracked",
            // which includes a position that arrived by direct transfer. Sizing the first
            // benchmark from the funded amount alone would leave the pre-existing balance
            // untracked, and _calculateFeeData would then read almost the whole untracked
            // position as appreciation and charge the performance fee on principal.
            //
            // Size from the account's actual post-transfer balance instead, scaling the
            // underlying legs by the same ratio so the benchmark stays internally consistent.
            uint256 gmBalance = IERC20Metadata(gmMarket).balanceOf(address(this));
            uint256 longAmount = positionDetails.underlyingLongTokenAmount;
            uint256 shortAmount = positionDetails.underlyingShortTokenAmount;
            if (gmBalance > fundedGmAmount) {
                addedValueUsd = (gmBalance * positionDetails.gmTokenPriceUsd) / 1e8;
                longAmount = (longAmount * gmBalance) / fundedGmAmount;
                shortAmount = (shortAmount * gmBalance) / fundedGmAmount;
            }

            DiamondStorageLib.setGmxPositionBenchmark(
                DiamondStorageLib.GmxPositionBenchmarkParams({
                    market: gmMarket,
                    benchmarkValueUsd: addedValueUsd,
                    longTokenAmount: longAmount,
                    shortTokenAmount: shortAmount,
                    longToken: positionDetails.longTokenAddress,
                    shortToken: positionDetails.shortTokenAddress,
                    timestamp: block.timestamp,
                    gmTokenPriceUsd: positionDetails.gmTokenPriceUsd,
                    longTokenPriceUsd: positionDetails.longTokenPriceUsd,
                    shortTokenPriceUsd: positionDetails.shortTokenPriceUsd
                })
            );
            emit BenchmarkCreated(
                gmMarket,
                addedValueUsd,
                longAmount,
                shortAmount,
                positionDetails.longTokenAddress,
                positionDetails.shortTokenAddress,
                positionDetails.gmTokenPriceUsd,
                positionDetails.longTokenPriceUsd,
                positionDetails.shortTokenPriceUsd,
                block.timestamp
            );
            return;
        }

        // Preserve existing cost basis. Total benchmark = prior benchmark + funded delta at current price.
        DiamondStorageLib.setGmxPositionBenchmark(
            DiamondStorageLib.GmxPositionBenchmarkParams({
                market: gmMarket,
                benchmarkValueUsd: existing.benchmarkValueUsd + addedValueUsd,
                longTokenAmount: existing.underlyingLongTokenAmount + positionDetails.underlyingLongTokenAmount,
                shortTokenAmount: existing.underlyingShortTokenAmount + positionDetails.underlyingShortTokenAmount,
                longToken: positionDetails.longTokenAddress,
                shortToken: positionDetails.shortTokenAddress,
                timestamp: block.timestamp,
                gmTokenPriceUsd: positionDetails.gmTokenPriceUsd,
                longTokenPriceUsd: positionDetails.longTokenPriceUsd,
                shortTokenPriceUsd: positionDetails.shortTokenPriceUsd
            })
        );
        emit BenchmarkUpdated(
            gmMarket,
            existing.benchmarkValueUsd + addedValueUsd,
            existing.underlyingLongTokenAmount + positionDetails.underlyingLongTokenAmount,
            existing.underlyingShortTokenAmount + positionDetails.underlyingShortTokenAmount,
            positionDetails.gmTokenPriceUsd,
            positionDetails.longTokenPriceUsd,
            positionDetails.shortTokenPriceUsd,
            block.timestamp
        );
    }

    /**
     * @notice Overwrites the benchmark for `gmMarket` to the PA's current balance valued at
     *         the supplied prices. Used by:
     *           - `GmxV2Facet._updatePositionBenchmark` / `GmxV2PlusFacet._updatePositionBenchmark`
     *             (standalone sweepFeesAndUpdateBenchMark* paths + GMX
     *             afterDepositExecution/afterWithdrawalExecution keeper callbacks);
     *           - `GlvFacet._updateGlvPositionBenchmark` (GLV equivalent);
     *           - `_updateBenchmark` (WithdrawalIntentFacet post-execution path).
     *
     * @dev    Overwrite semantics are safe on these paths — they cannot be used to reset a
     *         benchmark to current price and bypass the fee — because of the ordering of
     *         `_deposit` / `_withdraw`:
     *           1. The entrypoint calls `_sweepFees(...)` BEFORE the `BasicMulticall` that
     *              triggers GMX execution.
     *           2. The GMX router accepts the request; the GMX keeper executes it some
     *              blocks later.
     *           3. The keeper-triggered `afterDepositExecution` / `afterWithdrawalExecution`
     *              callback fires and overwrites the benchmark here.
     *         The fee is already swept in step 1, before the overwrite in step 3. Same
     *         shape for GmxV2Plus and Glv. The additive (non-overwrite) update is only
     *         needed on the `fund()` path, which has no preceding sweep.
     */
    function _createOrUpdatePositionBenchmark(address gmMarket, GmxPositionDetails memory positionDetails) internal {
        uint256 currentBalance = IERC20(gmMarket).balanceOf(address(this));
        uint256 benchmarkValueUsd = (currentBalance * positionDetails.gmTokenPriceUsd) / 1e8;

        DiamondStorageLib.GmxPositionBenchmark memory existingBenchmark = DiamondStorageLib.getGmxPositionBenchmark(gmMarket);
        bool isCreation = !existingBenchmark.exists;
        
        DiamondStorageLib.setGmxPositionBenchmark(
            DiamondStorageLib.GmxPositionBenchmarkParams({
                market: gmMarket,
                benchmarkValueUsd: benchmarkValueUsd,
                longTokenAmount: positionDetails.underlyingLongTokenAmount,
                shortTokenAmount: positionDetails.underlyingShortTokenAmount,
                longToken: positionDetails.longTokenAddress,
                shortToken: positionDetails.shortTokenAddress,
                timestamp: block.timestamp,
                gmTokenPriceUsd: positionDetails.gmTokenPriceUsd,
                longTokenPriceUsd: positionDetails.longTokenPriceUsd,
                shortTokenPriceUsd: positionDetails.shortTokenPriceUsd
            })
        );

        if (isCreation) {
            emit BenchmarkCreated(
                gmMarket,
                benchmarkValueUsd,
                positionDetails.underlyingLongTokenAmount,
                positionDetails.underlyingShortTokenAmount,
                positionDetails.longTokenAddress,
                positionDetails.shortTokenAddress,
                positionDetails.gmTokenPriceUsd,
                positionDetails.longTokenPriceUsd,
                positionDetails.shortTokenPriceUsd,
                block.timestamp
            );
        } else {
            emit BenchmarkUpdated(
                gmMarket,
                benchmarkValueUsd,
                positionDetails.underlyingLongTokenAmount,
                positionDetails.underlyingShortTokenAmount,
                positionDetails.gmTokenPriceUsd,
                positionDetails.longTokenPriceUsd,
                positionDetails.shortTokenPriceUsd,
                block.timestamp
            );
        }
    }

    function _updateBenchmark(
        address gmMarket,
        uint256 gmTokenPriceUsd,
        uint256 longTokenPrice,
        uint256 shortTokenPrice
    ) internal {
        DiamondStorageLib.GmxPositionBenchmark memory benchmark = DiamondStorageLib.getGmxPositionBenchmark(gmMarket);

        // Check for zero supply to avoid division by zero
        if (IERC20(gmMarket).totalSupply() == 0) {
            return;
        }

        uint256 currentBalance = IERC20(gmMarket).balanceOf(address(this));
        uint256 benchmarkValueUsd = (currentBalance * gmTokenPriceUsd) / 1e8; // currentBalance in 1e18 format

        // Use the premium-scaled pro-rata formula (`_getUnderlyingTokenDetails`) so the
        // benchmark matches the invariant `underlyingAmt * underlyingPrice ==
        // currentBalance * gmPrice` — the same form `_updatePositionBenchmark` and
        // `_updateGlvPositionBenchmark` already use. A strict pro-rata would leave
        // `performance > 0` immediately after this runs, so the next sweep would re-charge
        // a fee on the GM premium. Only caller is
        // `WithdrawalIntentFacet.executeWithdrawalIntent` (GMX markets only).
        (uint256 newUnderlyingLongTokenAmount, uint256 newUnderlyingShortTokenAmount) =
            _getUnderlyingTokenDetails(
                gmMarket,
                GmxTokenPrices({
                    gmTokenPrice: gmTokenPriceUsd,
                    longTokenPrice: longTokenPrice,
                    shortTokenPrice: shortTokenPrice
                }),
                benchmark.longTokenAddress,
                benchmark.shortTokenAddress
            );

        DiamondStorageLib.setGmxPositionBenchmark(
            DiamondStorageLib.GmxPositionBenchmarkParams({
                market: gmMarket,
                benchmarkValueUsd: benchmarkValueUsd,
                longTokenAmount: newUnderlyingLongTokenAmount,
                shortTokenAmount: newUnderlyingShortTokenAmount,
                longToken: benchmark.longTokenAddress,
                shortToken: benchmark.shortTokenAddress,
                timestamp: block.timestamp,
                gmTokenPriceUsd: gmTokenPriceUsd,
                longTokenPriceUsd: longTokenPrice,
                shortTokenPriceUsd: shortTokenPrice
            })
        );

        emit BenchmarkUpdated(
            gmMarket,
            benchmarkValueUsd,
            newUnderlyingLongTokenAmount,
            newUnderlyingShortTokenAmount,
            gmTokenPriceUsd,
            longTokenPrice,
            shortTokenPrice,
            block.timestamp
        );
    }

    /**
     * @dev Sweeps accumulated fees from GM token position and transfers them to treasury
     * @param gmMarket The GM market address
     * @param tokenPrices GmxTokenPrices struct containing current prices of GM, long, and short tokens in USD (1e8 format)
     
     * @return feeInGmTokens The amount of GM tokens collected as fees
     */
    function _sweepFees(
        address gmMarket, 
        GmxTokenPrices memory tokenPrices
    ) internal returns (uint256 feeInGmTokens) {
        DiamondStorageLib.GmxPositionBenchmark memory benchmark = DiamondStorageLib.getGmxPositionBenchmark(gmMarket);
        
        if (!benchmark.exists) {
            return 0;
        }

        if (tokenPrices.gmTokenPrice == 0 || tokenPrices.longTokenPrice == 0) { ///@dev shortTokenPrice can be 0 for GMX Plus markets
            return 0; 
        }
        
        FeeCalculationData memory feeData = _calculateFeeData(
            gmMarket, 
            tokenPrices.gmTokenPrice, 
            tokenPrices.longTokenPrice, 
            tokenPrices.shortTokenPrice, 
            benchmark
        );
        
        if (feeData.currentValueUsd > feeData.longTokenValueUsd + feeData.shortTokenValueUsd) {
            feeInGmTokens = _processFeeCollection(gmMarket, tokenPrices.gmTokenPrice, feeData, benchmark);
        }
    }

    function _getGmAnnualisedPerformance(address gmMarket, uint256 gmTokenPriceUsd, uint256 longTokenPriceUsd, uint256 shortTokenPriceUsd) internal view returns (uint256 gmAnnualPerformance) {
        DiamondStorageLib.GmxPositionBenchmark memory benchmark = DiamondStorageLib.getGmxPositionBenchmark(gmMarket);

        if (!benchmark.exists || benchmark.benchmarkTimeStamp == 0 || block.timestamp <= benchmark.benchmarkTimeStamp) {
            return 0;
        }

        // Current balance and its USD value
        uint256 currentBalance = IERC20(gmMarket).balanceOf(address(this));
        uint256 currentValueUsd = (currentBalance * gmTokenPriceUsd) / 1e8;

        // Calculate USD values with proper decimal handling
        uint256 longTokenValueUsd = _calculateTokenValueUsd(
            benchmark.underlyingLongTokenAmount, 
            longTokenPriceUsd, 
            benchmark.longTokenAddress
        );
        uint256 shortTokenValueUsd = _calculateTokenValueUsd(
            benchmark.underlyingShortTokenAmount, 
            shortTokenPriceUsd, 
            benchmark.shortTokenAddress
        );

        uint256 totalUnderlyingValueUsd = longTokenValueUsd + shortTokenValueUsd;

        // Check for negative performance (no underflow)
        if (currentValueUsd <= totalUnderlyingValueUsd) {
            return 0;
        }

        uint256 gmPerformanceUsd = currentValueUsd - totalUnderlyingValueUsd;
        uint256 timeElapsed = block.timestamp - benchmark.benchmarkTimeStamp;

        // Avoid division precision loss by scaling up first
        // Annual performance = (performance * 365 days) / timeElapsed
        // Annual performance %, scaled to 1e18 = (performance * 1e18 * 365 days) / timeElapsed / currentValue
        gmAnnualPerformance = (gmPerformanceUsd * 1e18 * 365 days) / timeElapsed / currentValueUsd;
    }

    /// @notice Returns the deductible GMX V2 performance fee for the calling facet's GM
    ///         position, denominated in GM tokens. Delegates to `GmxBenchmarkMath` so this
    ///         entrypoint and `SolvencyFacetProd`'s solvency-side fee deduction share a
    ///         single source of truth.
    function _getDeductibleFeesInGmTokens(address gmMarket, uint256 gmTokenPriceUsd, uint256 longTokenPriceUsd, uint256 shortTokenPriceUsd) internal view returns (uint256 feeInGmTokens) {
        feeInGmTokens = GmxBenchmarkMath.deductibleFeeInGmTokens(
            gmMarket,
            gmTokenPriceUsd,
            longTokenPriceUsd,
            shortTokenPriceUsd
        );
    }

    /**
     * @dev Calculate token value in USD with proper decimal handling
     * @param tokenAmount The token amount (with original token decimals)
     * @param tokenPriceUsd The token price in USD (1e8 format)
     * @param tokenAddress The token contract address
     * @return valueUsd The USD value with 18 decimals
     */
    function _calculateTokenValueUsd(
        uint256 tokenAmount, 
        uint256 tokenPriceUsd, 
        address tokenAddress
    ) private view returns (uint256 valueUsd) {
        if (tokenAmount == 0 || tokenPriceUsd == 0) {
            return 0;
        }

        uint8 decimals = IERC20Metadata(tokenAddress).decimals();
        
        // tokenAmount is stored in native token decimals, but USD calculations 
        // work with 18 decimals, so we need to normalize to 18 decimals
        if (decimals != 18) {
            if (decimals < 18) {
                // Scale UP for tokens with fewer decimals
                tokenAmount = tokenAmount * (10 ** (18 - decimals));
            } else {
                // Scale DOWN for tokens with more decimals
                tokenAmount = tokenAmount / (10 ** (decimals - 18));
            }
        }

        valueUsd = (tokenAmount * tokenPriceUsd) / 1e8;
    }

    function _calculateFeeData(
        address gmMarket,
        uint256 gmTokenPriceUsd,
        uint256 longTokenPriceUsd,
        uint256 shortTokenPriceUsd,
        DiamondStorageLib.GmxPositionBenchmark memory benchmark
    ) private view returns (FeeCalculationData memory feeData) {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        
        feeData.currentBalance = IERC20(gmMarket).balanceOf(address(this));
        feeData.currentValueUsd = (feeData.currentBalance * gmTokenPriceUsd) / 1e8;
        
        // Calculate USD values with proper decimal handling
        feeData.longTokenValueUsd = _calculateTokenValueUsd(
            benchmark.underlyingLongTokenAmount, 
            longTokenPriceUsd, 
            benchmark.longTokenAddress
        );
        feeData.shortTokenValueUsd = _calculateTokenValueUsd(
            benchmark.underlyingShortTokenAmount, 
            shortTokenPriceUsd, 
            benchmark.shortTokenAddress
        );
        
        uint256 totalUnderlyingValueUsd = feeData.longTokenValueUsd + feeData.shortTokenValueUsd;

        // Check for negative performance (no underflow)
        if (feeData.currentValueUsd > totalUnderlyingValueUsd) {
            feeData.gmPerformanceUsd = feeData.currentValueUsd - totalUnderlyingValueUsd;
        } else {
            feeData.gmPerformanceUsd = 0;
        }
    }

    function _processFeeCollection(
        address gmMarket,
        uint256 gmTokenPriceUsd,
        FeeCalculationData memory feeData,
        DiamondStorageLib.GmxPositionBenchmark memory benchmark
    ) private returns (uint256 feeInGmTokens) {
        uint256 gmPerformanceFeeUsd = (feeData.gmPerformanceUsd * FEE_PERCENTAGE) / 1e18;

        if (gmPerformanceFeeUsd == 0) {
            return 0;
        }

        feeInGmTokens = (gmPerformanceFeeUsd * 1e8) / gmTokenPriceUsd;

        // Only process fees if amount is >= 3 wei (to allow proper 1/3, 2/3 split)
        if (feeInGmTokens >= 3 && feeInGmTokens <= feeData.currentBalance) {
            uint256 stabilityPoolFee = feeInGmTokens / 3;
            uint256 treasuryFee = feeInGmTokens - stabilityPoolFee;

            IERC20(gmMarket).transfer(DeploymentConstants.getStabilityPoolAddress(), stabilityPoolFee);
            IERC20(gmMarket).transfer(DeploymentConstants.getTreasuryAddress(), treasuryFee);

            emit FeesCollected(
                gmMarket,
                feeInGmTokens,
                feeData.gmPerformanceUsd,
                feeData.currentBalance,
                block.timestamp
            );

            // The benchmark must be scaled proportionally to the GM tokens just swept out,
            // otherwise the next fee calc reports the same gain and charges the fee again.
            // Every `_sweepFees` caller EXCEPT `AssetsOperationsFacet.fund()` immediately
            // overwrites the benchmark (`_updatePositionBenchmark` /
            // `_updateGlvPositionBenchmark` / GMX callback), making in-place scaling here a
            // no-op for them. The additive fund() flow is the only one that doesn't
            // overwrite, so it performs the scaling itself after `_sweepFees` returns —
            // kept out of this private function to keep inheritors under the 24 KB limit.
        } else {
            // If feeInGmTokens < 3, we can't split properly, so return 0
            feeInGmTokens = 0;
        }
    }
}