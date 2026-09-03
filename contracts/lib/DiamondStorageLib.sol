// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

/******************************************************************************\
* Author: Nick Mudge <nick@perfectabstractions.com> (https://twitter.com/mudgen)
* EIP-2535 Diamonds: https://eips.ethereum.org/EIPS/eip-2535
/******************************************************************************/
import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {LeverageTierLib} from "../lib/LeverageTierLib.sol";
import "../lib/Bytes32EnumerableMap.sol";
import "../interfaces/IStakingPositions.sol";
import "../interfaces/facets/avalanche/ITraderJoeV2Facet.sol";

// Remember to add the loupe functions from DiamondLoupeFacet to the diamond.
// The loupe functions are required by the EIP2535 Diamonds standard

library DiamondStorageLib {
    using EnumerableMap for EnumerableMap.Bytes32ToAddressMap;

    bytes32 constant DIAMOND_STORAGE_POSITION = keccak256("diamond.standard.diamond.storage");
    bytes32 constant LIQUIDATION_STORAGE_POSITION = keccak256("diamond.standard.liquidation.storage");
    bytes32 constant LIQUIDATION_SNAPSHOT_STORAGE_POSITION = keccak256("diamond.standard.liquidation.snapshot.storage");
    /// @dev Validity window for an insolvency snapshot, shared by liquidate(), the liquidator modifiers and notInLiquidation.
    uint256 internal constant INSOLVENCY_SNAPSHOT_VALIDITY = 15 minutes;
    bytes32 constant SMARTLOAN_STORAGE_POSITION = keccak256("diamond.standard.smartloan.storage");
    bytes32 constant REENTRANCY_GUARD_STORAGE_POSITION = keccak256("diamond.standard.reentrancy.guard.storage");
    bytes32 constant OWNED_TRADERJOE_V2_BINS_POSITION = keccak256("diamond.standard.traderjoe_v2_bins_1685370112");
    //TODO: maybe we should keep here a tuple[tokenId, factory] to account for multiple Uniswap V3 deployments
    bytes32 constant WITHDRAWAL_INTENTS_POSITION = keccak256("diamond.standard.withdrawal.intents");
    bytes32 constant PRIME_LEVERAGE_STORAGE_POSITION = keccak256("diamond.standard.prime.leverage.storage");
    // GMX Performance Fee Tracking
    bytes32 constant GMX_POSITION_STORAGE_POSITION = keccak256("diamond.standard.gmx.position.storage");

    

    struct FacetAddressAndPosition {
        address facetAddress;
        uint96 functionSelectorPosition; // position in facetFunctionSelectors.functionSelectors array
    }

    struct PrimeLeverageStorage {
        LeverageTierLib.LeverageTier leverageTier;
        mapping(address => uint256) tokenToStakedAmount; // Staked amount of any token, only PRIME for now.
        uint256 recordedPrimeDebt;
        uint256 lastPrimeDebtUpdate;
    }

    struct FacetFunctionSelectors {
        bytes4[] functionSelectors;
        uint256 facetAddressPosition; // position of facetAddress in facetAddresses array
    }

    struct DiamondStorage {
        // ----------- DIAMOND-SPECIFIC VARIABLES --------------
        // maps function selector to the facet address and
        // the position of the selector in the facetFunctionSelectors.selectors array
        mapping(bytes4 => FacetAddressAndPosition) selectorToFacetAndPosition;
        // maps facet addresses to function selectors
        mapping(address => FacetFunctionSelectors) facetFunctionSelectors;
        // facet addresses
        address[] facetAddresses;
        // Used to query if a contract implements an interface.
        // Used to implement ERC-165.
        mapping(bytes4 => bool) supportedInterfaces;
        // Used to select methods that can be executed even when Diamond is paused
        mapping(bytes4 => bool) canBeExecutedWhenPaused;

        bool _initialized;
        bool _active;

        uint256 _lastBorrowTimestamp;
    }

    struct SmartLoanStorage {
        // PauseAdmin has the power to pause/unpause the contract without the timelock delay in case of a critical bug/exploit
        address pauseAdmin;
        // Owner of the contract
        address contractOwner;
        // Proposed owner of the contract
        address proposedOwner;
        // Proposed pauseAdmin of the contract
        address proposedPauseAdmin;
        // Is contract initialized?
        bool _initialized;
        // TODO: mock staking tokens until redstone oracle supports them
        EnumerableMap.Bytes32ToAddressMap ownedAssets;
        // Staked positions of the contract
        IStakingPositions.StakedPosition[] currentStakedPositions;

        // Timestamp since which the account is frozen
        // 0 means an account that is not frozen. Any other value means that the account is frozen
        uint256 frozenSince;

        // Timestamp of the last ownership transfer
        uint256 lastOwnershipTransferTimestamp;
    }

    struct WithdrawalIntent {
        uint256 amount;
        uint256 actionableAt;
        uint256 expiresAt;
    }

    struct WithdrawalIntentsStorage {
        // token address => WithdrawalIntent[]
        mapping(address => WithdrawalIntent[]) intents;
        // used to be token address => total pending amount but is no longer used. Left here to preserve the storage slot order.
        mapping(address => uint256) _doNOTUse;
    }

    struct TraderJoeV2Storage {
        // TJ v2 bins of the contract
        ITraderJoeV2Facet.TraderJoeV2Bin[] ownedTjV2Bins;
    }

    struct LiquidationStorage {
        // Mapping controlling addresses that can execute the liquidation methods
        mapping(address=>bool) canLiquidate;
    }

    struct LiquidationSnapshotStorage {
        uint256 lastInsolventTimestamp;
        uint256 healthRatioSnapshot;
        /// @dev dollar-denominated (18 decimals) debt value captured when snapshotInsolvency() is called.
        /// Used as the denominator when enforcing the cumulative pre-liquidation slippage budget.
        uint256 debtSnapshotDollars;
        /// @dev dollar-denominated (18 decimals) cumulative slippage loss across pre-liquidation swaps.
        /// Enforced against `debtSnapshotDollars * MAX_CUMULATIVE_LOSS_BPS / 10_000`.
        uint256 cumulativeLossDollars;
        /// @dev Leverage tier captured when snapshotInsolvency() is called, so the liquidation
        /// fee cannot be moved by the account owner inside the window. Stored as uint256 rather
        /// than the enum so the field is a plain slot append: 0 = BASIC, 1 = PREMIUM, matching
        /// LeverageTierLib.LeverageTier.
        ///
        /// A snapshot that was already live when this field shipped reads 0 and is therefore
        /// charged the BASIC fee. That is deliberate: 0 defaulting to the HIGHER fee is the
        /// conservative direction, and it keeps the reader a plain lookup. The alternative —
        /// encoding "not recorded" and falling back to the live tier — would reintroduce
        /// exactly the live-tier read this snapshot exists to eliminate, on any path that ever
        /// zeroes the slot.
        ///
        /// APPEND ONLY — this struct sits at a keccak slot in diamond storage, so new fields go
        /// at the end, never in the middle.
        uint256 leverageTierSnapshot;
    }

    struct ReentrancyGuardStorage {
        uint256 _status;
    }

    struct GmxPositionBenchmark {
        uint256 benchmarkValueUsd;  // Position value in USD at creation
        uint256 underlyingLongTokenAmount;  // NEW: Actual long tokens in the position
        uint256 underlyingShortTokenAmount;
        uint256 benchmarkTimeStamp;  // when benchmark was created/updated
        address longTokenAddress;    // a bit duplicate considering the facet mapping, but shareable across facets for now
        address shortTokenAddress;   // a bit duplicate considering the facet mapping, but shareable across facets for now
        bool exists;                // Whether benchmark exists
        uint256 gmTokenPriceUsd;
        uint256 longTokenPriceUsd; 
        uint256 shortTokenPriceUsd;
    }

    struct GmxPositionBenchmarkParams {
        address market;
        uint256 benchmarkValueUsd;
        uint256 longTokenAmount;
        uint256 shortTokenAmount;
        address longToken;
        address shortToken;
        uint256 timestamp;
        uint256 gmTokenPriceUsd;
        uint256 longTokenPriceUsd;
        uint256 shortTokenPriceUsd;
    }

    struct GmxPositionStorage {
        // market address => benchmark data 
        mapping(address => GmxPositionBenchmark) positionBenchmarks;
    }

    function gmxPositionStorage() internal pure returns (GmxPositionStorage storage gps) {
        bytes32 position = GMX_POSITION_STORAGE_POSITION;
        assembly { gps.slot := position }
    }
    
    function setGmxPositionBenchmark(GmxPositionBenchmarkParams memory params) internal {
        GmxPositionStorage storage gps = gmxPositionStorage();
        gps.positionBenchmarks[params.market] = GmxPositionBenchmark({
            benchmarkValueUsd: params.benchmarkValueUsd,
            underlyingLongTokenAmount: params.longTokenAmount,
            underlyingShortTokenAmount: params.shortTokenAmount,
            longTokenAddress: params.longToken,
            shortTokenAddress: params.shortToken,
            benchmarkTimeStamp: params.timestamp,
            exists: true,
            gmTokenPriceUsd: params.gmTokenPriceUsd,
            longTokenPriceUsd: params.longTokenPriceUsd,
            shortTokenPriceUsd: params.shortTokenPriceUsd
        });
    }

    /**
     * @notice Scales the underlying-token amounts of an existing benchmark by a fraction
     *         `numerator / denominator`, to keep the per-GM cost basis intact while
     *         removing the share of a position that was just realized as fee.
     * @dev    Only the two `underlying*TokenAmount` fields are touched: those are the ones
     *         read by the fee math and by the solvency-side fee deduction in
     *         `SolvencyFacetProd`. `benchmarkValueUsd` is never read in the fee path (only
     *         emitted for off-chain observability), so leaving it alone trims bytecode at
     *         every consuming facet without affecting fee math.
     */
    function scaleGmxPositionBenchmark(address market, uint256 numerator, uint256 denominator) internal {
        GmxPositionStorage storage gps = gmxPositionStorage();
        GmxPositionBenchmark storage b = gps.positionBenchmarks[market];
        b.underlyingLongTokenAmount  = (b.underlyingLongTokenAmount  * numerator) / denominator;
        b.underlyingShortTokenAmount = (b.underlyingShortTokenAmount * numerator) / denominator;
    }

    function getGmxPositionBenchmark(address market) internal view returns (GmxPositionBenchmark memory benchmark) {
        GmxPositionStorage storage gps = gmxPositionStorage();
        benchmark = gps.positionBenchmarks[market];
    }

    function withdrawalIntentsStorage() internal pure returns (WithdrawalIntentsStorage storage wis) {
        bytes32 position = WITHDRAWAL_INTENTS_POSITION;
        assembly {
            wis.slot := position
        }
    }

    function reentrancyGuardStorage() internal pure returns (ReentrancyGuardStorage storage rgs) {
        bytes32 position = REENTRANCY_GUARD_STORAGE_POSITION;
        assembly {
            rgs.slot := position
        }
    }

    function traderJoeV2Storage() internal pure returns (TraderJoeV2Storage storage tjv2s) {
        bytes32 position = OWNED_TRADERJOE_V2_BINS_POSITION;
        assembly {
            tjv2s.slot := position
        }
    }


    // 10x leverage functions 
    function primeLeverageStorage() internal pure returns (PrimeLeverageStorage storage pls) {
        bytes32 position = PRIME_LEVERAGE_STORAGE_POSITION;
        assembly {
            pls.slot := position
        }
    }

    

    function setPrimeLeverageTier(LeverageTierLib.LeverageTier _tier) internal {
        primeLeverageStorage().leverageTier = _tier;
    }

    function getPrimeLeverageTier() internal view returns (LeverageTierLib.LeverageTier) {
        return primeLeverageStorage().leverageTier;
    }

    function getPrimeDebt() internal view returns (uint256) {
        return primeLeverageStorage().recordedPrimeDebt;
    }

    function setPrimeDebt(uint256 _debt) internal {
        primeLeverageStorage().recordedPrimeDebt = _debt;
    }

    function getLastPrimeDebtUpdate() internal view returns (uint256) {
        return primeLeverageStorage().lastPrimeDebtUpdate;
    }

    function setLastPrimeDebtUpdate(uint256 _timestamp) internal {
        primeLeverageStorage().lastPrimeDebtUpdate = _timestamp;
    }


    function addStakedTokenAmount(address _token, uint256 _amount) internal {
        primeLeverageStorage().tokenToStakedAmount[_token] += _amount;
    }

    function removeStakedTokenAmount(address _token, uint256 _amount) internal {
        uint256 stakedAmount = primeLeverageStorage().tokenToStakedAmount[_token];
        require(_amount > 0, "Amount must be greater than zero");
        require(stakedAmount >= _amount, "Insufficient staked amount");
        primeLeverageStorage().tokenToStakedAmount[_token] -= _amount;
    }


    function getStakedTokenAmount(address _token) internal view returns (uint256) {
        return primeLeverageStorage().tokenToStakedAmount[_token];
    }


    function diamondStorage() internal pure returns (DiamondStorage storage ds) {
        bytes32 position = DIAMOND_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }

    function liquidationStorage() internal pure returns (LiquidationStorage storage ls) {
        bytes32 position = LIQUIDATION_STORAGE_POSITION;
        assembly {
            ls.slot := position
        }
    }

    function smartLoanStorage() internal pure returns (SmartLoanStorage storage sls) {
        bytes32 position = SMARTLOAN_STORAGE_POSITION;
        assembly {
            sls.slot := position
        }
    }

    function liquidationSnapshotStorage() internal pure returns (LiquidationSnapshotStorage storage ls) {
        bytes32 position = LIQUIDATION_SNAPSHOT_STORAGE_POSITION;
        assembly {
            ls.slot := position
        }
    }

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    event PauseAdminOwnershipTransferred(address indexed previousPauseAdmin, address indexed newPauseAdmin);

    event AccountFrozen(address indexed freezeToken, uint256 timestamp);

    event AccountUnfrozen(address indexed keeper, uint256 timestamp);

    function setContractOwner(address _newOwner) internal {
        SmartLoanStorage storage sls = smartLoanStorage();
        address previousOwner = sls.contractOwner;
        sls.contractOwner = _newOwner;
        if(!sls._initialized){
            sls.lastOwnershipTransferTimestamp = block.timestamp - 24 hours; // Dont block withdrawals upon account creation
        } else {
            sls.lastOwnershipTransferTimestamp = block.timestamp;
        }
        emit OwnershipTransferred(previousOwner, _newOwner);
    }

    function freezeAccount(address freezeToken) internal {
        SmartLoanStorage storage sls = smartLoanStorage();
        require(sls.frozenSince == 0, "Account is already frozen");
        sls.frozenSince = block.timestamp;
        emit AccountFrozen(freezeToken, block.timestamp);
    }

    function isAccountFrozen() internal view returns (bool){
        SmartLoanStorage storage sls = smartLoanStorage();
        return sls.frozenSince != 0;
    }

    function unfreezeAccount(address keeperAddress) internal {
        SmartLoanStorage storage sls = smartLoanStorage();
        require(sls.frozenSince != 0, "Account is not frozen");
        sls.frozenSince = 0;
        emit AccountUnfrozen(keeperAddress, block.timestamp);
    }

    function getTjV2OwnedBins() internal returns(ITraderJoeV2Facet.TraderJoeV2Bin[] storage bins){
        TraderJoeV2Storage storage tjv2s = traderJoeV2Storage();
        bins = tjv2s.ownedTjV2Bins;
    }

    function getTjV2OwnedBinsView() internal view returns(ITraderJoeV2Facet.TraderJoeV2Bin[] memory bins){
        TraderJoeV2Storage storage tjv2s = traderJoeV2Storage();
        bins = new ITraderJoeV2Facet.TraderJoeV2Bin[](tjv2s.ownedTjV2Bins.length);
        for (uint256 i = 0; i < bins.length; i++) {
            bins[i] = tjv2s.ownedTjV2Bins[i];
        }
    }

    function setContractPauseAdmin(address _newPauseAdmin) internal {
        SmartLoanStorage storage sls = smartLoanStorage();
        address previousPauseAdmin = sls.pauseAdmin;
        sls.pauseAdmin = _newPauseAdmin;
        emit PauseAdminOwnershipTransferred(previousPauseAdmin, _newPauseAdmin);
    }

    function contractOwner() internal view returns (address contractOwner_) {
        contractOwner_ = smartLoanStorage().contractOwner;
    }

    function pauseAdmin() internal view returns (address pauseAdmin) {
        pauseAdmin = smartLoanStorage().pauseAdmin;
    }

    function setProposedOwner(address _newOwner) internal {
        SmartLoanStorage storage sls = smartLoanStorage();
        sls.proposedOwner = _newOwner;
    }

    function setProposedPauseAdmin(address _newPauseAdmin) internal {
        SmartLoanStorage storage sls = smartLoanStorage();
        sls.proposedPauseAdmin = _newPauseAdmin;
    }

    function getPausedMethodExemption(bytes4 _methodSig) internal view returns (bool) {
        DiamondStorage storage ds = diamondStorage();
        return ds.canBeExecutedWhenPaused[_methodSig];
    }

    function proposedOwner() internal view returns (address proposedOwner_) {
        proposedOwner_ = smartLoanStorage().proposedOwner;
    }

    function proposedPauseAdmin() internal view returns (address proposedPauseAdmin) {
        proposedPauseAdmin = smartLoanStorage().proposedPauseAdmin;
    }

    function stakedPositions() internal view returns (IStakingPositions.StakedPosition[] storage _positions) {
        _positions = smartLoanStorage().currentStakedPositions;
    }

    function addStakedPosition(IStakingPositions.StakedPosition memory position) internal {
        IStakingPositions.StakedPosition[] storage positions = stakedPositions();

        bool found;

        for (uint256 i; i < positions.length; i++) {
            if (positions[i].identifier == position.identifier) {
                found = true;
                break;
            }
        }

        if (!found) {
            positions.push(position);
        }
    }

    function removeStakedPosition(bytes32 identifier) internal {
        IStakingPositions.StakedPosition[] storage positions = stakedPositions();

        for (uint256 i; i < positions.length; i++) {
            if (positions[i].identifier == identifier) {
                positions[i] = positions[positions.length - 1];
                positions.pop();
            }
        }
    }

    function addOwnedAsset(bytes32 _symbol, address _address) internal {
        require(_symbol != "", "Symbol cannot be empty");
        require(_address != address(0), "Invalid AddressZero");
        SmartLoanStorage storage sls = smartLoanStorage();
        EnumerableMap.set(sls.ownedAssets, _symbol, _address);
        emit OwnedAssetAdded(_symbol, block.timestamp);
    }

    function hasAsset(bytes32 _symbol) internal view returns (bool){
        SmartLoanStorage storage sls = smartLoanStorage();
        return sls.ownedAssets.contains(_symbol);
    }

    function removeOwnedAsset(bytes32 _symbol) internal {
        SmartLoanStorage storage sls = smartLoanStorage();
        EnumerableMap.remove(sls.ownedAssets, _symbol);

        emit OwnedAssetRemoved(_symbol, block.timestamp);
    }

    function enforceIsContractOwner() internal view {
        require(msg.sender == smartLoanStorage().contractOwner, "DiamondStorageLib: Must be contract owner");
    }

    function enforceIsPauseAdmin() internal view {
        require(msg.sender == smartLoanStorage().pauseAdmin, "DiamondStorageLib: Must be contract pauseAdmin");
    }

    event DiamondCut(IDiamondCut.FacetCut[] _diamondCut, address _init, bytes _calldata);

    // Internal function version of diamondCut
    function diamondCut(
        IDiamondCut.FacetCut[] memory _diamondCut,
        address _init,
        bytes memory _calldata
    ) internal {
        for (uint256 facetIndex; facetIndex < _diamondCut.length; facetIndex++) {
            IDiamondCut.FacetCutAction action = _diamondCut[facetIndex].action;
            if (action == IDiamondCut.FacetCutAction.Add) {
                addFunctions(_diamondCut[facetIndex].facetAddress, _diamondCut[facetIndex].functionSelectors);
            } else if (action == IDiamondCut.FacetCutAction.Replace) {
                replaceFunctions(_diamondCut[facetIndex].facetAddress, _diamondCut[facetIndex].functionSelectors);
            } else if (action == IDiamondCut.FacetCutAction.Remove) {
                removeFunctions(_diamondCut[facetIndex].facetAddress, _diamondCut[facetIndex].functionSelectors);
            } else {
                revert("DiamondStorageLibCut: Incorrect FacetCutAction");
            }
        }
        emit DiamondCut(_diamondCut, _init, _calldata);
        initializeDiamondCut(_init, _calldata);
    }

    function addFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        require(_functionSelectors.length > 0, "DiamondStorageLibCut: No selectors in facet to cut");
        DiamondStorage storage ds = diamondStorage();
        require(_facetAddress != address(0), "DiamondStorageLibCut: Add facet can't be address(0)");
        uint96 selectorPosition = uint96(ds.facetFunctionSelectors[_facetAddress].functionSelectors.length);
        // add new facet address if it does not exist
        if (selectorPosition == 0) {
            addFacet(ds, _facetAddress);
        }
        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            address oldFacetAddress = ds.selectorToFacetAndPosition[selector].facetAddress;
            require(oldFacetAddress == address(0), "DiamondStorageLibCut: Can't add function that already exists");
            addFunction(ds, selector, selectorPosition, _facetAddress);
            selectorPosition++;
        }
    }

    function replaceFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        require(_functionSelectors.length > 0, "DiamondStorageLibCut: No selectors in facet to cut");
        DiamondStorage storage ds = diamondStorage();
        require(_facetAddress != address(0), "DiamondStorageLibCut: Add facet can't be address(0)");
        uint96 selectorPosition = uint96(ds.facetFunctionSelectors[_facetAddress].functionSelectors.length);
        // add new facet address if it does not exist
        if (selectorPosition == 0) {
            addFacet(ds, _facetAddress);
        }
        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            address oldFacetAddress = ds.selectorToFacetAndPosition[selector].facetAddress;
            require(oldFacetAddress != _facetAddress, "DiamondStorageLibCut: Can't replace function with same function");
            removeFunction(ds, oldFacetAddress, selector);
            addFunction(ds, selector, selectorPosition, _facetAddress);
            selectorPosition++;
        }
    }

    function removeFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        require(_functionSelectors.length > 0, "DiamondStorageLibCut: No selectors in facet to cut");
        DiamondStorage storage ds = diamondStorage();
        // if function does not exist then do nothing and return
        require(_facetAddress == address(0), "DiamondStorageLibCut: Remove facet address must be address(0)");
        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            address oldFacetAddress = ds.selectorToFacetAndPosition[selector].facetAddress;
            removeFunction(ds, oldFacetAddress, selector);
        }
    }

    function addFacet(DiamondStorage storage ds, address _facetAddress) internal {
        enforceHasContractCode(_facetAddress, "DiamondStorageLibCut: New facet has no code");
        ds.facetFunctionSelectors[_facetAddress].facetAddressPosition = ds.facetAddresses.length;
        ds.facetAddresses.push(_facetAddress);
    }


    function addFunction(DiamondStorage storage ds, bytes4 _selector, uint96 _selectorPosition, address _facetAddress) internal {
        ds.selectorToFacetAndPosition[_selector].functionSelectorPosition = _selectorPosition;
        ds.facetFunctionSelectors[_facetAddress].functionSelectors.push(_selector);
        ds.selectorToFacetAndPosition[_selector].facetAddress = _facetAddress;
    }

    function removeFunction(DiamondStorage storage ds, address _facetAddress, bytes4 _selector) internal {
        require(_facetAddress != address(0), "DiamondStorageLibCut: Can't remove function that doesn't exist");
        // an immutable function is a function defined directly in a diamond
        require(_facetAddress != address(this), "DiamondStorageLibCut: Can't remove immutable function");
        // replace selector with last selector, then delete last selector
        uint256 selectorPosition = ds.selectorToFacetAndPosition[_selector].functionSelectorPosition;
        uint256 lastSelectorPosition = ds.facetFunctionSelectors[_facetAddress].functionSelectors.length - 1;
        // if not the same then replace _selector with lastSelector
        if (selectorPosition != lastSelectorPosition) {
            bytes4 lastSelector = ds.facetFunctionSelectors[_facetAddress].functionSelectors[lastSelectorPosition];
            ds.facetFunctionSelectors[_facetAddress].functionSelectors[selectorPosition] = lastSelector;
            ds.selectorToFacetAndPosition[lastSelector].functionSelectorPosition = uint96(selectorPosition);
        }
        // delete the last selector
        ds.facetFunctionSelectors[_facetAddress].functionSelectors.pop();
        delete ds.selectorToFacetAndPosition[_selector];

        // if no more selectors for facet address then delete the facet address
        if (lastSelectorPosition == 0) {
            // replace facet address with last facet address and delete last facet address
            uint256 lastFacetAddressPosition = ds.facetAddresses.length - 1;
            uint256 facetAddressPosition = ds.facetFunctionSelectors[_facetAddress].facetAddressPosition;
            if (facetAddressPosition != lastFacetAddressPosition) {
                address lastFacetAddress = ds.facetAddresses[lastFacetAddressPosition];
                ds.facetAddresses[facetAddressPosition] = lastFacetAddress;
                ds.facetFunctionSelectors[lastFacetAddress].facetAddressPosition = facetAddressPosition;
            }
            ds.facetAddresses.pop();
            delete ds.facetFunctionSelectors[_facetAddress].facetAddressPosition;
        }
    }

    function initializeDiamondCut(address _init, bytes memory _calldata) internal {
        if (_init == address(0)) {
            require(_calldata.length == 0, "DiamondStorageLibCut: _init is address(0) but_calldata is not empty");
        } else {
            require(_calldata.length > 0, "DiamondStorageLibCut: _calldata is empty but _init is not address(0)");
            if (_init != address(this)) {
                enforceHasContractCode(_init, "DiamondStorageLibCut: _init address has no code");
            }
            (bool success, bytes memory error) = _init.delegatecall(_calldata);
            if (!success) {
                if (error.length > 0) {
                    // bubble up the error
                    revert(string(error));
                } else {
                    revert("DiamondStorageLibCut: _init function reverted");
                }
            }
        }
    }

    function enforceHasContractCode(address _contract, string memory _errorMessage) internal view {
        uint256 contractSize;
        assembly {
            contractSize := extcodesize(_contract)
        }
        require(contractSize > 0, _errorMessage);
    }

    event OwnedAssetAdded(bytes32 indexed asset, uint256 timestamp);

    event OwnedAssetRemoved(bytes32 indexed asset, uint256 timestamp);
}