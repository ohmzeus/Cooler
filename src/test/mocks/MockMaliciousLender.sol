// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {CoolerCallback} from "src/CoolerCallback.sol";
import {Cooler} from "src/Cooler.sol";

contract MockMaliciousLender is CoolerCallback {
    constructor(address coolerFactory_) CoolerCallback(coolerFactory_) {}
    
    /// @notice Callback function that handles repayments. Override for custom logic.
    function _onRepay(uint256 loanID_, uint256 principlePaid_, uint256 interestPaid_) internal override {
        Cooler(msg.sender).repayLoan(loanID_, principlePaid_);
    }

    /// @notice Callback function that handles defaults.
    function _onDefault(uint256 loanID_, uint256 principle, uint256 interest_, uint256 collateral) internal override {
        Cooler(msg.sender).claimDefaulted(loanID_);
    }
}