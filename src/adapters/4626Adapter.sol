// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IPriceAdapter } from "../interfaces/IPriceAdapter.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @dev Symmetric 4626 Vaults only.
contract ERC4626Adapter is IPriceAdapter {
    struct VaultDetails {
        IERC4626 vault; // ERC-4626 vault contract
    }

    VaultDetails public vaultData; // Vault details for the peg

    error ERC4626Adapter__InvalidSetup(uint256 code);

    constructor(
        IERC4626 _vault
    ) {
        require(address(_vault) != address(0), ERC4626Adapter__InvalidSetup(0));

        vaultData = VaultDetails({ vault: _vault });
    }

    function exchangeRate() external view override returns (uint256 answer, bool isStale) {
        answer = vaultData.vault.convertToAssets(1e18);

        isStale = false; // ERC-4626 vault prices are always current
    }
}
