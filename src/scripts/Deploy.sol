// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.15;

import {Script, console2} from "forge-std/Script.sol";

// Cooler Loans
import {CoolerFactory, Cooler} from "src/CoolerFactory.sol";

/// @notice Script to deploy and initialize the Olympus system
/// @dev    The address that this script is broadcast from must have write access to the contracts being configured
contract Deploy is Script {
    // Cooler Loan contracts
    CoolerFactory public coolerFactory;

    function deploy() external {
            // Deploy a new Cooler Factory implementation
            vm.broadcast();
            coolerFactory = new CoolerFactory();
            console2.log("Cooler Factory deployed at:", address(coolerFactory));
    }
}
