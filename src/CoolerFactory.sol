// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "solmate/tokens/ERC20.sol";

import {Cooler} from "./Cooler.sol";

/// @notice the Cooler Factory creates new Cooler escrow contracts
contract CoolerFactory {

    // --- EVENTS ----------------------------------------------------

    // A global event when a loan request is created
    event Request(
        address cooler,
        address collateral,
        address debt,
        uint256 reqID
    );
    // A global event when a loan request is rescinded
    event Rescind(address cooler, uint256 reqID);
    // A global event when a loan request is cleared
    event Clear(address cooler, uint256 reqID);
    // A global event when a loan is repaid
    event Repay(address cooler, uint256 loanID, uint256 amount);

    // Mapping to validate deployed coolers
    mapping(address => bool) public created;

    // Mapping to prevent duplicate coolers
    mapping(address => mapping(ERC20 => mapping(ERC20 => address)))
        private coolerFor;

    // Mapping to query Coolers for Collateral-Debt pair
    mapping(ERC20 => mapping(ERC20 => address[])) public coolersFor;

    // --- INITIALIZATION --------------------------------------------

    /// @notice creates a new Escrow contract for collateral and debt tokens.
    /// @param collateral_ the token given as collateral.
    /// @param debt_ the token to be lent. Interest is denominated in debt tokens.
    function generateCooler(ERC20 collateral_, ERC20 debt_) external returns (address cooler) {
        // Return address if cooler exists
        cooler = coolerFor[msg.sender][collateral_][debt_];

        // Otherwise generate new cooler
        if (cooler == address(0)) {
            cooler = address(new Cooler(msg.sender, collateral_, debt_));
            coolerFor[msg.sender][collateral_][debt_] = cooler;
            coolersFor[collateral_][debt_].push(cooler);
            created[cooler] = true;
        }
    }

    // --- EMIT EVENTS -----------------------------------------------

    enum Events {
        Request,
        Rescind,
        Clear,
        Repay
    }

    /// @notice emit an event each time a request is interacted with on a Cooler.
    /// @param id_ loan or request identifier.
    /// @param ev_ event type.
    /// @param amount_ to be logged by the event.
    function newEvent(uint256 id_, Events ev_, uint256 amount_) external {
        require(created[msg.sender], "Only Created");

        if (ev_ == Events.Clear) emit Clear(msg.sender, id_);
        else if (ev_ == Events.Repay) emit Repay(msg.sender, id_, amount_);
        else if (ev_ == Events.Rescind) emit Rescind(msg.sender, id_);
        else if (ev_ == Events.Request)
            emit Request(
                msg.sender,
                address(Cooler(msg.sender).collateral()),
                address(Cooler(msg.sender).debt()),
                id_
            );
    }
}
