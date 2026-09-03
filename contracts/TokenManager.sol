// SPDX-License-Identifier: BUSL-1.1
// Last deployed from commit: 8bb1bbce4ca086a317fdb2d35d3df26db87d96fe;
pragma solidity 0.8.17;

import "./lib/Bytes32EnumerableMap.sol";
import "./lib/LeverageTierLib.sol";
import "./interfaces/IBorrowersRegistry.sol";
import "./interfaces/IPool.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import {DynamicSlotMapping} from "./lib/DynamicSlotMapping.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./lib/DeploymentConstants.sol";

contract TokenManager is OwnableUpgradeable {
    /**
     * For adding supported assets
     **/
    struct Asset {
        bytes32 asset;
        address assetAddress;
        uint256 debtCoverage;
    }

    /**
     * For adding supported lending pools
     **/
    struct poolAsset {
        bytes32 asset;
        address poolAddress;
    }

    struct Exposure {
        uint256 current;
        uint256 max; // Setting max to 0 means no exposure limitations.
    }

    struct GmxMarkets {
        bool isWhitelisted;
        bool isPlusMarket;
    }

    /// Custom errors
    error InvalidAsset();
    error MaxDebtCoverageExceeded();
    error InvalidDebtCoverageTier();

    bytes32 constant GMX_MARKETS_WHITELISTED_MAPPING_SLOT = keccak256("gmx.markets.whitelisted.mapping.storage");
    bytes32 constant GMX_MARKETS_PLUS_MAPPING_SLOT = keccak256("gmx.markets.plus.mapping.storage");
    bytes32 constant GMX_MARKETS_GLV_MAPPING_SLOT = keccak256("gmx.markets.glv.mapping.storage");
    bytes32 constant CHAINLINK_FEEDS_MAPPING_SLOT = keccak256("chainlink.feeds.mapping.storage");
    bytes32 constant PARASWAP_EXECUTORS_WHITELISTED_MAPPING_SLOT = keccak256("paraswap.executors.whitelisted.mapping.storage");
    bytes32 constant DEPOSIT_SWAP_ADDRESS_SLOT = keccak256("deposit.swap.address.storage");

    using EnumerableMap for EnumerableMap.Bytes32ToAddressMap;

    uint256 private constant _NOT_SUPPORTED = 0;
    uint256 private constant _INACTIVE = 1;
    uint256 private constant _ACTIVE = 2;

    // Stores an asset's bytes32 symbol representation to pool's address mapping
    EnumerableMap.Bytes32ToAddressMap private assetToPoolAddress;
    // Stores an asset's bytes32 symbol representation to asset's address mapping
    EnumerableMap.Bytes32ToAddressMap private assetToTokenAddress;
    mapping(address => bytes32) public tokenAddressToSymbol;
    mapping(address => uint256) private tokenPositionInList;
    // used for defining different leverage ratios for tokens
    mapping(address => uint256) public debtCoverage;
    address[] public supportedTokensList;

    mapping(address => uint256) public tokenToStatus;
    // used for defining different leverage ratios for staked assets
    mapping(bytes32 => uint256) public debtCoverageStaked;

    mapping(bytes32 => bytes32) public identifierToExposureGroup;
    mapping(bytes32 => Exposure) public groupToExposure;

    mapping(address => mapping(bytes32 => uint256)) public pendingUserExposure;
    mapping(bytes32 => uint256) public pendingProtocolExposure;

    // DEPRECATED: vPrime/sPrime programme removed. Storage slot retained (do NOT delete or
    // reorder) to preserve the upgradeable TokenManager's layout for the vars that follow.
    address private __deprecated_vPrimeControllerAddress;

    // Mapping for recording per-user per-token (normalized) exposure
    mapping(address => mapping(bytes32 => uint256)) public recordedUserExposure;

    mapping(LeverageTierLib.LeverageTier => mapping(address => uint256)) public tieredDebtCoverage;

    mapping(LeverageTierLib.LeverageTier => uint256) public tieredPrimeStakingRatio;

    mapping(LeverageTierLib.LeverageTier => mapping(bytes32 => uint256)) public tieredDebtCoverageStaked;

    mapping(LeverageTierLib.LeverageTier => uint256) public tieredPrimeDebtRatio;

    address[] private unsupportedWithdrawableAssets;
    mapping(address => bool) private isUnsupportedWithdrawableAsset;

    function initialize(Asset[] memory tokenAssets, poolAsset[] memory poolAssets) external initializer {
        __Ownable_init();

        addTokenAssets(tokenAssets);
        addPoolAssets(poolAssets);
    }

    function getAllPoolAssets() public view returns (bytes32[] memory result) {
        return assetToPoolAddress._inner._keys._inner._values;
    }

    function getSupportedTokensAddresses() public view returns (address[] memory) {
        return supportedTokensList;
    }

    function getAllTokenAssets() public view returns (bytes32[] memory result) {
        return assetToTokenAddress._inner._keys._inner._values;
    }

    function getUnsupportedWithdrawableAssets() public view returns (address[] memory) {
        return unsupportedWithdrawableAssets;
    }

    function addUnsupportedWithdrawableAssets(address[] memory assets) external onlyOwner {
        for (uint256 i = 0; i < assets.length; i++) {
            require(assets[i] != address(0), "Invalid asset address");
            require(!isUnsupportedWithdrawableAsset[assets[i]], "Asset already added");
            
            unsupportedWithdrawableAssets.push(assets[i]);
            isUnsupportedWithdrawableAsset[assets[i]] = true;
            
            emit UnsupportedWithdrawalAssetAdded(msg.sender, assets[i], block.timestamp);
        }
    }

    function removeUnsupportedWithdrawableAssets(address[] memory assets) external onlyOwner {
        for (uint256 i = 0; i < assets.length; i++) {
            require(isUnsupportedWithdrawableAsset[assets[i]], "Asset not in list");
            
            // Find and remove the asset from the array
            for (uint256 j = 0; j < unsupportedWithdrawableAssets.length; j++) {
                if (unsupportedWithdrawableAssets[j] == assets[i]) {
                    // Move last element to current position and pop
                    unsupportedWithdrawableAssets[j] = unsupportedWithdrawableAssets[unsupportedWithdrawableAssets.length - 1];
                    unsupportedWithdrawableAssets.pop();
                    break;
                }
            }
            
            isUnsupportedWithdrawableAsset[assets[i]] = false;
            
            emit UnsupportedWithdrawalAssetRemoved(msg.sender, assets[i], block.timestamp);
        }
    }

    /**
    * Returns address of an asset
    **/
    function getAssetAddress(bytes32 _asset, bool allowInactive) public view returns (address) {
        (, address assetAddress) = assetToTokenAddress.tryGet(_asset);
        require(assetAddress != address(0), "Asset not supported.");
        if (!allowInactive) {
            require(tokenToStatus[assetAddress] == _ACTIVE, "Asset inactive");
        }

        return assetAddress;
    }

    /**
    * Returns address of an asset's lending pool
    **/
    function getPoolAddress(bytes32 _asset) public view returns (address) {
        (, address assetAddress) = assetToPoolAddress.tryGet(_asset);
        require(assetAddress != address(0), "Pool asset not supported.");

        return assetAddress;
    }
    

    /**
    * @notice Refactored original function to use internal implementation
    * @param user The PrimeAccount address
    * @param token The ERC20 token address
    */
    function updateUserExposure(address user, address token) public onlyPrimeAccountOrOwner {
        require(user != address(0), "Invalid user address");
        require(token != address(0), "Invalid token address");
        
        bytes32 symbol = tokenAddressToSymbol[token];
        require(symbol != bytes32(0), "Token not supported");
        
        _updateUserExposureInternal(user, token);
    }

    /**
    * @notice Batch update exposure for multiple users across all supported tokens
    * @dev This function can be gas-intensive. Consider the number of users and tokens before calling.
    * @dev Only owner can perform batch operations as this is an administrative function
    * @param users Array of PrimeAccount addresses to update
    */
    function batchUpdateUserExposure(address[] memory users) external onlyOwner {
        require(users.length > 0, "Empty users array");
        
        IBorrowersRegistry borrowersRegistry = IBorrowersRegistry(getSmartLoansFactoryAddress());
        address[] memory tokens = getSupportedTokensAddresses();
        
        for (uint256 i = 0; i < users.length; i++) {
            require(users[i] != address(0), "Invalid user address");
            
            // Validate that the user is a valid PrimeAccount
            require(borrowersRegistry.canBorrow(users[i]), "User is not a valid PrimeAccount");
            
            for (uint256 j = 0; j < tokens.length; j++) {
                _updateUserExposureInternal(users[i], tokens[j]);
            }
            
            emit BatchUserExposureUpdated(users[i], tokens.length, block.timestamp);
        }
        
        emit BatchExposureUpdateCompleted(users.length, tokens.length, block.timestamp);
    }

    /**
    * @notice Internal function to update exposure for a single user-token pair
    * @param user The PrimeAccount address
    * @param token The ERC20 token address
    * @dev This function now reverts on unsupported tokens for consistency with the public method
    */
    function _updateUserExposureInternal(address user, address token) internal {
        bytes32 symbol = tokenAddressToSymbol[token];
        require(symbol != bytes32(0), "Token not supported");

        // Get current token balance of the user and normalize it to 1e18.
        uint256 currentBalance = IERC20Metadata(token).balanceOf(user);
        uint256 decimals = IERC20Metadata(token).decimals();
        uint256 normalizedCurrent = currentBalance * 1e18 / (10 ** decimals);

        // Get the last recorded exposure from our new mapping.
        uint256 lastRecorded = recordedUserExposure[user][symbol];

        if (normalizedCurrent > lastRecorded) {
            uint256 diff = normalizedCurrent - lastRecorded;
            recordedUserExposure[user][symbol] = normalizedCurrent;
            // Increase the global exposure by the positive difference.
            increaseProtocolExposure(symbol, diff);
        } else if (lastRecorded > normalizedCurrent) {
            uint256 diff = lastRecorded - normalizedCurrent;
            recordedUserExposure[user][symbol] = normalizedCurrent;
            // Decrease the global exposure by the negative difference.
            decreaseProtocolExposure(symbol, diff);
        }
        // If they are equal, nothing changes.
    }


    function increaseProtocolExposure(bytes32 assetIdentifier, uint256 exposureIncrease) public onlyPrimeAccountOrOwner {
        bytes32 group = identifierToExposureGroup[assetIdentifier];
        if(group != ""){
            Exposure storage exposure = groupToExposure[group];
            exposure.current += exposureIncrease;
            if(exposure.max != 0) {
                require(exposure.current <= exposure.max, "Max asset exposure breached");
            }
            emit ProtocolExposureChanged(msg.sender, group, exposure.current, block.timestamp);
        }
    }


    function decreaseProtocolExposure(bytes32 assetIdentifier, uint256 exposureDecrease) public onlyPrimeAccountOrOwner {
        bytes32 group = identifierToExposureGroup[assetIdentifier];
        if(group != ""){
            Exposure storage exposure = groupToExposure[group];
            if(exposure.current <= exposureDecrease) {
                exposure.current = 0;
            } else {
                exposure.current -= exposureDecrease;
            }
            emit ProtocolExposureChanged(msg.sender, group, exposure.current, block.timestamp);
        }
    }


    function setCurrentProtocolExposure(bytes32[] memory groupIdentifiers, uint256[] memory currentExposures) external onlyOwner {
        require(groupIdentifiers.length == currentExposures.length, "Arrays lengths mismatch");
        for (uint256 i = 0; i < groupIdentifiers.length; i++) {
            _setCurrentProtocolExposure(groupIdentifiers[i], currentExposures[i]);
        }
    }

    function setMaxProtocolsExposure(bytes32[] memory groupIdentifiers, uint256[] memory maxExposures) public onlyOwner {
        require(groupIdentifiers.length == maxExposures.length, "Arrays lengths mismatch");
        for (uint256 i = 0; i < groupIdentifiers.length; i++) {
            _setMaxProtocolExposure(groupIdentifiers[i], maxExposures[i]);
        }
    }

    function _setMaxProtocolExposure(bytes32 groupIdentifier, uint256 maxExposure) internal {
        require(groupIdentifier != "", "Cannot set an empty string asset.");
        uint256 prevExposure = groupToExposure[groupIdentifier].max;
        groupToExposure[groupIdentifier].max = maxExposure;

        emit ProtocolExposureSet(msg.sender, groupIdentifier, prevExposure, maxExposure, groupToExposure[groupIdentifier].current , block.timestamp);
    }

    function _setCurrentProtocolExposure(bytes32 groupIdentifier, uint256 currentExposure) internal {
        require(groupIdentifier != "", "Cannot set an empty string asset.");
        uint256 prevExposure = groupToExposure[groupIdentifier].current;
        groupToExposure[groupIdentifier].current = currentExposure;

        emit ProtocolCurrentExposureSet(msg.sender, groupIdentifier, prevExposure, currentExposure, block.timestamp);
    }

    function setIdentifiersToExposureGroups(bytes32[] memory identifiers, bytes32[] memory exposureGroups) public onlyOwner {
        require(identifiers.length == exposureGroups.length, "Arrays lengths mismatch");
        for(uint i=0; i<identifiers.length; i++){
            identifierToExposureGroup[identifiers[i]] = exposureGroups[i];
            emit IdentifierToExposureGroupSet(msg.sender, identifiers[i], exposureGroups[i], block.timestamp);
        }

    }

    function addPoolAssets(poolAsset[] memory poolAssets) public onlyOwner {
        for (uint256 i = 0; i < poolAssets.length; i++) {
            _addPoolAsset(poolAssets[i].asset, poolAssets[i].poolAddress);
        }
    }

    function _addPoolAsset(bytes32 _asset, address _poolAddress) internal {
        require(Address.isContract(_poolAddress), "TokenManager: Pool must be a contract");
        require(!assetToPoolAddress.contains(_asset), "Asset's pool already exists");
        assetToPoolAddress.set(_asset, _poolAddress);
        emit PoolAssetAdded(msg.sender, _asset, _poolAddress, block.timestamp);
    }

    function addTokenAssets(Asset[] memory tokenAssets) public onlyOwner {
        for (uint256 i = 0; i < tokenAssets.length; i++) {
            _addTokenAsset(tokenAssets[i].asset, tokenAssets[i].assetAddress, tokenAssets[i].debtCoverage);
        }
    }

    function isTokenAssetActive(address token) external view returns(bool) {
        return tokenToStatus[token] == _ACTIVE;
    }

    function activateToken(address token) public onlyOwner {
        require(tokenToStatus[token] == _INACTIVE, "Must be inactive");
        tokenToStatus[token] = _ACTIVE;
        emit TokenAssetActivated(msg.sender, token, block.timestamp);
    }

    function deactivateToken(address token) public onlyOwner {
        require(tokenToStatus[token] == _ACTIVE, "Must be active");
        tokenToStatus[token] = _INACTIVE;
        emit TokenAssetDeactivated(msg.sender, token, block.timestamp);
    }

    function _addTokenAsset(bytes32 _asset, address _tokenAddress, uint256 _debtCoverage) internal {
        require(_asset != "", "Cannot set an empty string asset.");
        require(_tokenAddress != address(0), "Cannot set an empty address.");
        require(!assetToTokenAddress.contains(_asset), "Asset's token already exists");
        require(tokenAddressToSymbol[_tokenAddress] == 0, "Asset address is already in use");
        setDebtCoverage(_tokenAddress, _debtCoverage);

        assetToTokenAddress.set(_asset, _tokenAddress);
        tokenAddressToSymbol[_tokenAddress] = _asset;
        tokenToStatus[_tokenAddress] = _ACTIVE;

        supportedTokensList.push(_tokenAddress);
        tokenPositionInList[_tokenAddress] = supportedTokensList.length - 1;

        emit TokenAssetAdded(msg.sender, _asset, _tokenAddress, block.timestamp);
    }

    function _removeTokenFromList(address tokenToRemove) internal {
        // Move last address token to the `tokenToRemoveIndex` position (index of an asset that is being removed) in the address[] supportedTokensList
        // and update map(address=>uint256) tokenPostitionInList if the token is not already the last element
        uint256 tokenToRemoveIndex = tokenPositionInList[tokenToRemove];
        require(tokenToRemoveIndex < supportedTokensList.length, "Index out of range");
        if (tokenToRemoveIndex == 0 && supportedTokensList[0] != tokenToRemove) {
            revert("Token does not exist");
        }
        if (tokenToRemoveIndex != (supportedTokensList.length - 1)) {
            address currentLastToken = supportedTokensList[supportedTokensList.length - 1];
            tokenPositionInList[currentLastToken] = tokenToRemoveIndex;
            supportedTokensList[tokenToRemoveIndex] = currentLastToken;
        }
        // Remove last element - that is either the token that is being removed (if was already at the end)
        // or some other asset that at this point was already copied to the `index` positon
        supportedTokensList.pop();
        tokenPositionInList[tokenToRemove] = 0;
    }

    function removeTokenAssets(bytes32[] memory _tokenAssets) public onlyOwner {
        for (uint256 i = 0; i < _tokenAssets.length; i++) {
            _removeTokenAsset(_tokenAssets[i]);
        }
    }

    function _removeTokenAsset(bytes32 _tokenAsset) internal {
        address tokenAddress = getAssetAddress(_tokenAsset, true);

        // Remove from main asset mappings
        EnumerableMap.remove(assetToTokenAddress, _tokenAsset);
        tokenAddressToSymbol[tokenAddress] = 0;
        tokenToStatus[tokenAddress] = _NOT_SUPPORTED;
        debtCoverage[tokenAddress] = 0;

        // Clear staked debt coverage
        debtCoverageStaked[_tokenAsset] = 0;

        // Clear tiered debt coverages for all tiers
        tieredDebtCoverage[LeverageTierLib.LeverageTier.BASIC][tokenAddress] = 0;
        tieredDebtCoverage[LeverageTierLib.LeverageTier.PREMIUM][tokenAddress] = 0;
        tieredDebtCoverageStaked[LeverageTierLib.LeverageTier.BASIC][_tokenAsset] = 0;
        tieredDebtCoverageStaked[LeverageTierLib.LeverageTier.PREMIUM][_tokenAsset] = 0;

        // Clear exposure group mapping for this asset
        identifierToExposureGroup[_tokenAsset] = bytes32(0);

        // Clear any pending exposures
        pendingProtocolExposure[_tokenAsset] = 0;

        // Remove from supported tokens list
        _removeTokenFromList(tokenAddress);

        emit TokenAssetRemoved(msg.sender, _tokenAsset, block.timestamp);
        emit IdentifierToExposureGroupSet(msg.sender, _tokenAsset, bytes32(0), block.timestamp);
    }

    function removePoolAssets(bytes32[] memory _poolAssets) public onlyOwner {
        for (uint256 i = 0; i < _poolAssets.length; i++) {
            _removePoolAsset(_poolAssets[i]);
        }
    }

    function _removePoolAsset(bytes32 _poolAsset) internal {
        address poolAddress = getPoolAddress(_poolAsset);
        require(IPool(poolAddress).totalBorrowed() == 0, "Pool must have no outstanding borrows");
        EnumerableMap.remove(assetToPoolAddress, _poolAsset);
        emit PoolAssetRemoved(msg.sender, _poolAsset, poolAddress, block.timestamp);
    }

    function setDebtCoverage(address token, uint256 coverage) public onlyOwner {
        //LTV must be lower than 5
        require(coverage <= 0.833333333333333333e18, 'Debt coverage higher than maximum acceptable');
        debtCoverage[token] = coverage;
    }

    function setDebtCoverageStaked(bytes32 stakedAsset, uint256 coverage) public onlyOwner {
        //LTV must be lower than 5
        require(coverage <= 0.833333333333333333e18, 'Debt coverage higher than maximum acceptable');
        debtCoverageStaked[stakedAsset] = coverage;
    }

     /**
     * @notice Set debt coverage for a specific tier and token
     * @param tier The leverage tier
     * @param tokenAddress The token address  
     * @param debtCoverageValue The debt coverage value
     */
    function setTieredDebtCoverage(LeverageTierLib.LeverageTier tier, address tokenAddress, uint256 debtCoverageValue) external onlyOwner {
        require(tokenAddress != address(0), "Invalid token address");
        if (tier >= LeverageTierLib.LeverageTier._NON_EXISTENT) {
            revert InvalidDebtCoverageTier();
        }
        if (tier == LeverageTierLib.LeverageTier.BASIC) {
            //LTV must be lower than 5
            if (debtCoverageValue > 0.833333333333333333e18) {
                revert MaxDebtCoverageExceeded();
            }
        }
        else if (tier == LeverageTierLib.LeverageTier.PREMIUM) {
            //LTV must be lower than 10
            if (debtCoverageValue > 0.909090909090909090e18) {
                revert MaxDebtCoverageExceeded();
            }
        } else {
            revert InvalidDebtCoverageTier();
        }
        tieredDebtCoverage[tier][tokenAddress] = debtCoverageValue;
        
        emit TieredDebtCoverageSet(tier, tokenAddress, debtCoverageValue, msg.sender, block.timestamp);
    }

    function setTieredDebtCoverageStaked(LeverageTierLib.LeverageTier tier, bytes32 stakedAsset, uint256 debtCoverageValue) external onlyOwner {
        require(stakedAsset != bytes32(0), "Invalid staked asset");
        if (tier >= LeverageTierLib.LeverageTier._NON_EXISTENT) {
            revert InvalidDebtCoverageTier();
        }
        if (tier == LeverageTierLib.LeverageTier.BASIC) {
            //LTV must be lower than 5
            if (debtCoverageValue > 0.833333333333333333e18) {
                revert MaxDebtCoverageExceeded();
            }
        }
        else if (tier == LeverageTierLib.LeverageTier.PREMIUM) {
            //LTV must be lower than 10
            if (debtCoverageValue > 0.909090909090909090e18) {
                revert MaxDebtCoverageExceeded();
            }
        } else {
            revert InvalidDebtCoverageTier();
        }
        
        tieredDebtCoverageStaked[tier][stakedAsset] = debtCoverageValue;
    }

    
    
    ///@notice Sets the prime debt ratio, which is the amount of PRIME tokens debt/fees per $100 borrowed while on PREMIUM tier.
    ///@dev The ratio expressed in 18 decimal precision
    function setTieredPrimeDebtRatio(LeverageTierLib.LeverageTier tier, uint256 ratio) external onlyOwner {
    /// @dev moving PrimeDebtRatio from DiamondStorageLib to TokenManager 
    /// reasoning: while debt accrual changes, debt ratio remains the same throughout for a given tier, 
    /// so it makes sense to store it in TokenManager, rather than initializing the value as 2e18 while activating Premium (which was the previous case)
    /// BASIC would have debt ratio of 0, PREMIUM would have debt ratio of 2e18
        tieredPrimeDebtRatio[tier] = ratio;
    }


    /// @notice Set the prime staking ratio for a specific leverage tier in 18 decimals (1e18)
    function setTieredPrimeStakingRatio(LeverageTierLib.LeverageTier tier, uint256 ratio) external onlyOwner {
        require(ratio > 0, "Staking ratio must be greater than 0");
        tieredPrimeStakingRatio[tier] = ratio;
    }

    /**
    * @notice Set GMX market configuration (whitelisted status and plus market status)
    * @param gmxMarket The GMX market address
    * @param isWhitelisted Whether the market is whitelisted
    * @param isPlusMarket Whether the market is a plus market
    */
    function setGmxMarket(address gmxMarket, bool isWhitelisted, bool isPlusMarket) external onlyOwner {
        require(gmxMarket != address(0), "Invalid GMX market address");
        
        // Get previous values for events
        bool prevWhitelisted = isGmxMarketWhitelisted(gmxMarket);
        bool prevPlusMarket = isGmxPlusMarket(gmxMarket);
        
        DynamicSlotMapping.setBool(GMX_MARKETS_WHITELISTED_MAPPING_SLOT, gmxMarket, isWhitelisted);
        DynamicSlotMapping.setBool(GMX_MARKETS_PLUS_MAPPING_SLOT, gmxMarket, isPlusMarket);
        
        emit GmxMarketConfigured(msg.sender, gmxMarket, prevWhitelisted, isWhitelisted, prevPlusMarket, isPlusMarket, block.timestamp);
    }

    /**
    * @notice Set GLV token configuration (whitelisted status)
    * @dev Updates the whitelisted status of a GLV token in the TokenManager.
    * @param glvToken The GLV token address to configure
    * @param isWhitelisted Whether the GLV token should be whitelisted (true) or removed from whitelist (false)
    */
    function setGlvTokenWhitelisting(address glvToken, bool isWhitelisted) external onlyOwner {
        require(glvToken != address(0), "Invalid GLV token address");
        
        // Get previous values for events
        bool prevWhitelisted = DynamicSlotMapping.getBool(GMX_MARKETS_GLV_MAPPING_SLOT, glvToken);
        
        DynamicSlotMapping.setBool(GMX_MARKETS_GLV_MAPPING_SLOT, glvToken, isWhitelisted);
        
        emit GlvTokenConfigured(msg.sender, glvToken, prevWhitelisted, isWhitelisted, block.timestamp);
    }

    function isGlvTokenWhitelisted(address glvToken) public view returns (bool) {
        return DynamicSlotMapping.getBool(GMX_MARKETS_GLV_MAPPING_SLOT, glvToken);
    }

    /**
    * @notice Check if GMX market is whitelisted
    * @param gmxMarket The GMX market address
    * @return True if the market is whitelisted
    */
    function isGmxMarketWhitelisted(address gmxMarket) public view returns (bool) {
        return DynamicSlotMapping.getBool(GMX_MARKETS_WHITELISTED_MAPPING_SLOT, gmxMarket);
    }
    
    /**
    * @notice Check if GMX market is a plus market
    * @param gmxMarket The GMX market address
    * @return True if the market is a plus market
    */
    function isGmxPlusMarket(address gmxMarket) public view returns (bool) {
        return DynamicSlotMapping.getBool(GMX_MARKETS_PLUS_MAPPING_SLOT, gmxMarket);
    }


    /**
    * @notice Whitelists ParaSwap executor addresses
    * @dev ParaSwap executors used to be hardcoded in ParaSwapHelper, which meant every ParaSwap
    *      router/executor rotation required a facet redeploy + diamondCut. They now live in the
    *      TokenManager so they can be added/removed by the owner without touching bytecode.
    *      Idempotent: already-whitelisted executors are silently skipped (no event, no revert),
    *      so a batch may be re-sent safely.
    * @param executors The executor addresses to whitelist
    */
    function whitelistParaSwapExecutors(address[] calldata executors) external onlyOwner {
        for (uint256 i; i < executors.length; ++i) {
            address executor = executors[i];
            require(executor != address(0), "Invalid executor address");
            if (DynamicSlotMapping.getBool(PARASWAP_EXECUTORS_WHITELISTED_MAPPING_SLOT, executor)) continue;

            DynamicSlotMapping.setBool(PARASWAP_EXECUTORS_WHITELISTED_MAPPING_SLOT, executor, true);
            emit ParaSwapExecutorWhitelisted(msg.sender, executor, block.timestamp);
        }
    }

    /**
    * @notice Removes ParaSwap executor addresses from the whitelist
    * @dev Idempotent: executors that are not whitelisted are silently skipped.
    * @param executors The executor addresses to delist
    */
    function delistParaSwapExecutors(address[] calldata executors) external onlyOwner {
        for (uint256 i; i < executors.length; ++i) {
            address executor = executors[i];
            if (!DynamicSlotMapping.getBool(PARASWAP_EXECUTORS_WHITELISTED_MAPPING_SLOT, executor)) continue;

            DynamicSlotMapping.setBool(PARASWAP_EXECUTORS_WHITELISTED_MAPPING_SLOT, executor, false);
            emit ParaSwapExecutorDelisted(msg.sender, executor, block.timestamp);
        }
    }

    /**
    * @notice Checks whether an address is a whitelisted ParaSwap executor
    * @param executor The executor address to check
    * @return True if the executor is whitelisted
    */
    function isParaSwapExecutorWhitelisted(address executor) public view returns (bool) {
        return DynamicSlotMapping.getBool(PARASWAP_EXECUTORS_WHITELISTED_MAPPING_SLOT, executor);
    }

    /**
    * @notice Enables the DepositSwap contract for Pool.withdrawInstant()
    * @dev Does NOT grant the bypass on its own: Pool checks msg.sender against its compiled-in
    *      DeploymentChainConfig.DEPOSIT_SWAP as well, so granting still requires a Pool upgrade
    *      (TUP timelock). This flag only enables/revokes that address. Single active address:
    *      whitelisting a new one delists the previous. Idempotent.
    * @param depositSwap The DepositSwap contract address to whitelist
    */
    function whitelistDepositSwap(address depositSwap) external onlyOwner {
        require(depositSwap != address(0), "Invalid DepositSwap address");
        // Same check _addPoolAsset applies: an EOA or not-yet-deployed address would leave
        // withdrawInstant disabled protocol-wide until someone noticed.
        require(Address.isContract(depositSwap), "DepositSwap must be a contract");
        address previous = getDepositSwapAddress();
        // Idempotent so a replayed batch is safe. delistDepositSwap() is deliberately NOT
        // idempotent: revoking nothing is an operator error worth surfacing.
        if (previous == depositSwap) return;

        _setDepositSwapAddress(depositSwap);
        emit DepositSwapWhitelisted(msg.sender, depositSwap, previous, block.timestamp);
    }

    /**
    * @notice Revokes the withdrawInstant bypass immediately (kill-switch)
    * @dev Pool.withdrawInstant() reverts for every caller afterwards, without waiting for a
    *      Pool upgrade.
    */
    function delistDepositSwap() external onlyOwner {
        address previous = getDepositSwapAddress();
        require(previous != address(0), "No DepositSwap whitelisted");

        _setDepositSwapAddress(address(0));
        emit DepositSwapDelisted(msg.sender, previous, block.timestamp);
    }

    /**
    * @notice The DepositSwap contract currently enabled for Pool.withdrawInstant()
    * @return depositSwap The enabled DepositSwap address, or address(0) when none is set
    */
    function getDepositSwapAddress() public view returns (address depositSwap) {
        bytes32 slot = DEPOSIT_SWAP_ADDRESS_SLOT;
        // Mask to 20 bytes so the invariant holds locally instead of depending on every
        // future writer to this slot passing through the ABI decoder.
        assembly { depositSwap := and(sload(slot), 0xffffffffffffffffffffffffffffffffffffffff) }
    }

    /**
    * @notice Checks whether an address is the enabled DepositSwap
    * @param candidate The address to check
    * @return True if `candidate` is the active DepositSwap
    */
    function isDepositSwapWhitelisted(address candidate) public view returns (bool) {
        return candidate != address(0) && candidate == getDepositSwapAddress();
    }

    function _setDepositSwapAddress(address depositSwap) private {
        bytes32 slot = DEPOSIT_SWAP_ADDRESS_SLOT;
        assembly { sstore(slot, depositSwap) }
    }

    /// @notice Sets the Chainlink price feed address for a specific token
    /// @dev Stores the feed address in a dynamic storage slot mapping. Only callable by the contract owner
    /// @param token The address of the token for which to set the Chainlink feed
    /// @param feed The address of the Chainlink price feed contract
    function setChainlinkFeed(address token, address feed) external onlyOwner {
        require(token != address(0), "Invalid token address");
        DynamicSlotMapping.setAddress(CHAINLINK_FEEDS_MAPPING_SLOT, token, feed);
        emit ChainLinkFeedSet(msg.sender, token, feed, block.timestamp);
    }

    /// @notice Retrieves the Chainlink price feed address for a specific token
    /// @dev Reads from the dynamic storage slot mapping
    /// @param token The address of the token for which to retrieve the Chainlink feed
    /// @return The address of the Chainlink price feed contract, or address(0) if not set
    function getChainlinkFeed(address token) external view returns (address) {
        return DynamicSlotMapping.getAddress(CHAINLINK_FEEDS_MAPPING_SLOT, token);
    }

    function isExposureAvailable(bytes32 assetIdentifier) internal view returns(bool) {
        bytes32 group = identifierToExposureGroup[assetIdentifier];
        if(group != ""){
            Exposure memory exposure = groupToExposure[group];
            if(exposure.max != 0){
                if(exposure.max <= exposure.current + pendingProtocolExposure[assetIdentifier]) {
                    return false;
                }
            }
        }
        return true;
    }

    function increasePendingExposure(bytes32 assetIdentifier, address user, uint256 amount) public onlyPrimeAccountOrOwner {
        pendingUserExposure[user][assetIdentifier] += amount;
        pendingProtocolExposure[assetIdentifier] += amount;
        
        require(isExposureAvailable(assetIdentifier), "Lack of Exposure");
    }

    function setPendingExposureToZero(bytes32 assetIdentifier, address user) public onlyPrimeAccountOrOwner {
        uint256 pending = pendingUserExposure[user][assetIdentifier];
        if(pending > 0) {
            pendingProtocolExposure[assetIdentifier] -= pending;
            pendingUserExposure[user][assetIdentifier] = 0;
        }
    }

    function getSmartLoansFactoryAddress() public view virtual returns (address) {
        return DeploymentConstants.getSmartLoansFactoryAddress();
    }

    /* ========== OVERRIDDEN FUNCTIONS ========== */

    function renounceOwnership() public virtual override {}

    /* ========== MODIFIERS ========== */

    modifier onlyPrimeAccountOrOwner() {
        IBorrowersRegistry borrowersRegistry = IBorrowersRegistry(getSmartLoansFactoryAddress());
        require(borrowersRegistry.canBorrow(msg.sender) || owner() == _msgSender(), "Only PrimeAccount or owner can change protocol exposure");
        _;
    }

    /**
     * @dev emitted after changing current protocol exposure
     * @param performer an address of the wallet changing the exposure
     * @param identifier group identifier
     * @param newExposure new current protocol exposure
     * @param timestamp time of associating identifier with a exposure group
     **/
    event ProtocolExposureChanged(address indexed performer, bytes32 indexed identifier, uint256 newExposure, uint256 timestamp);


    /**
     * @dev emitted after associating identifier with a exposure group
     * @param performer an address of the wallet setting max exposure
     * @param identifier asset identifier
     * @param exposureGroup exposure group identifier
     * @param timestamp time of associating identifier with a exposure group
     **/
    event IdentifierToExposureGroupSet(address indexed performer, bytes32 indexed identifier, bytes32 indexed exposureGroup, uint256 timestamp);

    /**
     * @dev emitted after setting max exposure for a given protocol.
     * @param performer an address of the wallet setting max exposure
     * @param groupIdentifier exposure group identifier
     * @param prevMaxExposure previous max protocol exposure
     * @param newMaxExposure new max protocol exposure
     * @param currentExposure current protocol exposure
     * @param timestamp time of setting max exposure
     **/
    event ProtocolExposureSet(address indexed performer, bytes32 indexed groupIdentifier, uint256 prevMaxExposure, uint256 newMaxExposure, uint256 currentExposure, uint256 timestamp);


    /**
         * @dev emitted after setting max exposure for a given protocol.
     * @param performer an address of the wallet setting max exposure
     * @param groupIdentifier exposure group identifier
     * @param prevCurrentExposure previous max protocol exposure
     * @param newCurrentExposure new max protocol exposure
     * @param timestamp time of setting max exposure
     **/
    event ProtocolCurrentExposureSet(address indexed performer, bytes32 indexed groupIdentifier, uint256 prevCurrentExposure, uint256 newCurrentExposure, uint256 timestamp);



    /**
     * @dev emitted after adding a token asset
     * @param performer an address of the wallet adding a token asset
     * @param tokenAsset token asset
     * @param assetAddress an address of the token asset
     * @param timestamp time of adding a token asset
     **/
    event TokenAssetAdded(address indexed performer, bytes32 indexed tokenAsset, address assetAddress, uint256 timestamp);

    /**
     * @dev emitted after activating a token asset
     * @param performer an address of the wallet activating a token asset
     * @param assetAddress an address of the token asset
     * @param timestamp time of activating a token asset
     **/
    event TokenAssetActivated(address indexed performer, address assetAddress, uint256 timestamp);

    /**
     * @dev emitted after deactivating a token asset
     * @param performer an address of the wallet deactivating a token asset
     * @param assetAddress an address of the token asset
     * @param timestamp time of deactivating a token asset
     **/
    event TokenAssetDeactivated(address indexed performer, address assetAddress, uint256 timestamp);

    /**
     * @dev emitted after removing a token asset
     * @param performer an address of the wallet removing a token asset
     * @param tokenAsset token asset
     * @param timestamp time a token asset removal
     **/
    event TokenAssetRemoved(address indexed performer, bytes32 indexed tokenAsset, uint256 timestamp);

    /**
     * @dev emitted after adding a pool asset
     * @param performer an address of wallet adding the pool asset
     * @param poolAsset pool asset
     * @param poolAddress an address of the pool asset
     * @param timestamp time of the pool asset addition
     **/
    event PoolAssetAdded(address indexed performer, bytes32 indexed poolAsset, address poolAddress, uint256 timestamp);

    /**
     * @dev emitted after removing a pool asset
     * @param performer an address of wallet removing the pool asset
     * @param poolAsset pool asset
     * @param poolAddress an address of the pool asset
     * @param timestamp time of a pool asset removal
     **/
    event PoolAssetRemoved(address indexed performer, bytes32 indexed poolAsset, address poolAddress, uint256 timestamp);

    /**
    * @dev Emitted when debt coverage is set for a specific leverage tier and token.
    * 
    * Debt coverage represents the maximum loan-to-value ratio for borrowing against token collateral.
    * - BASIC tier: Max 83.33% (0.833333333333333333e18)
    * - PREMIUM tier: Max 90.91% (0.909090909090909090e18)
    * 
    * @param tier The leverage tier (BASIC or PREMIUM)
    * @param tokenAddress The ERC20 token address
    * @param debtCoverage The debt coverage ratio in 18-decimal precision (1e18 = 100%)
    * @param admin The contract owner who set this configuration
    * @param timestamp Block timestamp of the configuration change
    */
    event TieredDebtCoverageSet(
        LeverageTierLib.LeverageTier indexed tier, 
        address indexed tokenAddress, 
        uint256 indexed debtCoverage, 
        address admin, 
        uint256 timestamp
    );

    /**
    * @dev emitted after updating exposure for a user across multiple tokens
    * @param user the user address that was updated
    * @param tokenCount number of tokens processed for this user
    * @param timestamp time of the update
    **/
    event BatchUserExposureUpdated(address indexed user, uint256 tokenCount, uint256 timestamp);

    /**
    * @dev emitted after completing a batch exposure update operation
    * @param userCount number of users processed
    * @param tokenCount number of tokens processed per user
    * @param timestamp time of completion
    **/
    event BatchExposureUpdateCompleted(uint256 userCount, uint256 tokenCount, uint256 timestamp);

    /**
    * @dev Emitted when GMX market configuration is updated
    * @param performer Address that updated the configuration
    * @param gmxMarket GMX market address
    * @param prevWhitelisted Previous whitelisted status
    * @param newWhitelisted New whitelisted status
    * @param prevPlusMarket Previous plus market status
    * @param newPlusMarket New plus market status
    * @param timestamp Block timestamp
    */
    event GmxMarketConfigured(
        address indexed performer,
        address indexed gmxMarket,
        bool prevWhitelisted,
        bool newWhitelisted,
        bool prevPlusMarket,
        bool newPlusMarket,
        uint256 timestamp
    );

    /**
     * @dev Emitted when an unsupported withdrawal asset is added
     * @param performer Address that added the asset
     * @param asset Asset address that was added
     * @param timestamp Block timestamp
     */
    event UnsupportedWithdrawalAssetAdded(
        address indexed performer,
        address indexed asset,
        uint256 timestamp
    );

    /**
     * @dev Emitted when an unsupported withdrawal asset is removed
     * @param performer Address that removed the asset
     * @param asset Asset address that was removed  
     * @param timestamp Block timestamp
     */
    event UnsupportedWithdrawalAssetRemoved(
        address indexed performer,
        address indexed asset,
        uint256 timestamp
    );

    event GlvTokenConfigured(
        address indexed performer,
        address indexed glvToken,
        bool prevWhitelisted,
        bool newWhitelisted,
        uint256 timestamp
    );

    event ChainLinkFeedSet(
        address indexed performer,
        address indexed token,
        address indexed feed,
        uint256 timestamp
    );

    /**
     * @dev Emitted when the active DepositSwap contract is set (or replaced)
     * @param performer Address that whitelisted the DepositSwap
     * @param depositSwap The DepositSwap address that is now active
     * @param previous The DepositSwap address it replaced
     * @param timestamp Block timestamp
     */
    event DepositSwapWhitelisted(
        address indexed performer,
        address indexed depositSwap,
        address indexed previous,
        uint256 timestamp
    );

    /**
     * @dev Emitted when the active DepositSwap contract is removed
     * @param performer Address that delisted the DepositSwap
     * @param depositSwap The DepositSwap address that was delisted
     * @param timestamp Block timestamp
     */
    event DepositSwapDelisted(
        address indexed performer,
        address indexed depositSwap,
        uint256 timestamp
    );

    /**
     * @dev Emitted when a ParaSwap executor is added to the whitelist
     * @param performer Address that whitelisted the executor
     * @param executor Executor address that was whitelisted
     * @param timestamp Block timestamp
     */
    event ParaSwapExecutorWhitelisted(
        address indexed performer,
        address indexed executor,
        uint256 timestamp
    );

    /**
     * @dev Emitted when a ParaSwap executor is removed from the whitelist
     * @param performer Address that delisted the executor
     * @param executor Executor address that was delisted
     * @param timestamp Block timestamp
     */
    event ParaSwapExecutorDelisted(
        address indexed performer,
        address indexed executor,
        uint256 timestamp
    );
}
