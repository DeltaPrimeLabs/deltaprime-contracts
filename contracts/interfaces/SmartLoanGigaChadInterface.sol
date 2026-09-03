// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "./facets/avalanche/IYieldYakFacet.sol";
import "./facets/avalanche/IYieldYakSwapFacet.sol";
import "./facets/avalanche/IParaSwapFacet.sol";
import "./facets/avalanche/IGLPFacet.sol";
import "./facets/IAssetsOperationsFacet.sol";
import "./facets/IOwnershipFacet.sol";
import "./facets/ISmartLoanViewFacet.sol";
import "./facets/ISmartLoanLiquidationFacet.sol";
import "./facets/ISmartLoanWrappedNativeTokenFacet.sol";
import "./facets/ISolvencyFacetProd.sol";
import "./facets/IHealthMeterFacetProd.sol";
import "./IDiamondLoupe.sol";
import "./facets/IGmxV2Facet.sol";
import "./facets/IGmxV2PlusFacet.sol";
import "./facets/avalanche/IBeefyFinanceFacet.sol";
import "./facets/avalanche/ITraderJoeV2Facet.sol";
import "./facets/avalanche/ITraderJoeV2AutopoolsFacet.sol";
import "./facets/avalanche/IBalancerV2Facet.sol";
import "./facets/avalanche/IGogoPoolFacet.sol";
import "./facets/arbitrum/IBeefyFinanceArbitrumFacet.sol";
import "./facets/avalanche/IYieldYakWombatFacet.sol";
import "./facets/IWithdrawalIntentFacet.sol";
import "./facets/avalanche/IWombatFacet.sol";
import "./facets/IPrimeLeverageFacet.sol";
import "./facets/ISJoeFacet.sol";
import "./IWithdrawUnsupportedPositionsFacet.sol";
import "./facets/arbitrum/IGlvFacet.sol";

interface SmartLoanGigaChadInterface is
    IWithdrawalIntentFacet,
    IHealthMeterFacetProd,
    IGLPFacet,
    IYieldYakSwapFacet,
    IParaSwapFacet,
    IDiamondLoupe,
    IBeefyFinanceFacet,
    IBeefyFinanceArbitrumFacet,
    IWombatFacet,
    IYieldYakWombatFacet,
    ISmartLoanWrappedNativeTokenFacet,
    IAssetsOperationsFacet,
    IOwnershipFacet,
    ISmartLoanLiquidationFacet,
    ISmartLoanViewFacet,
    ISolvencyFacetProd,
    IYieldYakFacet,
    ITraderJoeV2Facet,
    ITraderJoeV2AutopoolsFacet,
    IGmxV2Facet,
    IGmxV2PlusFacet,
    IBalancerV2Facet,
    IGogoPoolFacet,
    IPrimeLeverageFacet,
    ISJoeFacet,
    IWithdrawUnsupportedPositionsFacet,
    IGlvFacet
{}
