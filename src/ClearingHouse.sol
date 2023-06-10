// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../Factory.sol";
import "../lib/ITRSRY.sol";

contract ClearingHouse {
    // Errors

    error OnlyApproved();
    error OnlyFromFactory();
    error BadEscrow();
    error DurationMaximum();

    // Roles

    address public overseer;
    address public pendingOverseer;

    // Relevant Contracts

    ERC20 public immutable dai;
    ERC20 public immutable gOHM;
    ITRSRY public immutable treasury;
    CoolerFactory public immutable factory;

    // Parameter Bounds

    uint256 public constant interestRate = 1e16; // 1%
    uint256 public constant loanToCollateral = 3 * 1e21; // 3,000
    uint256 public constant maxDuration = 365 days; // 1 year

    constructor (
        address o, 
        ERC20 g, 
        ERC20 d, 
        CoolerFactory f, 
        ITRSRY t
    ) {
        overseer = o;
        gOHM = g;
        dai = d;
        factory = f;
        treasury = t;
    }

    // Operation

    /// @notice lend to a cooler
    /// @param cooler to lend to
    /// @param amount of DAI to lend
    /// @param duration of loan
    function lend (Cooler cooler, uint256 amount, uint256 duration) external {
        // Validate
        if (!factory.created(address(cooler))) 
            revert OnlyFromFactory();
        if (cooler.collateral() != gOHM || cooler.debt() != dai)
            revert BadEscrow();
        if (duration > maxDuration)
            revert DurationMaximum();
        
        // Compute and access collateral
        uint256 collateral = cooler.collateralFor(amount, loanToCollateral);
        gOHM.transferFrom(msg.sender, address(this), collateral);

        // Create loan request
        gOHM.approve(address(cooler), collateral);
        uint256 id = cooler.request(amount, interestRate, loanToCollateral, duration);

        // Clear loan request
        dai.approve(address(cooler), amount);
        cooler.clear(id, true);
    }

    /// @notice provide terms for loan rollover
    /// @param cooler to provide terms
    /// @param id of loan in cooler
    /// @param duration of new loan
    function roll (Cooler cooler, uint256 id, uint256 duration) external {
        // Provide rollover terms
        cooler.provideNewTermsForRoll(id, interestRate, loanToCollateral, duration);

        // Collect applicable new collateral from user
        uint256 newCollateral = cooler.newCollateralFor(id);
        gOHM.transferFrom(msg.sender, address(this), newCollateral);

        // Roll loan
        gOHM.approve(address(cooler), newCollateral);
        cooler.roll(id);
    }

    // Oversight

    /// @notice fund loan liquidity from treasury
    /// @param amount of DAI to fund
    function fund (uint256 amount) external {
        if (msg.sender != overseer) 
            revert OnlyApproved();
        treasury.withdrawReserves(address(this), dai, amount);
    }

    /// @notice return funds to treasury
    /// @param token to transfer
    /// @param amount to transfer
    function defund (ERC20 token, uint256 amount) external {
        if (msg.sender != overseer) 
            revert OnlyApproved();
        token.transfer(address(treasury), amount);
    }

    // Management

    /// @notice operator or overseer can set a new address
    /// @dev using a push/pull model for safety
    function push (address newAddress) external {
        if (msg.sender == overseer) 
            pendingOverseer = newAddress;
        else revert OnlyApproved();
    }

    /// @notice new operator or overseer can pull role once pushed
    function pull () external {
        if (msg.sender == pendingOverseer) {
            overseer = pendingOverseer;
            pendingOverseer = address(0);
        } else revert OnlyApproved();
    }
}