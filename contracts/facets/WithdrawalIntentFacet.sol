// SPDX-License-Identifier: BUSL-1.1
// Last deployed from commit:
pragma solidity 0.8.17;

import "../ReentrancyGuardKeccak.sol";
import "../interfaces/facets/IWithdrawalIntentFacet.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@uniswap/lib/contracts/libraries/TransferHelper.sol";
import {DiamondStorageLib} from "../lib/DiamondStorageLib.sol";
import {LeverageTierLib} from "../lib/LeverageTierLib.sol";
import "../lib/GmxV2FeesHelper.sol";
import {GlvHelper} from "../lib/GlvHelper.sol";
import {IGmxReader} from "../interfaces/gmx-v2/IGmxReader.sol";
import {IGlvReader} from "../interfaces/gmx-v2/IGlvReader.sol";
import {ISmartLoanLiquidationFacet} from "../interfaces/facets/ISmartLoanLiquidationFacet.sol";


contract WithdrawalIntentFacet is IWithdrawalIntentFacet, ReentrancyGuardKeccak, GmxV2FeesHelper, GlvHelper {
    using TransferHelper for address;

    // for prime token burning
    address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    function createWithdrawalIntent(bytes32 _asset, uint256 _amount) external onlyOwner nonReentrant notInLiquidation {
        require(_amount > 0, "Amount must be greater than zero");

        IERC20Metadata token = getERC20TokenInstance(_asset, true);
        address tokenAddress = address(token);

        _removeExpiredIntents(tokenAddress);

        uint256 availableBalance = getAvailableBalance(_asset);
        if(_amount > availableBalance) {
            revert InsufficientAvailableBalance(_amount, availableBalance);
        }

        DiamondStorageLib.WithdrawalIntentsStorage storage wis = DiamondStorageLib.withdrawalIntentsStorage();
        uint256 actionableAt = block.timestamp + 24 hours;
        uint256 expiresAt = actionableAt + 48 hours;

        wis.intents[tokenAddress].push(DiamondStorageLib.WithdrawalIntent({
            amount: _amount,
            actionableAt: actionableAt,
            expiresAt: expiresAt
        }));

        emit WithdrawalIntentCreated(_asset, _amount, actionableAt, expiresAt);
    }

    function executeWithdrawalIntent(bytes32 _asset, uint256[] calldata intentIndices) external onlyOwner noBorrowInTheSameBlock nonReentrant canRepayDebtFully remainsSolvent notInLiquidation {
        IERC20Metadata token = getERC20TokenInstance(_asset, true);
        address tokenAddress = address(token);
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        GmxTokenPrices memory gmTokenPrices;
        UnifiedGmxTokenPricesAndAddresses memory glvPricesAndAddresses;
        uint256 finalAmount = validateWithdrawalIntents(tokenAddress, intentIndices);
        uint256 feesCollected = 0;
        
        if (tokenManager.isGmxMarketWhitelisted(tokenAddress) || tokenManager.isGlvTokenWhitelisted(tokenAddress)) {
            if(tokenManager.isGlvTokenWhitelisted(tokenAddress)) {
                glvPricesAndAddresses = _getUnifiedGlvTokenPricesAndAddresses(address(token));
                gmTokenPrices = GmxTokenPrices({
                gmTokenPrice: glvPricesAndAddresses.gmTokenPrice,
                longTokenPrice: glvPricesAndAddresses.longTokenPrice,
                shortTokenPrice: glvPricesAndAddresses.shortTokenPrice
                });
            } else  { // isGmxMarketWhitelisted
                gmTokenPrices = _getGmxTokenPrices(tokenAddress);    
            }
            feesCollected = _sweepFees(tokenAddress, gmTokenPrices);
            feesCollected = feesCollected > finalAmount ? finalAmount : feesCollected; // Ensure we don't deduct more than the final amount
            if (feesCollected > 0) {
                finalAmount -= feesCollected;
                emit FeesSweptDuringWithdrawalIntent(
                    tokenAddress,
                    feesCollected,
                    _asset,
                    finalAmount + feesCollected,
                    block.timestamp
                );
            }
        }

        require(finalAmount > 0, "No valid amount to withdraw");

        uint256 totalDebt = _getDebt();
        LeverageTierLib.updatePrimeDebtSnapshot(totalDebt);

        uint256 currentPrimeDebt = LeverageTierLib.getCurrentPrimeDebt(totalDebt);
        if(currentPrimeDebt > 0.05 * 1e18){
            _repayPrimeDebtToExecuteWithdrawalIntent(currentPrimeDebt, totalDebt, tokenManager);
             
        }

        DiamondStorageLib.WithdrawalIntentsStorage storage wis = DiamondStorageLib.withdrawalIntentsStorage();
        DiamondStorageLib.WithdrawalIntent[] storage intents = wis.intents[tokenAddress];

        // Remove intents from highest to lowest index
        for(uint256 i = intentIndices.length; i > 0; i--) {
            uint256 indexToRemove = intentIndices[i - 1];

            uint256 lastIndex = intents.length - 1;
            if (indexToRemove != lastIndex) {
                intents[indexToRemove] = intents[lastIndex];
            }
            intents.pop();
        }

        address(token).safeTransfer(msg.sender, finalAmount);

        if (tokenManager.isGmxMarketWhitelisted(tokenAddress)) {
            // OPTIMIZED: Use inherited method from GmxV2FeesHelper
            _updateBenchmark(tokenAddress, gmTokenPrices.gmTokenPrice, gmTokenPrices.longTokenPrice, gmTokenPrices.shortTokenPrice);
            
            emit BenchmarkUpdatedDuringWithdrawalIntent(
                tokenAddress,
                gmTokenPrices.gmTokenPrice,
                gmTokenPrices.longTokenPrice,
                gmTokenPrices.shortTokenPrice,
                block.timestamp
            );
        } else if (tokenManager.isGlvTokenWhitelisted(tokenAddress)) {
            // Mirror the GM path for GLV — refresh the position benchmark to the
            // post-withdrawal balance. Without it the (now smaller) GLV position keeps a stale,
            // oversized benchmark, suppressing measured performance and under-collecting
            // performance fees until the next keeper sweep. GlvFacet does this on its own paths.
            _updateGlvBenchmark(tokenAddress, glvPricesAndAddresses);

            emit BenchmarkUpdatedDuringWithdrawalIntent(
                tokenAddress,
                glvPricesAndAddresses.gmTokenPrice,
                glvPricesAndAddresses.longTokenPrice,
                glvPricesAndAddresses.shortTokenPrice,
                block.timestamp
            );
        }

        // Update exposure only if not PRIME token
        if(_asset == bytes32("PRIME")) {
            tokenManager.updateUserExposure(address(this), tokenAddress);
        } else {
            _syncExposure(tokenManager, tokenAddress);
        }

        emit WithdrawalIntentExecuted(_asset, finalAmount, block.timestamp);
        emit WithdrawalIntentsProcessed(
            _asset,
            intentIndices.length,
            finalAmount,
            feesCollected,
            block.timestamp
        );
    }

    /// @dev GLV equivalent of GmxV2FeesHelper._updateBenchmark. Refreshes the GLV position
    /// benchmark to the PA's current (post-withdrawal) balance, mirroring
    /// GlvFacet._updateGlvPositionBenchmark (which lives on a facet this one does not inherit).
    function _updateGlvBenchmark(address glvToken, UnifiedGmxTokenPricesAndAddresses memory pricesAndAddresses) private {
        uint256 glvBalance = IERC20Metadata(glvToken).balanceOf(address(this));
        (uint256 longTokenAmount, uint256 shortTokenAmount) = _getGlvLongAndShortTokenAmounts(glvToken, glvBalance);

        _createOrUpdatePositionBenchmark(glvToken, GmxPositionDetails({
            underlyingLongTokenAmount: longTokenAmount,
            underlyingShortTokenAmount: shortTokenAmount,
            gmTokenPriceUsd: pricesAndAddresses.gmTokenPrice,
            longTokenPriceUsd: pricesAndAddresses.longTokenPrice,
            shortTokenPriceUsd: pricesAndAddresses.shortTokenPrice,
            benchmarkTimeStamp: block.timestamp,
            longTokenAddress: pricesAndAddresses.longToken,
            shortTokenAddress: pricesAndAddresses.shortToken
        }));
    }

    function _repayPrimeDebtToExecuteWithdrawalIntent(uint256 amount, uint256 totalDebt, ITokenManager tokenManager) internal {
        require(_getAvailableBalance("PRIME") >= amount, "Not enough PRIME to repay the debt");
        address primeTokenAddress = tokenManager.getAssetAddress("PRIME", true);
        
        // Split: 50% burn, 50% to treasury
        uint256 burnAmount = amount / 2;
        uint256 treasuryAmount = amount - burnAmount;


        primeTokenAddress.safeTransfer(BURN_ADDRESS, burnAmount);

        address treasuryAddress = DeploymentConstants.getTreasuryAddress();
        primeTokenAddress.safeTransfer(treasuryAddress, treasuryAmount);
        
        // Update debt (need to update the recorded debt, not just subtract from current)
        uint256 recordedDebt = DiamondStorageLib.getPrimeDebt();
        DiamondStorageLib.setPrimeDebt(recordedDebt > amount ? recordedDebt - amount : 0);

        uint256 currentDebtAfter = LeverageTierLib.getCurrentPrimeDebt(totalDebt);
        
        emit PrimeDebtRepaid(msg.sender, amount, currentDebtAfter, block.timestamp);
    }
    



    function cancelWithdrawalIntent(bytes32 _asset, uint256 intentIndex) external onlyWhitelistedLiquidatorsAndInsolvencySnapshotOrOwner nonReentrant {
        address tokenAddress = address(getERC20TokenInstance(_asset, true));
        DiamondStorageLib.WithdrawalIntentsStorage storage wis = DiamondStorageLib.withdrawalIntentsStorage();
        DiamondStorageLib.WithdrawalIntent[] storage intents = wis.intents[tokenAddress];

        require(intentIndex < intents.length, "Invalid intent index");

        uint256 amount = intents[intentIndex].amount;
        uint256 actionableAt = intents[intentIndex].actionableAt;
        uint256 expiresAt = intents[intentIndex].expiresAt;

        uint256 lastIndex = intents.length - 1;
        if (intentIndex != lastIndex) {
            intents[intentIndex] = intents[lastIndex];
        }
        intents.pop();

        emit WithdrawalIntentCanceled(_asset, amount, block.timestamp);
        emit WithdrawalIntentCanceledDetailed(
            _asset,
            intentIndex,
            amount,
            actionableAt,
            expiresAt,
            block.timestamp
        );
    }

    function clearExpiredIntents(bytes32 _asset) external {
        address tokenAddress = address(getERC20TokenInstance(_asset, true));
        uint256 clearedCount = _removeExpiredIntents(tokenAddress);
        
        if (clearedCount > 0) {
            emit ExpiredIntentsCleared(_asset, clearedCount, block.timestamp);
        }
    }

    function _removeExpiredIntents(address tokenAddress) internal returns (uint256 clearedCount) {
        DiamondStorageLib.WithdrawalIntentsStorage storage wis = DiamondStorageLib.withdrawalIntentsStorage();
        DiamondStorageLib.WithdrawalIntent[] storage intents = wis.intents[tokenAddress];

        uint256 i = 0;
        clearedCount = 0;
        while (i < intents.length) {
            if (block.timestamp > intents[i].expiresAt) {
                uint256 lastIndex = intents.length - 1;
                if (i != lastIndex) {
                    intents[i] = intents[lastIndex];
                }
                intents.pop();
                clearedCount++;
            } else {
                i++;
            }
        }
    }

    function validateWithdrawalIntents(
        address tokenAddress,
        uint256[] calldata intentIndices
    ) internal view returns (uint256 finalAmount) {
        require(intentIndices.length > 0, "Must provide at least one intent");

        DiamondStorageLib.WithdrawalIntentsStorage storage wis = DiamondStorageLib.withdrawalIntentsStorage();
        DiamondStorageLib.WithdrawalIntent[] storage intents = wis.intents[tokenAddress];

        uint256 totalAmount = 0;

        for(uint256 i = 0; i < intentIndices.length; i++) {
            require(
                i == 0 || intentIndices[i] > intentIndices[i-1],
                "Intent indices must be strictly increasing"
            );

            uint256 index = intentIndices[i];
            require(index < intents.length, "Invalid intent index");

            DiamondStorageLib.WithdrawalIntent storage intent = intents[index];
            require(block.timestamp >= intent.actionableAt, "Intent not matured");
            require(block.timestamp <= intent.expiresAt, "Intent expired");

            totalAmount += intent.amount;
        }

        return totalAmount;
    }

    function getUserIntents(bytes32 _asset) external view returns (IntentInfo[] memory) {
        address tokenAddress = address(getERC20TokenInstance(_asset, true));
        DiamondStorageLib.WithdrawalIntentsStorage storage wis = DiamondStorageLib.withdrawalIntentsStorage();
        DiamondStorageLib.WithdrawalIntent[] storage intents = wis.intents[tokenAddress];

        IntentInfo[] memory intentInfos = new IntentInfo[](intents.length);

        for (uint256 i = 0; i < intents.length; i++) {
            DiamondStorageLib.WithdrawalIntent storage intent = intents[i];
            intentInfos[i] = IntentInfo({
                amount: intent.amount,
                actionableAt: intent.actionableAt,
                expiresAt: intent.expiresAt,
                isPending: block.timestamp < intent.actionableAt,
                isActionable: block.timestamp >= intent.actionableAt && block.timestamp <= intent.expiresAt,
                isExpired: block.timestamp > intent.expiresAt
            });
        }

        return intentInfos;
    }

    function getTotalIntentAmount(bytes32 _asset) public view returns (uint256) {
        address tokenAddress = address(getERC20TokenInstance(_asset, true));
        DiamondStorageLib.WithdrawalIntentsStorage storage wis = DiamondStorageLib.withdrawalIntentsStorage();
        DiamondStorageLib.WithdrawalIntent[] storage intents = wis.intents[tokenAddress];

        uint256 totalPending = 0;
        for (uint256 i = 0; i < intents.length; i++) {
            // Only count non-expired intents
            if (block.timestamp <= intents[i].expiresAt) {
                totalPending += intents[i].amount;
            }
        }

        return totalPending;
    }

    function getAvailableBalance(bytes32 _asset) public view returns (uint256) {
        IERC20Metadata token = getERC20TokenInstance(_asset, true);
        uint256 balance = token.balanceOf(address(this));
        uint256 stakedAmount = DiamondStorageLib.getStakedTokenAmount(address(token));
        balance = balance > stakedAmount ? balance - stakedAmount: 0;
        uint256 pendingWithdrawals = getTotalIntentAmount(_asset);
        return balance > pendingWithdrawals ? balance - pendingWithdrawals : 0;
    }

    function getAvailableBalancePayable(bytes32 _asset) external payable returns (uint256) {
        return getAvailableBalance(_asset);
    }

    /**
     * @dev Allows whitelisted liquidators to cancel a PA's withdrawal intents once an
     * insolvency snapshot is in place, so intents whose underlying token amounts are no
     * longer available cannot remain as stale obligations blocking liquidation accounting.
     * Owners retain unrestricted cancel rights.
     */
    modifier onlyWhitelistedLiquidatorsAndInsolvencySnapshotOrOwner() {
        bool isWhitelistedLiquidator = ISmartLoanLiquidationFacet(DeploymentConstants.getDiamondAddress()).isLiquidatorWhitelisted(msg.sender);
        if (isWhitelistedLiquidator) {
            DiamondStorageLib.LiquidationSnapshotStorage storage ls = DiamondStorageLib.liquidationSnapshotStorage();
            require(ls.lastInsolventTimestamp > 0, "No insolvency snapshot - call snapshotInsolvency first");
            require(block.timestamp - ls.lastInsolventTimestamp < DiamondStorageLib.INSOLVENCY_SNAPSHOT_VALIDITY, "Insolvency snapshot expired - take a new one");
        } else {
            DiamondStorageLib.enforceIsContractOwner();
        }
        _;
    }

    error InsufficientAvailableBalance(uint256 amount, uint256 availableBalance);
    /* ========== ERRORS ========== */
    error NeitherGmxOrGlv();

    // NEW EVENTS FOR ENHANCED MONITORING
    event FeesSweptDuringWithdrawalIntent(
        address indexed gmToken,
        uint256 feesCollected,
        bytes32 indexed asset,
        uint256 originalAmount,
        uint256 timestamp
    );

    event BenchmarkUpdatedDuringWithdrawalIntent(
        address indexed gmToken,
        uint256 gmTokenPrice,
        uint256 longTokenPrice,
        uint256 shortTokenPrice,
        uint256 timestamp
    );

    event WithdrawalIntentsProcessed(
        bytes32 indexed asset,
        uint256 intentsProcessed,
        uint256 finalAmount,
        uint256 feesDeducted,
        uint256 timestamp
    );

    event WithdrawalIntentCanceledDetailed(
        bytes32 indexed asset,
        uint256 intentIndex,
        uint256 amount,
        uint256 actionableAt,
        uint256 expiresAt,
        uint256 timestamp
    );

    event ExpiredIntentsCleared(
        bytes32 indexed asset,
        uint256 clearedCount,
        uint256 timestamp
    );

    event PrimeDebtRepaid(
        address indexed user, 
        uint256 amount, 
        uint256 remainingDebt, 
        uint256 timestamp
    );
}