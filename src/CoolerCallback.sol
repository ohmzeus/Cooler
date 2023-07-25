// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/// @notice Allows for debt issuers to execute logic when a loan is repaid, rolled, or defaulted.
abstract contract CoolerCallback {
    function isCoolerCallback() external pure returns (bool) { return true; }    
    function onRepay(uint256 loanID, uint256 amount) external virtual;
    function onDefault(uint256 loanID) external virtual;
    function onRoll(uint256 loanID) external virtual;
}