// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

interface IGlvFacet {
    

    // ============ EXTERNAL FUNCTIONS ============

    /**
     * @notice Deposits WETH or USDC into the WETH-USDC GLV token
     * @param isLongToken True if depositing the long token (WETH), false for short token (USDC)
     * @param tokenAmount Amount of tokens to deposit
     * @param minGlvAmount Minimum amount of GLV tokens to receive
     * @param targetMarket Target market address for the deposit
     * @param executionFee Execution fee in native token (must equal msg.value)
     */
    function depositWethUsdcGlv(
        bool isLongToken,
        uint256 tokenAmount,
        uint256 minGlvAmount,
        address targetMarket,
        uint256 executionFee
    ) external payable;

    /**
     * @notice Withdraws from the WETH-USDC GLV token
     * @param glvAmount Amount of GLV tokens to withdraw
     * @param targetMarket Target market address for the withdrawal
     * @param minLongTokenAmount Minimum amount of long token (WETH) to receive
     * @param minShortTokenAmount Minimum amount of short token (USDC) to receive
     * @param executionFee Execution fee in native token (must equal msg.value)
     */
    function withdrawWethUsdcGlv(
        uint256 glvAmount,
        address targetMarket,
        uint256 minLongTokenAmount,
        uint256 minShortTokenAmount,
        uint256 executionFee
    ) external payable;

    /**
     * @notice Deposits WBTC or USDC into the BTC-USDC GLV token
     * @param isLongToken True if depositing the long token (WBTC), false for short token (USDC)
     * @param tokenAmount Amount of tokens to deposit
     * @param minGlvAmount Minimum amount of GLV tokens to receive
     * @param targetMarket Target market address for the deposit
     * @param executionFee Execution fee in native token (must equal msg.value)
     */
    function depositBtcUsdcGlv(
        bool isLongToken,
        uint256 tokenAmount,
        uint256 minGlvAmount,
        address targetMarket,
        uint256 executionFee
    ) external payable;

    /**
     * @notice Withdraws from the BTC-USDC GLV token
     * @param glvAmount Amount of GLV tokens to withdraw
     * @param targetMarket Target market address for the withdrawal
     * @param minLongTokenAmount Minimum amount of long token (WBTC) to receive
     * @param minShortTokenAmount Minimum amount of short token (USDC) to receive
     * @param executionFee Execution fee in native token (must equal msg.value)
     */
    function withdrawBtcUsdcGlv(
        uint256 glvAmount,
        address targetMarket,
        uint256 minLongTokenAmount,
        uint256 minShortTokenAmount,
        uint256 executionFee
    ) external payable;

    /**
     * @notice Initiates the fee benchmark for a GLV token
     * @param glvToken Address of the GLV token
     */

    /**
     * @notice Gets the annualized performance of a GLV token
     * @param glvToken Address of the GLV token
     * @return Annualized performance value
     */
    function getGlvPerformance(address glvToken) external view returns (uint256);

    /**
     * @notice Sweeps accumulated fees and updates the benchmark for a GLV token
     * @param glvToken Address of the GLV token
     * @return gmTokensInFees Amount of GM tokens collected as fees
     */
    function sweepFeesAndUpdateGlvBenchMark(address glvToken) external returns (uint256 gmTokensInFees);

    
}