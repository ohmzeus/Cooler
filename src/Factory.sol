// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Cooler.sol";

/// @notice the Cooler Factory creates new Cooler escrow contracts
contract CoolerFactory {
    // Mapping to validate deployed coolers
    mapping(address => bool) public created;

    // Mapping to prevent duplicate coolers
    mapping(address => mapping(ERC20 => mapping(ERC20 => address))) private coolerFor;

    /// @notice creates a new Escrow contract for collateral and debt tokens
    function generate (ERC20 collateral, ERC20 debt) external returns (address cooler) {
        // Return address if cooler exists
        cooler = coolerFor[msg.sender][collateral][debt];

        // Otherwise generate new cooler
        if (cooler == address(0)) {
            cooler = address(new Cooler(msg.sender, collateral, debt));
            coolerFor[msg.sender][collateral][debt] = cooler;
            created[cooler] = true;
        }
    }
}