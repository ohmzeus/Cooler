// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {CoolerCallback} from "src/CoolerCallback.sol";
import {Cooler} from "src/Cooler.sol";

contract MockLender is CoolerCallback {
    constructor(address coolerFactory_) CoolerCallback(coolerFactory_) {}
    
    /// @notice Callback function that handles repayments. Override for custom logic.
    function _onRepay(uint256 loanID_, uint256 principleAmount_, uint256 interestAmount_) internal override {
        // callback logic
    }

    /// @notice Callback function that handles defaults.
    function _onDefault(uint256 loanID_, uint256 debt, uint256 collateral) internal override {
        // callback logic
    }
}