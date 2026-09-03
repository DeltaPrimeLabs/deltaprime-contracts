// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "@redstone-finance/evm-connector/contracts/core/RedstoneConstants.sol";

/**
 * @title TestAuthorisedSigners
 * @notice Abstract contract that maps the 5 deterministic DP test signers
 *         (derived from keccak256(abi.encodePacked("DP_RS_SIGNER", uint256(i))))
 *         to their indices 0-4.
 *
 * Addresses are pinned from RedstoneLib.signerAddresses output and verified
 * by testSignerAddressesAreDeterministic in RedstonePayload.t.sol.
 * NEVER hand-derive these addresses — copy from forge output only.
 *
 *   index 0: 0x8F0406923D6194ca9Ea874f99E58f315FE0fe321
 *   index 1: 0xB09678B8Fe02c23fc09B331D12b6EbB3DEc97c11
 *   index 2: 0xcAF6A6758a720732f286F269C6965E04CB204b09
 *   index 3: 0xf750Beb2910c22F8af4EeFC4aA4cCD01CB993B9a
 *   index 4: 0x23611a4AB4c9a7675f0C5E1eeBcb69b51Ddc04C1
 */
abstract contract TestAuthorisedSigners is RedstoneConstants {
    function _testSignerIndex(address signerAddress) internal pure returns (uint8) {
        if      (signerAddress == 0x8F0406923D6194ca9Ea874f99E58f315FE0fe321) return 0;
        else if (signerAddress == 0xB09678B8Fe02c23fc09B331D12b6EbB3DEc97c11) return 1;
        else if (signerAddress == 0xcAF6A6758a720732f286F269C6965E04CB204b09) return 2;
        else if (signerAddress == 0xf750Beb2910c22F8af4EeFC4aA4cCD01CB993B9a) return 3;
        else if (signerAddress == 0x23611a4AB4c9a7675f0C5E1eeBcb69b51Ddc04C1) return 4;
        else revert SignerNotAuthorised(signerAddress);
    }
}
