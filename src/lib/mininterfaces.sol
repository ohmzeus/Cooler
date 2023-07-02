// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ERC20.sol";

interface IDelegateERC20 is IERC20 {
    function delegate(address to) external;
}

interface ITreasury {
    function manage(address token, uint256 amount) external;
}

interface IStaking {
    function unstake(address to, uint256 amount, bool trigger, bool rebasing) external returns (uint256);
}

interface IBurnableERC20 is IERC20 {
    function burn(uint256 amount) external;
}