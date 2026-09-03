// SPDX-License-Identifier: BUSL-1.1
// Last deployed from commit: 47cac92e2aae18ac8937139ac1f8de17bc62f581;
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@uniswap/lib/contracts/libraries/TransferHelper.sol";
import "../ReentrancyGuardKeccak.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {DiamondStorageLib} from "../lib/DiamondStorageLib.sol";
import {LeverageTierLib} from "../lib/LeverageTierLib.sol";
import "../lib/GmxV2FeesHelper.sol";
import {GlvHelper} from "../lib/GlvHelper.sol";
import {GmxBenchmarkMath} from "../lib/GmxBenchmarkMath.sol";
import "../PrimeAccountModifiers.sol";
import "../interfaces/ITokenManager.sol";
import {IGmxReader} from "../interfaces/gmx-v2/IGmxReader.sol";
import {IGlvReader} from "../interfaces/gmx-v2/IGlvReader.sol";
import "./SmartLoanLiquidationFacet.sol";
import "../interfaces/facets/IYieldYakRouter.sol";

//this path is updated during deployment
import "../lib/DeploymentConstants.sol";

contract AssetsOperationsFacet is ReentrancyGuardKeccak, PrimeAccountModifiers, GmxV2FeesHelper, GlvHelper {
    using TransferHelper for address payable;
    using TransferHelper for address;

    address private constant PARA_TRANSFER_PROXY =
        0x216B4B4Ba9F3e719726886d34a177484278Bfcae;
    address private constant PARA_ROUTER =
        0xDEF171Fe48CF0115B1d80b88dc8eAB59176FEe57;

    /**
     * @dev Restricts `fund()` to the loan owner or the SmartLoansFactory. The factory needs
     *      access because `createAndFundLoan` calls `fund()` via a low-level call on the
     *      freshly-created loan, so `msg.sender` is the factory address rather than the EOA.
     */
    modifier onlyOwnerOrFactory() {
        if (msg.sender != DeploymentConstants.getSmartLoansFactoryAddress()) {
            DiamondStorageLib.enforceIsContractOwner();
        }
        _;
    }

    /* ========== PUBLIC AND EXTERNAL MUTATIVE FUNCTIONS ========== */
    
    

    /**
    * Removes an asset from the ownedAssets array
    * @param _asset asset to be removed
    * @param _address address of the asset
    **/
    function removeUnsupportedOwnedAsset(bytes32 _asset, address _address) external onlyWhitelistedLiquidators nonReentrant {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();

        _validateAssetRemoval(tokenManager, _address, _asset);

        // Remove the asset from the ownedAssets array
        DiamondStorageLib.removeOwnedAsset(_asset);

        emit RemovedAsset(_asset, _address, block.timestamp);
    }

    function removeUnsupportedStakedPosition(bytes32 _identifier) external onlyWhitelistedLiquidators nonReentrant {
        IStakingPositions.StakedPosition[] storage positions = DiamondStorageLib.stakedPositions();
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();

        bool found = false;
        IStakingPositions.StakedPosition memory stakedPosition;
        for (uint i = 0; i < positions.length; i++) {
            if (positions[i].identifier == _identifier) {
                found = true;
                stakedPosition = positions[i];
                break;
            }
        }
        if(!found) revert PositionNotFound();

        address _address = stakedPosition.asset;
        bytes32 _symbol = stakedPosition.symbol;

        _validateAssetRemoval(tokenManager, _address, _symbol);

        DiamondStorageLib.removeStakedPosition(_identifier);

        emit RemovedStakedPosition(_identifier, _address,_symbol, block.timestamp);
    }

    /**
    * Funds the loan with a specified amount of a defined token
    * @dev Requires approval for ERC20 token on frontend side
    * @param _fundedAsset asset to be funded
    * @param _amount to be funded
    **/
    function fund(bytes32 _fundedAsset, uint256 _amount) public virtual onlyOwnerOrFactory noBorrowInTheSameBlock nonReentrant {
        IERC20Metadata token = getERC20TokenInstance(_fundedAsset, false);
        _amount = Math.min(_amount, token.balanceOf(msg.sender));

        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        GmxTokenPrices memory gmxTokenPrices;
        uint256 feesCollected = 0;
        
        if(tokenManager.isGmxMarketWhitelisted(address(token)) || tokenManager.isGlvTokenWhitelisted(address(token))) {
            DiamondStorageLib.GmxPositionBenchmark memory benchmark = DiamondStorageLib.getGmxPositionBenchmark(address(token));

            // Fetch the prices for ANY whitelisted GM/GLV token, not only when a
            // benchmark already exists. These prices are used twice — by the fee sweep below
            // (existing benchmark) and by _createOrUpdateBenchmarkIfGmOrGlvToken further down,
            // which runs unconditionally. Leaving them zeroed on a first-time deposit fed a
            // zero price struct into GmxBenchmarkMath.premiumScaledUnderlying, whose
            // totalUnderlyingWorth then divides by zero: every first fund() of a GM market
            // token into an account with no benchmark for it reverted with Panic(0x12), and
            // the GLV branch silently seeded a benchmark with zero prices.
            if(tokenManager.isGlvTokenWhitelisted(address(token))){
                UnifiedGmxTokenPricesAndAddresses memory pricesAndAddresses = _getUnifiedGlvTokenPricesAndAddresses(address(token));
                gmxTokenPrices = GmxTokenPrices({
                gmTokenPrice: pricesAndAddresses.gmTokenPrice,
                longTokenPrice: pricesAndAddresses.longTokenPrice,
                shortTokenPrice: pricesAndAddresses.shortTokenPrice
                });
            } else  { // isGmxMarketWhitelisted
                gmxTokenPrices = _getGmxTokenPrices(address(token));
            }

            if(benchmark.exists) {
                // Capture the pre-sweep balance so the benchmark can be scaled down
                // proportionally after the fee tokens leave the PA. Without scaling, the
                // benchmark would still reflect the pre-sweep position size and the
                // additive update below would leave a stale performance residual that
                // gets re-charged on the next sweep.
                uint256 preSweepBalance = IERC20(token).balanceOf(address(this));
                feesCollected = _sweepFees(address(token), gmxTokenPrices);
                if (feesCollected > 0) {
                    DiamondStorageLib.scaleGmxPositionBenchmark(
                        address(token),
                        preSweepBalance - feesCollected,
                        preSweepBalance
                    );
                    emit FeesSweptDuringFunding(address(token), feesCollected, _fundedAsset, _amount, block.timestamp);
                }
            }
        }

        address(token).safeTransferFrom(msg.sender, address(this), _amount);

        _syncExposure(tokenManager, address(token));
        if(tokenManager.isGmxMarketWhitelisted(address(token)) || tokenManager.isGlvTokenWhitelisted(address(token))) {
            //Use unified method for both GMX and GLV tokens
            _createOrUpdateBenchmarkIfGmOrGlvToken(address(token), _amount, gmxTokenPrices);
        }

        emit Funded(msg.sender, _fundedAsset, _amount, block.timestamp);
    }

    /**
     * @dev Compute the underlying-token deltas attributable to `_amount` of GM/GLV tokens
     *      being funded in, then extend the benchmark additively. The benchmark is never
     *      overwritten here: a dust fund() call must not be able to erase an
     *      unrealized-gain cost basis.
     */
    function _createOrUpdateBenchmarkIfGmOrGlvToken(address _token, uint256 _amount, GmxTokenPrices memory gmxTokenPrices) internal {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        UnifiedGmxTokenPricesAndAddresses memory unified;
        uint256 longTokenAmount;
        uint256 shortTokenAmount;
        if (tokenManager.isGlvTokenWhitelisted(_token)) {
            unified = _getUnifiedGlvTokenPricesAndAddresses(_token);
            // For GLV tokens we compute the delta contribution from just `_amount`, not the
            // full post-fund balance. This keeps the additive update semantically consistent
            // with the GM branch below.
            (longTokenAmount, shortTokenAmount) = _getGlvLongAndShortTokenAmounts(_token, _amount);

        } else if (tokenManager.isGmxMarketWhitelisted(_token)) {
            // Use the unified method to get both addresses and avoid duplicate calls
            unified = _getUnifiedGmxTokenPricesAndAddresses(_token);

            // Use premium-scaled pro-rata for the funded delta, matching the invariant
            // `longAmt * longPrice + shortAmt * shortPrice == _amount * gmPrice` that
            // `_getUnderlyingTokenDetails` and the GLV branch already maintain. The math
            // is delegated to the external `GmxBenchmarkMath` library to keep this facet
            // under the 24 KB code-size limit.
            (longTokenAmount, shortTokenAmount) = GmxBenchmarkMath.premiumScaledUnderlying(
                _token,
                _amount,
                unified.longToken,
                unified.shortToken,
                gmxTokenPrices.gmTokenPrice,
                gmxTokenPrices.longTokenPrice,
                gmxTokenPrices.shortTokenPrice,
                unified.isPlusMarket
            );

            if(unified.isPlusMarket) {
                gmxTokenPrices.shortTokenPrice = 0; // to avoid double counting of tokenPriceUSD
            }

        }
        GmxPositionDetails memory positionDetails = GmxPositionDetails({
            underlyingLongTokenAmount: longTokenAmount,
            underlyingShortTokenAmount: shortTokenAmount,
            gmTokenPriceUsd: gmxTokenPrices.gmTokenPrice,
            longTokenPriceUsd: gmxTokenPrices.longTokenPrice,
            shortTokenPriceUsd: gmxTokenPrices.shortTokenPrice,
            benchmarkTimeStamp: block.timestamp,
            longTokenAddress: unified.longToken,
            shortTokenAddress: unified.shortToken
        });
        _addToBenchmarkFromFunding(_token, positionDetails, _amount);

        emit BenchmarkCreatedOrUpdatedViaFunding(
            _token,
            _amount,
            longTokenAmount,
            shortTokenAmount,
            unified.isPlusMarket,
            block.timestamp
        );
    }

    function addOwnedAsset(bytes32 _asset, address _address) external onlyWhitelistedLiquidators nonReentrant{
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        if(tokenManager.tokenAddressToSymbol(_address) != _asset) revert AssetAddressSymbolMismatch();
        if(!tokenManager.isTokenAssetActive(_address)) revert AssetNotSupported();

        DiamondStorageLib.addOwnedAsset(_asset, _address);
        
        emit AssetAdded(_asset, _address, msg.sender, block.timestamp);
    }

    function _processRepay(ITokenManager tokenManager, Pool fromAssetPool, address fromToken, uint256 repayAmount, uint256 receivedRepayTokenAmount) internal {
        fromToken.safeApprove(address(fromAssetPool), 0);
        fromToken.safeApprove(address(fromAssetPool), repayAmount);
        fromAssetPool.repay(repayAmount);

        _syncExposure(tokenManager, fromToken);

        fromToken.safeApprove(address(fromAssetPool), 0);
    }

    /**
    * Funds the loan with a specified amount of a GLP
    * @dev Requires approval for stakedGLP token on frontend side
    * @param _amount to be funded
    **/
    function fundGLP(uint256 _amount) public virtual onlyOwner noBorrowInTheSameBlock nonReentrant {
        IERC20Metadata stakedGlpToken = IERC20Metadata(0xaE64d55a6f09E4263421737397D1fdFA71896a69);
        _amount = Math.min(_amount, stakedGlpToken.balanceOf(msg.sender));
        address(stakedGlpToken).safeTransferFrom(msg.sender, address(this), _amount);

        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        _syncExposure(tokenManager, address(stakedGlpToken));

        emit Funded(msg.sender, "GLP", _amount, block.timestamp);
    }

    /**
    * Borrows funds from the pool
    * @dev This function uses the redstone-evm-connector
    * @param _asset to be borrowed
    * @param _amount of funds to borrow
    **/
    function borrow(bytes32 _asset, uint256 _amount) external onlyOwner remainsSolvent noBorrowInTheSameBlock nonReentrant notInLiquidation {
        DiamondStorageLib.DiamondStorage storage ds = DiamondStorageLib.diamondStorage();
        ds._lastBorrowTimestamp = block.timestamp;

        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        Pool pool = Pool(tokenManager.getPoolAddress(_asset));
    
        uint256 totalDebt = _getDebt();
        ///@dev previous totalDebt goes into snapshot update before borrowing, collateral value stays unchanged
        LeverageTierLib.updatePrimeDebtSnapshot(totalDebt);
        uint256 totalCollateralValue = _getTotalValue() - totalDebt;

        pool.borrow(_amount);
        IERC20Metadata token = getERC20TokenInstance(_asset, false);
        _syncExposure(tokenManager, address(token));
        

        // max borrowable value gets passed in, multiplication with primeStakingRatio is done in the function
        LeverageTierLib.validateAndUpdateStakedPrime(totalCollateralValue * 10, _getAvailableBalance("PRIME")); //10x total collateral value is max borrowable value

        emit Borrowed(msg.sender, _asset, _amount, block.timestamp);
    }

    
    /**
     * Repays funds to the pool
     * @dev This function uses the redstone-evm-connector
     * @param _asset to be repaid
     * @param _amount of funds to repay
     **/
    function repay(bytes32 _asset, uint256 _amount) public payable  noBorrowInTheSameBlock nonReentrant notInLiquidation {
        IERC20Metadata token = getERC20TokenInstance(_asset, true);

        if(_getAvailableBalance(_asset) < _amount) revert InsufficientBalance();

        if (_isSolvent()) {
            DiamondStorageLib.enforceIsContractOwner();
        }

        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        Pool pool = Pool(tokenManager.getPoolAddress(_asset));

        _amount = Math.min(_amount, _getAvailableBalance(_asset));
        _amount = Math.min(_amount, pool.getBorrowed(address(this)));

        address(token).safeApprove(address(pool), 0);
        address(token).safeApprove(address(pool), _amount);

        uint256 totalDebt = _getDebt();
        ///@dev previous totalDebt goes into snapshot update before repayment, collateral value stays unchanged
        LeverageTierLib.updatePrimeDebtSnapshot(totalDebt);
        uint256 totalCollateralValue = _getTotalValue() - totalDebt;

        pool.repay(_amount);
        _syncExposure(tokenManager, address(token));

        emit Repaid(msg.sender, _asset, _amount, block.timestamp);

        address(token).safeApprove(address(pool), 0);
    }

    function withdrawUnsupportedToken(address token) external nonReentrant onlyOwner noBorrowInTheSameBlock remainsSolvent notInLiquidation {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();

        // _NOT_SUPPORTED = 0
        if(tokenManager.tokenToStatus(token) != 0) revert AssetStillSupported();
        if(tokenManager.tieredDebtCoverage(DiamondStorageLib.getPrimeLeverageTier(), token) != 0) revert AssetHasDebtCoverage();
        
        uint256 balance = IERC20(token).balanceOf(address(this));
        if(balance <= 0) revert ZeroBalance();
        token.safeTransfer(msg.sender, balance);

        emit WithdrawUnsupportedToken(msg.sender, token, balance, block.timestamp);
    }

    // TODO: Separate manager for unfreezing - not liquidators
    function unfreezeAccount() external onlyWhitelistedLiquidators {
        DiamondStorageLib.unfreezeAccount(msg.sender); // This already emits the event
    }

    function _validateAssetRemoval(ITokenManager tokenManager, address _address, bytes32 _symbol) internal view {
        // Check if the asset exists in the TokenManager
        if(tokenManager.tokenToStatus(_address) != 0) revert AssetStillSupported();
        if(tokenManager.tokenAddressToSymbol(_address) != bytes32(0)) revert AssetAddressToSymbolNotEmpty();
        if(tokenManager.tieredDebtCoverage(DiamondStorageLib.getPrimeLeverageTier(), _address) != 0) revert AssetHasDebtCoverage();
        if(tokenManager.identifierToExposureGroup(_symbol) != bytes32(0)) revert AssetHasExposureGroup();

        bytes32[] memory allAssets = tokenManager.getAllTokenAssets();
        // Loop through all assets and check if the asset exists
        for (uint i = 0; i < allAssets.length; i++) {
            if(allAssets[i] == _symbol) revert AssetExistsInTokenManager();
        }
    }

    /* ======= VIEW FUNCTIONS ======*/

    /**
    * Returns a current balance of the asset held by the smart loan
    * @param _asset the code of an asset
    **/
    function getBalance(bytes32 _asset) internal view returns (uint256) {
        IERC20 token = IERC20(DeploymentConstants.getTokenManager().getAssetAddress(_asset, true));
        return token.balanceOf(address(this));
    }

    /* ========== ERRORS ========== */
    error AssetStillSupported();
    error AssetAddressToSymbolNotEmpty();
    error AssetHasDebtCoverage();
    error AssetHasExposureGroup();
    error AssetExistsInTokenManager();
    error PositionNotFound();
    error AssetAddressSymbolMismatch();
    error AssetNotSupported();
    error ZeroBalance();

    /* ========== EVENTS ========== */

    /**
     * @dev emitted after an asset is removed
     * @param asset the asset that was removed
     * @param _address the address of the asset
     * @param timestamp time of removal
     **/
    event RemovedAsset(bytes32 indexed asset, address indexed _address, uint256 timestamp);

    /**
     * @dev emitted after a staked position is removed
     * @param identifier the identifier of the staked position
     * @param _address the address of the asset
     * @param timestamp time of removal
     **/
    event RemovedStakedPosition(bytes32 indexed identifier, address indexed _address, bytes32 indexed _symbol, uint256 timestamp);

    /**
     * @dev emitted after a debt swap
     * @param user the address which performed the debt swap
     * @param fromToken token that was repaid
     * @param toToken token that was borrowed
     * @param repayAmount the amount of fromToken that was repaid
     * @param borrowAmount the amount of toToken that was borrowed
     * @param timestamp time of debt swap
     **/
    event DebtSwap(address indexed user, address indexed fromToken, address indexed toToken, uint256 repayAmount, uint256 borrowAmount, uint256 timestamp);

    /**
     * @dev emitted after a loan is funded
     * @param user the address which funded the loan
     * @param asset funded by a user
     * @param amount the amount of funds
     * @param timestamp time of funding
     **/
    event Funded(address indexed user, bytes32 indexed asset, uint256 amount, uint256 timestamp);

    /**
     * @dev emitted after the funds are withdrawn from the loan
     * @param user the address which withdraws funds from the loan
     * @param asset withdrawn by a user
     * @param amount of funds withdrawn
     * @param timestamp of the withdrawal
     **/
    event Withdrawn(address indexed user, bytes32 indexed asset, uint256 amount, uint256 timestamp);

    /**
     * @dev emitted when funds are borrowed from the pool
     * @param user the address of borrower
     * @param asset borrowed by an= user
     * @param amount of the borrowed funds
     * @param timestamp time of the borrowing
     **/
    event Borrowed(address indexed user, bytes32 indexed asset, uint256 amount, uint256 timestamp);

    /**
     * @dev emitted when funds are repaid to the pool
     * @param user the address initiating repayment
     * @param asset asset repaid by a user
     * @param amount of repaid funds
     * @param timestamp of the repayment
     **/
    event Repaid(address indexed user, bytes32 indexed asset, uint256 amount, uint256 timestamp);

    /**
     * @dev emitted when unsupported token is withdrawn
     * @param user the address withdrawing unsupported token
     * @param token the unsupported token address
     * @param amount of unsupported token withdrawn
     * @param timestamp of the withdraw
     **/
    event WithdrawUnsupportedToken(address indexed user, address indexed token, uint256 amount, uint256 timestamp);

    /**
     * @dev Emitted when PRIME tokens are staked
     * @param user The user who staked
     * @param amount The amount staked
     * @param totalStaked The total amount staked after this operation
     * @param timestamp When the staking occurred
     */
    event PrimeStaked(
        address indexed user, 
        uint256 amount, 
        uint256 totalStaked, 
        uint256 timestamp
    );

     /**
     * @dev Emitted when PRIME tokens are unstaked
     * @param user The user who unstaked
     * @param amount The amount unstaked
     * @param totalStaked The total amount staked after this operation
     * @param timestamp When the unstaking occurred
     */
    event PrimeUnstaked(
        address indexed user, 
        uint256 amount, 
        uint256 totalStaked, 
        uint256 timestamp
    );

    // NEW EVENTS FOR GMX OPERATIONS
    event FeesSweptDuringFunding(
        address indexed gmToken,
        uint256 feesCollected,
        bytes32 indexed fundedAsset,
        uint256 fundedAmount,
        uint256 timestamp
    );

    event BenchmarkCreatedOrUpdatedViaFunding(
        address indexed gmToken,
        uint256 fundedAmount,
        uint256 longTokenAmount,
        uint256 shortTokenAmount,
        bool isPlusMarket,
        uint256 timestamp
    );

    event AssetAdded(
        bytes32 indexed asset,
        address indexed assetAddress,
        address indexed addedBy,
        uint256 timestamp
    );
}