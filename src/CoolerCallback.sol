// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {CoolerFactory} from "src/CoolerFactory.sol";

/// @notice Allows for debt issuers to execute logic when a loan is repaid, rolled, or defaulted.
/// @dev    The three callback functions must be implemented if `isCoolerCallback()` is set to true.
abstract contract CoolerCallback {

    CoolerFactory public immutable factory;

    constructor(address coolerFactory_) {
        factory = CoolerFactory(coolerFactory_);
    }

    /// @notice Informs to Cooler that this contract can handle its callbacks.
    function isCoolerCallback() external pure returns (bool) {
        return true;
    }

    /// @dev Ensures that the callback caller is a Cooler deployed by the factory.
    ///      Failing to implement this check properly may lead to unexpected/malicious
    ///      contracts calling the lender's callback functions.
    function _onlyFromFactory() internal view {
        // Validate caller is cooler.
        require(factory.created(msg.sender), "ONLY_FROM_FACTORY");
    }

    /// @notice Callback function that handles repayments.
    function onRepay(uint256 loanID, uint256 amount) external virtual { 
        _onlyFromFactory();
        // Callback Logic
    }

    /// @notice Callback function that handles rollovers.
    function onRoll(uint256 loanID, uint256 newDebt, uint256 newCollateral) external virtual {
        _onlyFromFactory();
        // Callback Logic
    }

    /// @notice Callback function that handles defaults.
    function onDefault(uint256 loanID, uint256 debt, uint256 collateral) external virtual {
        _onlyFromFactory();
        // Callback Logic
    }
}