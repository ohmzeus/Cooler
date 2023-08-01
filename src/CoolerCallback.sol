// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {CoolerFactory} from "src/CoolerFactory.sol";

/// @notice Allows for debt issuers to execute logic when a loan is repaid, rolled, or defaulted.
abstract contract CoolerCallback {

    CoolerFactory public immutable factory;

    constructor(address coolerFactory_) {
        factory = CoolerFactory(coolerFactory_);
    }

    function isCoolerCallback() external pure returns (bool) {
        return true;
    }

    function onDefault(uint256 loanID, uint256 amount, uint256 collateral) external virtual {        
        // Validate caller is cooler.
        require(factory.created(msg.sender), "ONLY_FROM_FACTORY");
        // Callback Logic
    }

    function onRepay(uint256 loanID, uint256 amount) external virtual {        
        // Validate caller is cooler.
        require(factory.created(msg.sender), "ONLY_FROM_FACTORY");
        // Callback Logic
    }

    function onRoll(uint256 loanID) external virtual {        
        // Validate caller is cooler.
        require(factory.created(msg.sender), "ONLY_FROM_FACTORY");
        // Callback Logic
    }
}