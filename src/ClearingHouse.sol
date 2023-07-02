// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "src/Factory.sol";
import {ROLESv1, RolesConsumer} from "lib/olympus-v3/src/modules/ROLES/OlympusRoles.sol";
import {TRSRYv1, ERC20 as TRSRYERC20} from "lib/olympus-v3/src/modules/TRSRY/TRSRY.v1.sol";
import {Kernel, Policy, Keycode, toKeycode, Permissions} from "lib/olympus-v3/src/Kernel.sol";

contract ClearingHouse is Policy, RolesConsumer {
    // Errors

    error OnlyFromFactory();
    error BadEscrow();
    error DurationMaximum();

    // Roles

    address public overseer;
    address public pendingOverseer;

    // Relevant Contracts

    ERC20 public immutable dai;
    ERC20 public immutable gOHM;
    CoolerFactory public immutable factory;

    // Modules
    TRSRYv1 internal TRSRY;

    // Parameter Bounds

    uint256 public constant interestRate = 1e16; // 1%
    uint256 public constant loanToCollateral = 3 * 1e21; // 3,000
    uint256 public constant maxDuration = 365 days; // 1 year

    constructor (
        address o, 
        ERC20 g, 
        ERC20 d, 
        CoolerFactory f,
        address k
    ) Policy(Kernel(k)) {
        overseer = o;
        gOHM = g;
        dai = d;
        factory = f;
    }

    // Default framework setup
    function configureDependencies() external override returns (Keycode[] memory dependencies) {
        dependencies = new Keycode[](2);
        dependencies[0] = toKeycode("TRSRY");
        dependencies[1] = toKeycode("ROLES");

        TRSRY = TRSRYv1(getModuleAddress(toKeycode("TRSRY")));
        ROLES = ROLESv1(getModuleAddress(toKeycode("ROLES")));
    }

    function requestPermissions() external view override returns (Permissions[] memory requests) {
        requests = new Permissions[](1);
        requests[0] = Permissions(toKeycode("TRSRY"), TRSRY.withdrawReserves.selector);
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
    function fund (uint256 amount) external onlyRole("cooler_overseer") {
        TRSRY.withdrawReserves(address(this), TRSRYERC20(address(dai)), amount);
    }

    /// @notice return funds to treasury
    /// @param token to transfer
    /// @param amount to transfer
    function defund (ERC20 token, uint256 amount) external onlyRole("cooler_overseer") {
        token.transfer(address(TRSRY), amount);
    }
}