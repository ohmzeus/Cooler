// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../lib/ERC20.sol";

/// @dev    NOTE this is a testing contract and should NOT be used in prod.
contract Treasury {
    function deposit(address token, uint amount, uint value) external {
        amount = amount * value / value;
        ERC20(token).transferFrom(msg.sender, address(this), amount);
    }
    
    function manage(address token, uint amount) external {
        ERC20(token).transfer(msg.sender, amount);
    }

    function valueOf(address token, uint amount) external view returns (uint256) {
        return ERC20(token).balanceOf(address(this)) + amount;
    }
}