// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {CoolerCallback} from "src/CoolerCallback.sol";
import {Cooler} from "src/Cooler.sol";

contract MockMaliciousLender is CoolerCallback {
    constructor(address coolerFactory_) CoolerCallback(coolerFactory_) {}
    
    /// @notice Callback function that handles repayments. Override for custom logic.
    function _onRepay(uint256 loanID_, uint256 amount_) internal override {
        Cooler(msg.sender).repayLoan(loanID_, amount_);
    }

    /// @notice Callback function that handles rollovers.
    function _onRoll(uint256 loanID_, uint256 newDebt, uint256 newCollateral) internal override {
        Cooler(msg.sender).rollLoan(loanID_);
    }

    /// @notice Callback function that handles defaults.
    function _onDefault(uint256 loanID_, uint256 debt, uint256 collateral) internal override {
        Cooler(msg.sender).claimDefaulted(loanID_);
    }
}