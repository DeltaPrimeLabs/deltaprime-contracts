// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../ReentrancyGuardKeccak.sol";
import "../lib/DiamondStorageLib.sol";
import "../lib/DiamondMethodsAccess.sol";
import "./SmartLoanLiquidationFacet.sol";
import "../interfaces/ITokenManager.sol";
import "../interfaces/facets/avalanche/IParaSwapFacet.sol";
import "../lib/DeploymentConstants.sol";
import {ParaSwapHelper} from "../lib/ParaSwapHelper.sol";
import "../PrimeAccountModifiers.sol";


contract ParaSwapFacet is ReentrancyGuardKeccak, ParaSwapHelper, PrimeAccountModifiers {
    
    function paraSwapBeforeLiquidation(
        bytes4 selector,
        bytes calldata data
    ) external nonReentrant onlyWhitelistedLiquidators noBorrowInTheSameBlock {
        ParaSwapDecodedData memory paraSwapDecodedData = decodeParaSwapData(selector, data);
        validateSwapParameters(paraSwapDecodedData, true);

        SwapTokensDetails memory details = getInitialTokensDetails(
            paraSwapDecodedData.srcToken,
            paraSwapDecodedData.destToken
        );

        executeSwap(selector, data, details, paraSwapDecodedData, true);
    }

    function paraSwapV6(
        bytes4 selector,
        bytes calldata data
    ) external nonReentrant onlyOwner noBorrowInTheSameBlock remainsSolvent notInLiquidation {
        
        ParaSwapDecodedData memory paraSwapDecodedData = decodeParaSwapData(selector, data);

        validateSwapParameters(paraSwapDecodedData, false);

        SwapTokensDetails memory details = getInitialTokensDetails(
                paraSwapDecodedData.srcToken,
                paraSwapDecodedData.destToken
            );
        
        executeSwap(selector, data, details, paraSwapDecodedData, false);

    }
}