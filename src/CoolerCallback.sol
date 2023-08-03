// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {CoolerFactory} from "src/CoolerFactory.sol";

/// @notice Allows for debt issuers to execute logic when a loan is repaid, rolled, or defaulted.
/// @dev    The three callback functions must be implemented if `isCoolerCallback()` is set to true.
abstract contract CoolerCallback {

    // --- ERRORS ----------------------------------------------------

    error OnlyFromFactory();

    // --- INITIALIZATION --------------------------------------------

    CoolerFactory public immutable factory;

    constructor(address coolerFactory_) {
        factory = CoolerFactory(coolerFactory_);
    }

    // --- EXTERNAL FUNCTIONS ------------------------------------------------

    /// @notice Informs to Cooler that this contract can handle its callbacks.
    function isCoolerCallback() external pure returns (bool) {
        return true;
    }

    /// @notice Callback function that handles repayments.
    function onRepay(uint256 loanID_, uint256 amount_) external { 
        if(!factory.created(msg.sender)) revert OnlyFromFactory();
        _onRepay(loanID_, amount_);
    }

    /// @notice Callback function that handles rollovers.
    function onRoll(uint256 loanID_, uint256 newDebt, uint256 newCollateral) external {
        if(!factory.created(msg.sender)) revert OnlyFromFactory();
        _onRoll(loanID_, newDebt, newCollateral);
    }

    /// @notice Callback function that handles defaults.
    function onDefault(uint256 loanID_, uint256 debt, uint256 collateral) external {
        if(!factory.created(msg.sender)) revert OnlyFromFactory();
        _onDefault(loanID_, debt, collateral);
    }

    // --- INTERNAL FUNCTIONS ------------------------------------------------

    /// @notice Callback function that handles repayments. Override for custom logic.
    function _onRepay(uint256 loanID_, uint256 amount_) internal virtual {}

    /// @notice Callback function that handles rollovers.
    function _onRoll(uint256 loanID_, uint256 newDebt, uint256 newCollateral) internal virtual {}

    /// @notice Callback function that handles defaults.
    function _onDefault(uint256 loanID_, uint256 debt, uint256 collateral) internal virtual {}
}