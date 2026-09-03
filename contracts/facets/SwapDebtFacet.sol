// SPDX-License-Identifier: BUSL-1.1
// Last deployed from commit: a52a9854d08c0ef6be5d121511952dd473bb82dd;
pragma solidity 0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TransferHelper} from "@uniswap/lib/contracts/libraries/TransferHelper.sol";
import {ReentrancyGuardKeccak} from "../ReentrancyGuardKeccak.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DiamondStorageLib} from "../lib/DiamondStorageLib.sol";
import {ITokenManager} from "../interfaces/ITokenManager.sol";
import {IStakingPositions} from "../interfaces/IStakingPositions.sol";
import {Pool} from "../Pool.sol";
import {LeverageTierLib} from "../lib/LeverageTierLib.sol";
import {PrimeAccountModifiers} from "../PrimeAccountModifiers.sol";
import {SmartLoanLiquidationFacet} from "./SmartLoanLiquidationFacet.sol";
import {IAssetsOperationsFacet} from "../interfaces/facets/IAssetsOperationsFacet.sol";
import {ParaSwapHelper} from "../lib/ParaSwapHelper.sol";

//this path is updated during deployment
import {DeploymentConstants} from "../lib/DeploymentConstants.sol";

/**
 * @title SwapDebtFacet
 * @notice Facet for refinancing debt from one token to another while maintaining equal dollar value
 * @dev Allows users to convert their existing debt (e.g., USDC) into an equivalent value of debt in another token (e.g., BTC)
 * without changing their overall debt position value, using ParaSwap for efficient token conversion
 */
contract SwapDebtFacet is ReentrancyGuardKeccak, PrimeAccountModifiers, ParaSwapHelper {

    using TransferHelper for address payable;
    using TransferHelper for address;

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
     * @notice Processes the repayment after a debt refinancing
     * @dev Handles approval, repayment, and exposure adjustments after converting debt to a new token
     * @param tokenManager The token manager interface
     * @param fromAssetPool The pool where the original debt is being repaid
     * @param fromToken The original debt token address being repaid
     * @param repayAmount The amount to repay
     */
    /**
     * @notice Borrows `_borrowAmount` of `_toAsset` while keeping the leverage-tier PRIME
     *         accounting in sync, exactly as AssetsOperationsFacet.borrow does.
     * @dev Snapshots prime debt on the pre-borrow state, borrows, then re-validates/updates the
     *      required PRIME stake against the (unchanged) collateral value. Kept in its own frame
     *      so swapDebtParaSwap stays under the stack-depth limit without via-ir.
     */
    function _borrowWithPrimeAccounting(bytes32 _toAsset, uint256 _borrowAmount) private {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        Pool toAssetPool = Pool(tokenManager.getPoolAddress(_toAsset));

        uint256 totalDebt = _getDebt();
        LeverageTierLib.updatePrimeDebtSnapshot(totalDebt);
        uint256 maxBorrowableValue = (_getTotalValue() - totalDebt) * 10;

        toAssetPool.borrow(_borrowAmount);

        LeverageTierLib.validateAndUpdateStakedPrime(maxBorrowableValue, _getAvailableBalance("PRIME"));
    }

    function _processRepay(ITokenManager tokenManager, Pool fromAssetPool, address fromToken, uint256 repayAmount) internal {
        fromToken.safeApprove(address(fromAssetPool), 0);
        fromToken.safeApprove(address(fromAssetPool), repayAmount);
        fromAssetPool.repay(repayAmount);
        _syncExposure(tokenManager, fromToken);
        fromToken.safeApprove(address(fromAssetPool), 0);
    }

  /**
     * @notice Refinances debt from one token to another of equal dollar value
     * @dev Borrows in the new token, swaps to the old token, and repays existing debt
     * @param _fromAsset Asset symbol of the current debt to be repaid
     * @param _toAsset Asset symbol of the new debt to take on
     * @param _repayAmount Amount of current debt to repay
     * @param _borrowAmount Amount of new token to borrow
     * @param selector Function selector for the ParaSwap transaction
     * @param data Calldata to execute with ParaSwap
     */    
     function swapDebtParaSwap(bytes32 _fromAsset, bytes32 _toAsset, uint256 _repayAmount, uint256 _borrowAmount, bytes4 selector, bytes calldata data) external onlyOwner noBorrowInTheSameBlock remainsSolvent nonReentrant notInLiquidation {
        require(_borrowAmount > 0, "Borrow amount must be positive");
        require(_fromAsset != _toAsset, "Cannot swap same asset");
        
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        Pool fromAssetPool = Pool(tokenManager.getPoolAddress(_fromAsset));
        _repayAmount = Math.min(_repayAmount, fromAssetPool.getBorrowed(address(this)));

        IERC20Metadata toToken = getERC20TokenInstance(_toAsset, false);
        IERC20Metadata fromToken = getERC20TokenInstance(_fromAsset, false);
        
        // Check dollar value difference between borrowed and repaid amounts
        {
            bytes32[] memory symbols = new bytes32[](2);
            symbols[0] = _fromAsset;
            symbols[1] = _toAsset;
            uint256[] memory prices = getPrices(symbols);
            
            uint256 repayValueUSD = prices[0] * _repayAmount * (10**10) / (10**fromToken.decimals());
            uint256 borrowValueUSD = prices[1] * _borrowAmount * (10**10) / (10**toToken.decimals());
            
            // Allow maximum 5% difference between repay and borrow values
            uint256 maxDiff = repayValueUSD > borrowValueUSD ? 
                ((repayValueUSD - borrowValueUSD) * 10000) / repayValueUSD : 
                ((borrowValueUSD - repayValueUSD) * 10000) / borrowValueUSD;
                
            require(maxDiff <= 500, "Dollar value diff too high"); // 500 = 5%
        }

        // Borrow the new asset with the same PRIME debt-snapshot + stake re-sync that
        // AssetsOperationsFacet.borrow performs, so a debt swap cannot expand a Premium position
        // outside the leverage-tier PRIME-staking gate.
        // Encapsulated in a helper to keep swapDebtParaSwap within the stack-depth limit (no via-ir).
        _borrowWithPrimeAccounting(_toAsset, _borrowAmount);

        uint256 initialRepayTokenAmount = _getAvailableBalance(_fromAsset);
        
        // Update lastBorrowTimestamp to prevent flash loan attacks
        {
            DiamondStorageLib.DiamondStorage storage ds = DiamondStorageLib.diamondStorage();
            ds._lastBorrowTimestamp = block.timestamp;
        }


        {
            ParaSwapDecodedData memory paraSwapDecodedData = decodeParaSwapData(selector, data);
            require(paraSwapDecodedData.fromAmount == _borrowAmount, "Borrow amount mismatch in swap data");

            validateSwapParameters(paraSwapDecodedData, false);

            SwapTokensDetails memory details = getInitialTokensDetails(
                    paraSwapDecodedData.srcToken,
                    paraSwapDecodedData.destToken
                );

            // Bind the ParaSwap route to the declared refinance: it must sell the borrowed
            // _toAsset and buy the _fromAsset being repaid. Without this binding an unrelated
            // swap could create new _toAsset debt while repaying none of the _fromAsset debt.
            require(paraSwapDecodedData.srcToken == address(toToken), "Debt swap must sell the borrowed asset");
            require(paraSwapDecodedData.destToken == address(fromToken), "Debt swap must buy the repaid asset");

            executeSwap(selector, data, details, paraSwapDecodedData, false);
        }
 
        _repayAmount = Math.min(_getAvailableBalance(_fromAsset), _repayAmount);

        ///@dev might need to declare a separate scope here if stack too deep error in testing. Compiles now with via_ir
        _processRepay(tokenManager, fromAssetPool, address(fromToken), _repayAmount);
        _syncExposure(tokenManager, address(toToken));

        emit DebtSwap(msg.sender, address(fromToken), address(toToken), _repayAmount, _borrowAmount, block.timestamp);
    }

}