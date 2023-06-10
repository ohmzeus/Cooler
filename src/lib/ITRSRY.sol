// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./mininterfaces.sol";

interface ITRSRY {
    function withdrawReserves(
        address to_,
        ERC20 token_,
        uint256 amount_
    ) external;
}