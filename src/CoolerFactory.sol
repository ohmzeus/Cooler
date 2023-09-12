// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ClonesWithImmutableArgs} from "clones/ClonesWithImmutableArgs.sol";

import {Cooler} from "./Cooler.sol";

/// @title  Cooler Loans Factory.
/// @notice The Cooler Factory creates new Cooler escrow contracts.
/// @dev    This contract uses Clones (https://github.com/wighawag/clones-with-immutable-args)
///         to save gas on deployment.
contract CoolerFactory {
    using ClonesWithImmutableArgs for address;

    // --- ERRORS ----------------------------------------------------

    error DecimalsNot18();

    // --- EVENTS ----------------------------------------------------

    /// @notice A global event when a new loan request is created.
    event RequestLoan(address cooler, address collateral, address debt, uint256 reqID);
    /// @notice A global event when a loan request is rescinded.
    event RescindRequest(address cooler, uint256 reqID);
    /// @notice A global event when a loan request is fulfilled.
    event ClearRequest(address cooler, uint256 reqID);
    /// @notice A global event when a loan is repaid.
    event RepayLoan(address cooler, uint256 loanID, uint256 amount);
    /// @notice A global event when a loan is extended.
    event ExtendLoan(address cooler, uint256 loanID);
    /// @notice A global event when the collateral of defaulted loan is claimed.
    event DefaultLoan(address cooler, uint256 loanID);

    // -- STATE VARIABLES --------------------------------------------

    /// @notice Cooler reference implementation (deployed on creation to clone from).
    Cooler public immutable coolerImplementation;

    /// @notice Mapping to validate deployed coolers.
    mapping(address => bool) public created;

    /// @notice Mapping to prevent duplicate coolers.
    mapping(address => mapping(ERC20 => mapping(ERC20 => address)))
        private coolerFor;

    /// @notice Mapping to query Coolers for Collateral-Debt pair.
    mapping(ERC20 => mapping(ERC20 => address[])) public coolersFor;

    // --- INITIALIZATION --------------------------------------------

    constructor() {
        coolerImplementation = new Cooler();
    }

    // --- DEPLOY NEW COOLERS ----------------------------------------

    /// @notice creates a new Escrow contract for collateral and debt tokens.
    /// @param  collateral_ the token given as collateral.
    /// @param  debt_ the token to be lent. Interest is denominated in debt tokens.
    /// @return cooler address of the contract.
function generateCooler(ERC20 collateral_, ERC20 debt_) external returns (address cooler) {
    // Return address if cooler exists.
    cooler = coolerFor[msg.sender][collateral_][debt_];

    // Otherwise generate new cooler.
    if (cooler == address(0)) {
        if (collateral_.decimals() != 18 || collateral_.decimals() != 18) revert DecimalsNot18();
        // Clone the cooler implementation.
        bytes memory coolerData = abi.encodePacked(
            msg.sender,              // owner
            address(collateral_),    // collateral
            address(debt_),          // debt
            address(this)            // factory
        );
        cooler = address(coolerImplementation).clone(coolerData);

        // Update storage accordingly.
        coolerFor[msg.sender][collateral_][debt_] = cooler;
        coolersFor[collateral_][debt_].push(cooler);
        created[cooler] = true;
    }
}

    // --- EMIT EVENTS -----------------------------------------------

    enum Events {
        RequestLoan,
        RescindRequest,
        ClearRequest,
        RepayLoan,
        ExtendLoan,
        DefaultLoan
    }

    /// @notice emit an event each time a request is interacted with on a Cooler.
    /// @param  id_ loan or request identifier.
    /// @param  ev_ event type.
    /// @param  amount_ to be logged by the event.
    function newEvent(uint256 id_, Events ev_, uint256 amount_) external {
        require(created[msg.sender], "Only Created");

        if (ev_ == Events.RequestLoan) {
            emit RequestLoan(msg.sender, address(Cooler(msg.sender).collateral()), address(Cooler(msg.sender).debt()), id_);
        } else if (ev_ == Events.RescindRequest) {
            emit RescindRequest(msg.sender, id_);
        } else if (ev_ == Events.ClearRequest) {
            emit ClearRequest(msg.sender, id_);
        } else if (ev_ == Events.RepayLoan) {
            emit RepayLoan(msg.sender, id_, amount_);
        } else if (ev_ == Events.ExtendLoan) {
            emit ExtendLoan(msg.sender, id_);
        } else if (ev_ == Events.DefaultLoan) {
            emit DefaultLoan(msg.sender, id_);
        }
    }
}
