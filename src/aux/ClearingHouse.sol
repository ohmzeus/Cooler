// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../Factory.sol";
import "../lib/mininterfaces.sol";

contract ClearingHouse {
    // Errors

    error OnlyApproved();
    error OnlyFromFactory();
    error BadEscrow();
    error InterestMinimum();
    error LTCMaximum();
    error DurationMaximum();

    // Roles

    address public operator;
    address public overseer;
    address public pendingOperator;
    address public pendingOverseer;

    // Relevant Contracts

    ERC20 public immutable dai;
    ERC20 public immutable gOHM;
    address public immutable treasury;
    CoolerFactory public immutable factory;

    // Parameter Bounds

    uint256 public constant minimumInterest = 2e16; // 2%
    uint256 public constant maxLTC = 2_500 * 1e18; // 2,500
    uint256 public constant maxDuration = 365 days; // 1 year

    constructor (
        address oper, 
        address over, 
        ERC20 g, 
        ERC20 d, 
        CoolerFactory f, 
        address t
    ) {
        operator = oper;
        overseer = over;
        gOHM = g;
        dai = d;
        factory = f;
        treasury = t;
    }

    // Operation

    /// @notice clear a requested loan
    /// @param cooler contract requesting loan
    /// @param id of loan in escrow contract
    function clear (Cooler cooler, uint256 id) external returns (uint256) {
        if (msg.sender != operator) 
            revert OnlyApproved();

        // Validate escrow
        if (!factory.created(address(cooler))) 
            revert OnlyFromFactory();
        if (cooler.collateral() != gOHM || cooler.debt() != dai)
            revert BadEscrow();

        (
            uint256 amount, 
            uint256 interest, 
            uint256 ltc, 
            uint256 duration,
        ) = cooler.requests(id);

        // Validate terms
        if (interest < minimumInterest) 
            revert InterestMinimum();
        if (ltc > maxLTC) 
            revert LTCMaximum();
        if (duration > maxDuration) 
            revert DurationMaximum();

        // Clear loan
        dai.approve(address(cooler), amount);
        return cooler.clear(id);
    }

    /// @notice toggle 'rollable' status of a loan
    function toggleRoll(Cooler cooler, uint256 loanID) external {
        if (msg.sender != operator) 
            revert OnlyApproved();

        cooler.toggleRoll(loanID);
    }

    // Oversight

    /// @notice pull funding from treasury
    function fund (uint256 amount) external {
        if (msg.sender != overseer) 
            revert OnlyApproved();
        ITreasury(treasury).manage(address(dai), amount);
    }

    /// @notice return funds to treasury
    /// @param token to transfer
    /// @param amount to transfer
    function defund (ERC20 token, uint256 amount) external {
        if (msg.sender != operator && msg.sender != overseer) 
            revert OnlyApproved();
        token.transfer(treasury, amount);
    }

    // Management

    /// @notice operator or overseer can set a new address
    /// @dev using a push/pull model for safety
    function push (address newAddress) external {
        if (msg.sender == overseer) 
            pendingOverseer = newAddress;
        else if (msg.sender == operator) 
            pendingOperator = newAddress;
        else revert OnlyApproved();
    }

    /// @notice new operator or overseer can pull role once pushed
    function pull () external {
        if (msg.sender == pendingOverseer) {
            overseer = pendingOverseer;
            pendingOverseer = address(0);
        } else if (msg.sender == pendingOperator) {
            operator = pendingOperator;
            pendingOperator = address(0);
        } else revert OnlyApproved();
    }
}