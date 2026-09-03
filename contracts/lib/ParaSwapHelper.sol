// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ITokenManager} from "../interfaces/ITokenManager.sol";
import {IPool} from "../interfaces/IPool.sol";
import {TransferHelper} from "@uniswap/lib/contracts/libraries/TransferHelper.sol";
import {DeploymentConstants} from "../lib/DeploymentConstants.sol";
import {DiamondMethodsAccess} from "./DiamondMethodsAccess.sol";
import {DiamondStorageLib} from "./DiamondStorageLib.sol";


/**
 * @title ParaSwapLib
 * @notice Library containing extracted and reusable functions from ParaSwapFacet
 * @dev All functions are pure or view and can be used in any context
 */
contract ParaSwapHelper is DiamondMethodsAccess {
    using TransferHelper for address;

    // Constants
    uint256 private constant MAX_BPS = 10000;
    uint256 private constant LIQUIDATION_MAX_SLIPPAGE_BPS = 500; // 5% per-swap hard cap
    uint256 private constant NORMAL_MAX_SLIPPAGE_BPS = 500; // 5%
    uint256 private constant MAX_AMOUNT = type(uint128).max;
    uint256 private constant PRICE_DECIMALS = 10; // Prices have 8 decimals in this project
    /// @dev Cumulative pre-liquidation slippage is measured in dollars and compared
    /// against this fraction (in basis points) of the debt captured at snapshotInsolvency time.
    /// 800 BPS = 8% of the liquidated debt value.
    uint256 private constant MAX_CUMULATIVE_LOSS_BPS = 800;

    ///@dev paraSwap v6.2 router
    address private constant PARA_ROUTER = 0x6A000F20005980200259B80c5102003040001068;

    ///@notice selectors for paraSwapV6 data decoding
    bytes4 private constant SWAP_EXACT_AMOUNT_IN_SELECTOR = 0xe3ead59e;
    bytes4 private constant SWAP_EXACT_AMOUNT_IN_ON_UNI_V3_SELECTOR = 0x876a02f6;

    // Events
    event SwapExecuted(
        address indexed user,
        bytes32 indexed soldAsset,
        bytes32 indexed boughtAsset,
        uint256 amountSold,
        uint256 amountBought,
        uint256 timestamp
    );
    event SlippageExceeded(
        address indexed user,
        uint256 soldTokenValue,
        uint256 boughtTokenValue,
        uint256 slippage
    );

    // Custom errors for gas optimization
    error InvalidExecutor();
    error InvalidPartnerAddress();
    error InvalidBeneficiary();
    error InvalidTokenAddress();
    error InvalidAmount();
    error InsufficientBalance();
    error InsufficientAllowance();
    error SwapFailed();
    error TooLittleReceived();
    error SlippageTooHigh(uint256 actual, uint256 max);
    error InvalidDecimals();
    error TooMuchSold();
    error CumulativeLossExceeded(uint256 cumulativeLossDollars, uint256 maxAllowedDollars);
    error BoughtTokenHasNoDebt(bytes32 boughtSymbol);
    error GmGlvNotSwappable(address token);

    struct SwapTokensDetails {
        bytes32 tokenSoldSymbol;
        bytes32 tokenBoughtSymbol;
        IERC20Metadata soldToken;
        IERC20Metadata boughtToken;
        uint256 initialSoldTokenBalance;
        uint256 initialBoughtTokenBalance;
        uint8 soldTokenDecimals;
        uint8 boughtTokenDecimals;
    }

    struct ParaSwapDecodedData {
        address executor;
        address srcToken;
        address destToken;
        uint256 fromAmount;
        uint256 toAmount;
        address partner;
        address payable beneficiary;
    }

    struct GenericData {
        address srcToken;
        address destToken;
        uint256 fromAmount;
        uint256 toAmount;
        uint256 quotedAmount;
        bytes32 metadata;
        address payable beneficiary;
    }

    struct SwapExactAmountIn {
        address executor;
        GenericData swapData;
        uint256 partnerAndFee;
        bytes permit;
        bytes executorData;
    }

    struct UniswapV3Data {
        address srcToken;
        address destToken;
        uint256 fromAmount;
        uint256 toAmount;
        uint256 quotedAmount;
        bytes32 metadata;
        address payable beneficiary;
        bytes pools;
    }

    struct UniswapV3FullData {
        UniswapV3Data uniData;
        uint256 partnerAndFee;
        bytes permit;
    }
    /**
     * @notice Get initial token details for a swap
     * @param _soldTokenAddress The address of the token being sold
     * @param _boughtTokenAddress The address of the token being bought
     * @return SwapTokensDetails struct containing token details
     */
    function getInitialTokensDetails(address _soldTokenAddress, address _boughtTokenAddress)
    internal
    view
    returns (SwapTokensDetails memory)
    {
        if (_soldTokenAddress == address(0) || _boughtTokenAddress == address(0)) {
            revert InvalidTokenAddress();
        }

        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        require(address(tokenManager) != address(0), "Invalid token manager");

        // GM/GLV market tokens carry fee-aware (performance-fee benchmark) accounting that the
        // generic swap path does not respect, and they are not routable through ParaSwap on-chain
        // (mint/redeem-only via the GMX keeper). Reject them as either side of any swap routed
        // through this helper: paraSwapV6, paraSwapBeforeLiquidation and swapDebtParaSwap.
        if (tokenManager.isGmxMarketWhitelisted(_soldTokenAddress) || tokenManager.isGlvTokenWhitelisted(_soldTokenAddress)) {
            revert GmGlvNotSwappable(_soldTokenAddress);
        }
        if (tokenManager.isGmxMarketWhitelisted(_boughtTokenAddress) || tokenManager.isGlvTokenWhitelisted(_boughtTokenAddress)) {
            revert GmGlvNotSwappable(_boughtTokenAddress);
        }

        bytes32 _tokenSoldSymbol = tokenManager.tokenAddressToSymbol(_soldTokenAddress);
        bytes32 _tokenBoughtSymbol = tokenManager.tokenAddressToSymbol(_boughtTokenAddress);

        require(tokenManager.isTokenAssetActive(_boughtTokenAddress), "Asset not supported");

        IERC20Metadata _soldToken = IERC20Metadata(_soldTokenAddress);
        IERC20Metadata _boughtToken = IERC20Metadata(_boughtTokenAddress);

        // Validate token decimals
        uint8 soldDecimals = _soldToken.decimals();
        uint8 boughtDecimals = _boughtToken.decimals();
        if (soldDecimals > 18 || boughtDecimals > 18) {
            revert InvalidDecimals();
        }

        return SwapTokensDetails({
            tokenSoldSymbol: _tokenSoldSymbol,
            tokenBoughtSymbol: _tokenBoughtSymbol,
            soldToken: _soldToken,
            boughtToken: _boughtToken,
            initialSoldTokenBalance: _soldToken.balanceOf(address(this)),
            initialBoughtTokenBalance: _boughtToken.balanceOf(address(this)),
            soldTokenDecimals: soldDecimals,
            boughtTokenDecimals: boughtDecimals
        });
    }

    /**
     * @notice Validate swap parameters
     * @param data The decoded ParaSwap data
     * @param isLiquidation Whether the swap is part of a liquidation
     */
    function validateSwapParameters(ParaSwapDecodedData memory data, bool isLiquidation) internal {
        // Validate executor
        if (data.executor != address(0) && !_checkExecutorAddress(data.executor)) {
            revert InvalidExecutor();
        }

        // Validate partner address
        if (data.partner != address(0) && data.partner != DeploymentConstants.getTreasuryAddress()) {
            revert InvalidPartnerAddress();
        }

        // Validate beneficiary
        if (data.beneficiary != address(this) && data.beneficiary != address(0)) {
            revert InvalidBeneficiary();
        }

        // Validate token addresses
        if (data.srcToken == address(0) || data.destToken == address(0) || data.srcToken == data.destToken) {
            revert InvalidTokenAddress();
        }

        // Validate amounts
        if (data.fromAmount == 0 || data.toAmount == 0 || data.fromAmount > MAX_AMOUNT) {
            revert InvalidAmount();
        }

        // Additional checks for liquidation
        if (isLiquidation) {
            DiamondStorageLib.LiquidationSnapshotStorage storage ls = DiamondStorageLib.liquidationSnapshotStorage();
            require(ls.lastInsolventTimestamp > 0, "No insolvency snapshot - call snapshotInsolvency first");
            require(block.timestamp - ls.lastInsolventTimestamp < DiamondStorageLib.INSOLVENCY_SNAPSHOT_VALIDITY, "Insolvency snapshot expired - take a new one");

            // Pre-liquidation swaps may only produce tokens the Prime Account owes.
            // This prevents liquidators from pivoting collateral through arbitrary assets
            // on the way to eventual debt repayment.
            _requireBoughtTokenHasDebt(data.destToken);
        }
    }

    /**
     * @notice Reverts unless the Prime Account has outstanding debt in `boughtToken`'s pool.
     * @dev Allowing swaps into tokens the PA doesn't owe would let a pre-liquidation swap
     *      move value through an arbitrary asset with no solvency guardrail, bypassing the intent
     *      of bounding pre-liquidation slippage to assets directly needed for debt repayment.
     */
    function _requireBoughtTokenHasDebt(address boughtToken) internal view {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        bytes32 boughtSymbol = tokenManager.tokenAddressToSymbol(boughtToken);
        // getPoolAddress reverts for non-borrowable assets; that reverts pre-liquidation swap appropriately.
        address pool = tokenManager.getPoolAddress(boughtSymbol);
        if (IPool(pool).getBorrowed(address(this)) == 0) {
            revert BoughtTokenHasNoDebt(boughtSymbol);
        }
    }

    function executeSwap(
        bytes4 selector,
        bytes calldata data,
        SwapTokensDetails memory details,
        ParaSwapDecodedData memory swapData,
        bool isLiquidation
    ) internal {
        // Check balance and allowance
        if (_getAvailableBalance(details.tokenSoldSymbol) < swapData.fromAmount) {
            revert InsufficientBalance();
        }

        // Approve tokens
        address(details.soldToken).safeApprove(PARA_ROUTER, 0);
        address(details.soldToken).safeApprove(PARA_ROUTER, swapData.fromAmount);

        if (details.soldToken.allowance(address(this), PARA_ROUTER) < swapData.fromAmount) {
            revert InsufficientAllowance();
        }

        // Execute swap
        (bool success,) = PARA_ROUTER.call(abi.encodePacked(selector, data));
        if (!success) revert SwapFailed();


        // Verify results
        uint256 boughtAmount = details.boughtToken.balanceOf(address(this)) - details.initialBoughtTokenBalance;

        
        if (boughtAmount < swapData.toAmount) revert TooLittleReceived();

        uint256 soldAmount = details.initialSoldTokenBalance - details.soldToken.balanceOf(address(this));

        // Verify exact amount sold for liquidations
        if (isLiquidation && soldAmount != swapData.fromAmount) {
            revert TooMuchSold();
        }


        // Check slippage
        checkSlippage(details, soldAmount, boughtAmount, isLiquidation);


        // Update exposures
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        _syncExposure(tokenManager, address(details.soldToken));
        _syncExposure(tokenManager, address(details.boughtToken));

        // Revoke unused approval
        address(details.soldToken).safeApprove(PARA_ROUTER, 0);
        emit SwapExecuted(
            msg.sender,
            details.tokenSoldSymbol,
            details.tokenBoughtSymbol,
            soldAmount,
            boughtAmount,
            block.timestamp
        );
    }

    /**
     * @notice Check slippage for a swap
     * @param details Token details
     * @param soldAmount Amount of tokens sold
     * @param boughtAmount Amount of tokens bought
     * @param isLiquidation Whether this is a liquidation
     */
    function checkSlippage(
        SwapTokensDetails memory details,
        uint256 soldAmount,
        uint256 boughtAmount,
        bool isLiquidation
    ) internal {
        bytes32[] memory symbols = new bytes32[](2);
        symbols[0] = details.tokenSoldSymbol;
        symbols[1] = details.tokenBoughtSymbol;
        uint256[] memory prices = getPrices(symbols);
        require(prices.length == 2, "Invalid price data");

        uint256 soldTokenDollarValue = prices[0] * soldAmount * (10**PRICE_DECIMALS) / (10**details.soldTokenDecimals);
        uint256 boughtTokenDollarValue = prices[1] * boughtAmount * (10**PRICE_DECIMALS) / (10**details.boughtTokenDecimals);

        if (soldTokenDollarValue > boughtTokenDollarValue) {
            uint256 lossDollars = soldTokenDollarValue - boughtTokenDollarValue;
            uint256 slippage = (lossDollars * MAX_BPS) / soldTokenDollarValue;
            uint256 maxSlippage = isLiquidation ? LIQUIDATION_MAX_SLIPPAGE_BPS : NORMAL_MAX_SLIPPAGE_BPS;

            // Per-swap hard cap (unchanged).
            if (slippage >= maxSlippage) {
                emit SlippageExceeded(msg.sender, soldTokenDollarValue, boughtTokenDollarValue, slippage);
                revert SlippageTooHigh(slippage, maxSlippage);
            }

            // For liquidation swaps, accumulate $-loss and compare against a fraction of the
            // debt value captured at snapshotInsolvency(). This measures "how much value have
            // pre-liquidation swaps drained, as a share of the debt the liquidator is unwinding",
            // which is correct under variable swap sizes (simply summing BPS is not).
            if (isLiquidation) {
                DiamondStorageLib.LiquidationSnapshotStorage storage ls = DiamondStorageLib.liquidationSnapshotStorage();
                uint256 newCumulativeLoss = ls.cumulativeLossDollars + lossDollars;
                uint256 maxAllowedLoss = (ls.debtSnapshotDollars * MAX_CUMULATIVE_LOSS_BPS) / MAX_BPS;
                if (newCumulativeLoss > maxAllowedLoss) {
                    revert CumulativeLossExceeded(newCumulativeLoss, maxAllowedLoss);
                }
                ls.cumulativeLossDollars = newCumulativeLoss;
            }
        }
    }

    /**
     * @notice Decode ParaSwap data based on the selector
     * @param selector Function selector
     * @param data Calldata for the ParaSwap interaction
     * @return decoded ParaSwapDecodedData struct
     */
    function decodeParaSwapData(bytes4 selector, bytes calldata data) internal pure returns (ParaSwapDecodedData memory) {
        if (selector == SWAP_EXACT_AMOUNT_IN_SELECTOR) {
            return _decodeSwapExactAmountInData(data);
        } else if (selector == SWAP_EXACT_AMOUNT_IN_ON_UNI_V3_SELECTOR) {
            return _decodeSwapExactAmountInOnUniV3Data(data);
        }
        revert("Invalid selector");
    }

    /**
     * @notice Decode data for SwapExactAmountInOnUniV3
     * @param _data Calldata for the function
     * @return decoded ParaSwapDecodedData struct
     */
    function _decodeSwapExactAmountInOnUniV3Data(bytes calldata _data)
    internal
    pure
    returns (ParaSwapDecodedData memory decoded)
    {
        UniswapV3Data memory _uniswapV3Data = abi.decode(_data, (UniswapV3Data));
        uint256 partnerAndFee = _decodePartnerAndFeeForUniFullData(_data);
        (address payable partner,) = _parsePartnerAndFeeData(partnerAndFee);

        decoded.srcToken = _uniswapV3Data.srcToken;
        decoded.destToken = _uniswapV3Data.destToken;
        decoded.fromAmount = _uniswapV3Data.fromAmount;
        decoded.toAmount = _uniswapV3Data.toAmount;
        decoded.partner = partner;
        decoded.beneficiary = _uniswapV3Data.beneficiary;

        return decoded;
    }

    /**
     * @notice Decode partnerAndFee from UniswapV3 data
     * @param data Calldata for the function
     * @return partnerAndFee Encoded partner and fee data
     */
    function _decodePartnerAndFeeForUniFullData(bytes calldata data) internal pure returns (uint256 partnerAndFee) {
        require(data.length >= 288, "Invalid UniV3 data length");

        assembly {
            partnerAndFee := calldataload(add(data.offset, 32))
        }
    }

    /**
     * @notice Decode data for SwapExactAmountIn
     * @param _data Calldata for the function
     * @return decoded ParaSwapDecodedData struct
     */
    function _decodeSwapExactAmountInData(bytes calldata _data)
    internal
    pure
    returns (ParaSwapDecodedData memory decoded)
    {
        require(_data.length >= 288, "Invalid SwapExactAmountIn data length");

        address executor;
        bytes memory executorBytes = _data[:32];
        assembly {
            executor := mload(add(executorBytes, 32))
        }

        /// @dev generic data size is 224. So the entire struct would be from 32 to 224+32 positions
        bytes memory genericDataBytes = _data[32:256];
        GenericData memory _genericData = _decodeGenericData(genericDataBytes);

        uint256 partnerAndFee = abi.decode(_data[256:288], (uint256));
        (address payable partner,) = _parsePartnerAndFeeData(partnerAndFee);

        decoded.executor = executor;
        decoded.srcToken = _genericData.srcToken;
        decoded.destToken = _genericData.destToken;
        decoded.fromAmount = _genericData.fromAmount;
        decoded.toAmount = _genericData.toAmount;
        decoded.partner = partner;
        decoded.beneficiary = _genericData.beneficiary;

        return decoded;
    }

    /**
     * @notice Decode GenericData struct
     * @param _data Encoded generic data
     * @return decoded GenericData struct
     */
    function _decodeGenericData(bytes memory _data) internal pure returns (GenericData memory) {
        GenericData memory genericData = abi.decode(_data, (GenericData));
        return genericData;
    }

    /**
     * @notice Parse partner and fee data
     * @param partnerAndFee Encoded partner and fee data
     * @return partner Partner address
     * @return feeBps Fee in basis points
     */
    function _parsePartnerAndFeeData(uint256 partnerAndFee)
    internal
    pure
    returns (address payable partner, uint256 feeBps)
    {
        assembly {
        // Get partner address from last 20 bytes
            partner := and(shr(96, partnerAndFee), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        // Get fee directly in basis points using 14-bit mask
            feeBps := and(partnerAndFee, 0x3FFF)
        }
    }

    /**
     * @notice Check if an address is a valid ParaSwap executor
     * @dev The executor set lives in the TokenManager (whitelisted/delisted by the owner) instead of
     *      being hardcoded here, so ParaSwap router/executor rotations no longer require redeploying
     *      and diamondCutting every facet that swaps.
     * @param _executorAddress Address to check
     * @return isValid Whether the address is a valid executor
     */
    function _checkExecutorAddress(address _executorAddress) internal view returns (bool) {
        return DeploymentConstants.getTokenManager().isParaSwapExecutorWhitelisted(_executorAddress);
    }
}