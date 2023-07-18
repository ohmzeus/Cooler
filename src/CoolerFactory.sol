// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ClonesWithImmutableArgs} from "clones/ClonesWithImmutableArgs.sol";

import {Cooler} from "./Cooler.sol";

/// @notice the Cooler Factory creates new Cooler escrow contracts
///
/// @dev This contract uses Clones (https://github.com/wighawag/clones-with-immutable-args)
///      to save gas on deployment
contract CoolerFactory {
    using ClonesWithImmutableArgs for address;

    // -- EVENTS -----------------------------------------------------

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

    // -- STATE VARIABLES --------------------------------------------

    // Cooler reference implementation (deployed on creation to clone from)
    Cooler public immutable coolerImplementation;

    // Mapping to validate deployed coolers
    mapping(address => bool) public created;

    // Mapping to prevent duplicate coolers
    mapping(address => mapping(ERC20 => mapping(ERC20 => address)))
        private coolerFor;

    // Mapping to query Coolers for Collateral-Debt pair
    mapping(ERC20 => mapping(ERC20 => address[])) public coolersFor;

    // -- INITIALIZATION ---------------------------------------------

    constructor() {
        coolerImplementation = new Cooler();
    }

    // -- DEPLOY NEW COOLERS -----------------------------------------

    /// @notice creates a new Escrow contract for collateral and debt tokens
    function generate(
        ERC20 collateral,
        ERC20 debt
    ) external returns (address cooler) {
        // Return address if cooler exists
        cooler = coolerFor[msg.sender][collateral][debt];

        // Otherwise generate new cooler
        if (cooler == address(0)) {
            bytes memory coolerData = abi.encodePacked(
                msg.sender,             // owner
                address(collateral),    // collateral
                address(debt),          // debt
                address(this)           // factory
            );
            cooler = address(coolerImplementation).clone(coolerData);
            coolerFor[msg.sender][collateral][debt] = cooler;
            coolersFor[collateral][debt].push(cooler);
            created[cooler] = true;
        }
    }

    // -- EMIT EVENTS ------------------------------------------------

    enum Events {
        Request,
        Rescind,
        Clear,
        Repay
    }

    /// @notice emit an event each time a request is interacted with on a Cooler
    function newEvent(uint256 id, Events ev, uint256 amount) external {
        require(created[msg.sender], "Only Created");

        if (ev == Events.Clear) emit Clear(msg.sender, id);
        else if (ev == Events.Repay) emit Repay(msg.sender, id, amount);
        else if (ev == Events.Rescind) emit Rescind(msg.sender, id);
        else if (ev == Events.Request)
            emit Request(
                msg.sender,
                address(Cooler(msg.sender).collateral()),
                address(Cooler(msg.sender).debt()),
                id
            );
    }
}
