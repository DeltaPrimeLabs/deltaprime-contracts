// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "./PendingOwnableUpgradeable.sol";
import "../Pool.sol";
import "../lib/ParaSwapHelper.sol";
import "../lib/DeploymentConstants.sol";
import "../interfaces/ITokenManager.sol";

abstract contract DepositSwapBase is ReentrancyGuardUpgradeable, PendingOwnableUpgradeable, ParaSwapHelper {
    using SafeERC20 for IERC20;

    // Custom errors for better gas efficiency
    error UnsupportedToken(address token);
    error InsufficientPoolBalance(uint256 available, uint256 requested);
    error SlippageLimitExceeded(uint256 currentSlippage, uint256 accumulatedSlippage, uint256 threshold);
    error ContractPaused();

    // STORAGE

    // Slippage tracking
    struct SlippageInfo {
        uint256 timestamp;
        uint256 slippageValueUSD; // In 18 decimals
    }
    
    SlippageInfo[] public slippageHistory;
    uint256 public accumulatedSlippageUSD; // Accumulated slippage in USD (18 decimals)
    uint256 public slippageThresholdUSD; // Threshold for accumulated slippage in USD (18 decimals)
    bool public paused;

    uint256 public constant SLIPPAGE_HISTORY_DURATION = 12 hours;

    event SlippageRecorded(uint256 timestamp, uint256 slippageValueUSD);
    event SlippageHistoryCleaned(uint256 removedEntries, uint256 slippageReduced);
    event SlippageThresholdUpdated(uint256 newThreshold);
    event OpeartionsPaused();
    event OperationsUnpaused();

    /**
     * @notice Initialize the contract
     * @param _initialSlippageThreshold Initial slippage threshold in USD (18 decimals)
     */
    function __DepositSwapBase_init(
        uint256 _initialSlippageThreshold
    ) internal onlyInitializing {
        __PendingOwnable_init();
        slippageThresholdUSD = _initialSlippageThreshold;
    }

    /**
     * @notice Modifier to prevent execution when contract is paused
     */
    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    // ============ TOKEN / POOL RESOLUTION ============

    /**
     * @notice The TokenManager backing token/pool resolution
     */
    function _tokenManager() internal view virtual returns (ITokenManager) {
        return DeploymentConstants.getTokenManager();
    }

    /**
     * @notice Get the pool address for a given token
     * @param token Token address
     * @return Pool address, or address(0) when the token has no active pool
     */
    function _getPoolAddress(address token) internal view virtual returns (address) {
        if (token == address(0)) return address(0);
        ITokenManager tokenManager = _tokenManager();

        bytes32 symbol = tokenManager.tokenAddressToSymbol(token);
        if (symbol == bytes32(0)) return address(0);

        if (!tokenManager.isTokenAssetActive(token)) return address(0);

        // Round-trip the symbol so a stale symbol->address mapping cannot point the pool
        // lookup at a different token than the caller supplied.
        try tokenManager.getAssetAddress(symbol, false) returns (address registered) {
            if (registered != token) return address(0);
        } catch {
            return address(0);
        }

        // getPoolAddress reverts for a symbol with no lending pool.
        try tokenManager.getPoolAddress(symbol) returns (address pool) {
            return pool;
        } catch {
            return address(0);
        }
    }

    /**
     * @notice Check if a token is supported by the contract
     * @param token Address of the token to check
     * @return supported Whether the token is supported
     */
    function _isTokenSupported(address token) internal view virtual returns (bool supported) {
        return _getPoolAddress(token) != address(0);
    }

    /**
     * @notice Convert token address to symbol
     * @param token Token address
     * @return symbol Token symbol as bytes32
     */
    function _tokenAddressToSymbol(address token) internal view virtual returns (bytes32 symbol) {
        symbol = _tokenManager().tokenAddressToSymbol(token);
        if (symbol == bytes32(0)) revert UnsupportedToken(token);
    }

    // ============ COMMON FUNCTIONALITY ============

    /**
     * @notice Set the slippage threshold
     * @param _newThreshold New slippage threshold in USD (18 decimals)
     */
    function setSlippageThreshold(uint256 _newThreshold) external nonReentrant onlyOwner {
        slippageThresholdUSD = _newThreshold;
        emit SlippageThresholdUpdated(_newThreshold);
    }
    
    /**
     * @notice Pause the contract
     */
    function pause() external nonReentrant onlyOwner {
        paused = true;
        emit OpeartionsPaused();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external nonReentrant onlyOwner {
        paused = false;
        emit OperationsUnpaused();
    }

    /**
     * @notice Clean up old slippage history entries
     * @return removedCount Number of entries removed
     * @return slippageReduced Amount of slippage removed from accumulator
     */
    function cleanSlippageHistory() public returns (uint256 removedCount, uint256 slippageReduced) {
        uint256 currentTime = block.timestamp;
        uint256 cutoffTime = currentTime - SLIPPAGE_HISTORY_DURATION;
        uint256 i = 0;
        uint256 totalReduced = 0;
        
        // Find the first entry that's not expired
        while (i < slippageHistory.length && slippageHistory[i].timestamp < cutoffTime) {
            totalReduced += slippageHistory[i].slippageValueUSD;
            i++;
        }
        
        // If we found expired entries, remove them
        if (i > 0) {
            // Shift all non-expired entries to the beginning
            for (uint256 j = i; j < slippageHistory.length; j++) {
                slippageHistory[j - i] = slippageHistory[j];
            }
            
            // Remove duplicates from the end
            for (uint256 j = 0; j < i; j++) {
                slippageHistory.pop();
            }
            
            // Update accumulated slippage
            accumulatedSlippageUSD -= totalReduced;
            
            emit SlippageHistoryCleaned(i, totalReduced);
            return (i, totalReduced);
        }
        
        return (0, 0);
    }

    /**
     * @notice Record slippage and update accumulator
     * @notice slippageValueUSD == 0 means that no limit is being enforced
     * @param slippageValueUSD Slippage value in USD (18 decimals)
     */
    function recordSlippage(uint256 slippageValueUSD) internal {
        cleanSlippageHistory();

        // Check against threshold
        if (slippageThresholdUSD != 0 && accumulatedSlippageUSD + slippageValueUSD > slippageThresholdUSD) {
            revert SlippageLimitExceeded(slippageValueUSD, accumulatedSlippageUSD, slippageThresholdUSD);
        }
        
        // Record new slippage
        slippageHistory.push(SlippageInfo({
            timestamp: block.timestamp,
            slippageValueUSD: slippageValueUSD
        }));
        
        // Update accumulator
        accumulatedSlippageUSD += slippageValueUSD;
        
        emit SlippageRecorded(block.timestamp, slippageValueUSD);
    }

    /**
     * @notice Map a token address to its corresponding pool
     * @param token Address of the token
     * @return pool Pool contract for the token
     */
    function _tokenToPoolTUPMapping(address token) internal view returns (Pool) {
        address poolAddress = _getPoolAddress(token);
        if (poolAddress == address(0)) {
            revert UnsupportedToken(token);
        }
        return Pool(poolAddress);
    }

    /**
     * @notice Withdraw tokens from a pool
     * @param pool Pool to withdraw from
     * @param token Token to withdraw
     * @param amount Amount to withdraw
     * @param user User address
     */
    function _withdrawFromPool(Pool pool, IERC20 token, uint256 amount, address user) internal {
        uint256 userInitialFromTokenDepositBalance = pool.balanceOf(user);
        uint256 contractFromTokenInitialDepositBalance = pool.balanceOf(address(this));

        if (userInitialFromTokenDepositBalance < amount) {
            revert InsufficientPoolBalance(userInitialFromTokenDepositBalance, amount);
        }

        pool.transferFrom(user, address(this), amount);
        require(pool.balanceOf(address(this)) - contractFromTokenInitialDepositBalance == amount, "amountFromToken and post-transfer contract balance mismatch");
        require(pool.balanceOf(user) == userInitialFromTokenDepositBalance - amount, "user post-transfer balance is incorrect");

        uint256 poolInitialTokenBalance = token.balanceOf(address(this));

        pool.withdrawInstant(amount);

        require(pool.balanceOf(address(this)) == contractFromTokenInitialDepositBalance, "Post-withdrawal contract deposit balance must be 0");
        require(token.balanceOf(address(this)) == poolInitialTokenBalance + amount, "Post-withdrawal contract fromToken balance is incorrect");
    }

    /**
     * @notice Deposit tokens to a pool
     * @param pool Pool to deposit to
     * @param token Token to deposit
     * @param amount Amount to deposit
     * @param user User address
     */
    function _depositToPool(Pool pool, IERC20 token, uint256 amount, address user) internal {
        uint256 contractInitialToTokenBalance = token.balanceOf(address(this));
        uint256 userInitialToTokenDepositBalance = pool.balanceOf(user);
        uint256 contractInitialToTokenDepositBalance = pool.balanceOf(address(this));

        require(contractInitialToTokenBalance >= amount, "Insufficient contract toToken balance");

        token.forceApprove(address(pool), amount);
        pool.deposit(amount);

        require(pool.balanceOf(address(this)) == contractInitialToTokenDepositBalance + amount, "Post-deposit contract deposit balance is incorrect");

        pool.transfer(user, amount);

        require(pool.balanceOf(user) == userInitialToTokenDepositBalance + amount, "Post-transfer user deposit balance is incorrect");
    }

    /**
     * @notice Sync exposure for token - override implementation from ParaSwapHelper
     * @param token Token address to sync exposure for
     */
    function _syncExposure(ITokenManager tokenManager, address token) internal override {
        // No-op implementation for deposit swap context
        // This function is called by ParaSwapHelper.executeSwap but not needed in our context
    }

    /**
     * @notice Calculate USD value of token amount
     * @param token Token address
     * @param amount Token amount in token decimals
     * @return usdValue USD value in 18 decimals
     */
    function _calculateUSDValue(address token, uint256 amount) internal view returns (uint256) {
        bytes32 symbol = _tokenAddressToSymbol(token);
        bytes32[] memory symbols = new bytes32[](1);
        symbols[0] = symbol;
        uint256[] memory prices = getPrices(symbols);
        uint256 tokenDecimals = IERC20Metadata(token).decimals();
        
        // Convert amount to 18 decimals for USD calculation
        uint256 amountIn18Decimals;
        if (tokenDecimals < 18) {
            amountIn18Decimals = amount * (10 ** (18 - tokenDecimals));
        } else if (tokenDecimals > 18) {
            amountIn18Decimals = amount / (10 ** (tokenDecimals - 18));
        } else {
            amountIn18Decimals = amount;
        }
        
        // Calculate USD value - prices are in 8 decimals, we need to adjust to get result in 18 decimals
        // We multiply by 10^10 to convert from 8 decimals to 18 decimals
        return (amountIn18Decimals * prices[0] * 10**10) / 1e18;
    }

    /**
     * @notice Deposit from one token pool to another using ParaSwap v6
     * @param selector Function selector for ParaSwap
     * @param data Encoded ParaSwap data
     * @param fromToken Address of the source token
     * @param fromAmount Amount of source tokens to swap
     * @param toToken Address of the destination token
     * @param minOut Minimum amount of destination tokens to receive
     */
    function depositSwapParaSwapV6(
        bytes4 selector,
        bytes calldata data,
        address fromToken,
        uint256 fromAmount,
        address toToken,
        uint256 minOut
    ) public nonReentrant whenNotPaused {
        if (!_isTokenSupported(fromToken)) revert UnsupportedToken(fromToken);
        if (!_isTokenSupported(toToken)) revert UnsupportedToken(toToken);

        require(minOut > 0, "minOut needs to be > 0");
        require(fromAmount > 0, "Amount of tokens to sell needs to be > 0");

        // Decode and validate ParaSwap data
        ParaSwapDecodedData memory swapData = decodeParaSwapData(selector, data);
        validateSwapParameters(swapData, false); // Not a liquidation
        
        // Ensure decoded data matches provided parameters
        require(swapData.fromAmount == fromAmount, "From amount mismatch");
        require(swapData.toAmount >= minOut, "Min output mismatch");

        Pool fromPool = _tokenToPoolTUPMapping(fromToken);
        Pool toPool = _tokenToPoolTUPMapping(toToken);
        
        address user = msg.sender;
        uint256 initialUSDValue = _calculateUSDValue(fromToken, fromAmount);
        
        // Withdraw from source pool
        _withdrawFromPool(fromPool, IERC20(fromToken), fromAmount, user);
        
        // Get token details for the swap
        SwapTokensDetails memory details = SwapTokensDetails({
            tokenSoldSymbol: _tokenAddressToSymbol(fromToken),  // We don't use these in this context
            tokenBoughtSymbol: _tokenAddressToSymbol(toToken),
            soldToken: IERC20Metadata(fromToken),
            boughtToken: IERC20Metadata(toToken),
            initialSoldTokenBalance: IERC20(fromToken).balanceOf(address(this)),
            initialBoughtTokenBalance: IERC20(toToken).balanceOf(address(this)),
            soldTokenDecimals: IERC20Metadata(fromToken).decimals(),
            boughtTokenDecimals: IERC20Metadata(toToken).decimals()
        });
        
        // Execute swap via ParaSwap helper
        executeSwap(selector, data, details, swapData, false);
        
        // Get the received amount
        uint256 receivedAmount = IERC20(toToken).balanceOf(address(this)) - details.initialBoughtTokenBalance;
        require(receivedAmount >= minOut, "Too little received");

        uint256 finalUSDValue = _calculateUSDValue(toToken, receivedAmount);

        if (finalUSDValue < initialUSDValue) {
            uint256 slippageUSD = initialUSDValue - finalUSDValue;
            recordSlippage(slippageUSD);
        }
        
        // Deposit to destination pool
        _depositToPool(toPool, IERC20(toToken), receivedAmount, user);
    }
}