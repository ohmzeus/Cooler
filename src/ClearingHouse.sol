// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {ROLESv1, RolesConsumer} from "olympus-v3/modules/ROLES/OlympusRoles.sol";
import {TRSRYv1} from "olympus-v3/modules/TRSRY/TRSRY.v1.sol";
import {MINTRv1} from "olympus-v3/modules/MINTR/MINTR.v1.sol";
import "olympus-v3/Kernel.sol";

import {CoolerFactory, Cooler} from "src/CoolerFactory.sol";

interface IStaking {
    function unstake(
        address to,
        uint256 amount,
        bool trigger,
        bool rebasing
    ) external returns (uint256);
}

contract ClearingHouse is Policy, RolesConsumer {
    // Errors

    error OnlyFromFactory();
    error BadEscrow();
    error DurationMaximum();
    error OnlyBurnable();
    error TooEarlyToFund();

    // Relevant Contracts

    CoolerFactory public immutable factory;
    ERC20 public immutable dai;
    ERC4626 public immutable sDai;
    ERC20 public immutable gOHM;
    IStaking public immutable staking;

    // Modules

    TRSRYv1 public TRSRY;
    MINTRv1 public MINTR;

    // Parameter Bounds

    uint256 public constant INTEREST_RATE = 5e15; // 0.5%
    uint256 public constant LOAN_TO_COLLATERAL = 3000 * 1e18; // 3,000
    uint256 public constant DURATION = 121 days; // Four months
    uint256 public constant FUND_CADENCE = 7 days; // One week
    uint256 public constant FUND_AMOUNT = 18 * 1e24; // 18 million

    uint256 public fundTime; // Timestamp at which rebalancing can occur
    uint256 public receivables; // Outstanding loan receivables
                                // Incremented when a loan is made or rolled
                                // Decremented when a loan is repaid or collateral is burned

    // Initialization

    // Initialization

    constructor(
        address gohm_,
        address staking_,
        address sdai_,
        address coolerFactory_,
        address kernel_
    ) Policy(Kernel(kernel_)) {
        gOHM = ERC20(gohm_);
        staking = IStaking(staking_);
        sDai = ERC4626(sdai_);
        dai = ERC20(sDai.asset());
        factory = CoolerFactory(coolerFactory_);
    }

    /// @notice Default framework setup
    function configureDependencies()
        external
        override
        returns (Keycode[] memory dependencies)
    {
        dependencies = new Keycode[](3);
        dependencies[0] = toKeycode("TRSRY");
        dependencies[1] = toKeycode("MINTR");
        dependencies[2] = toKeycode("ROLES");

        TRSRY = TRSRYv1(getModuleAddress(toKeycode("TRSRY")));
        MINTR = MINTRv1(getModuleAddress(toKeycode("MINTR")));
        ROLES = ROLESv1(getModuleAddress(toKeycode("ROLES")));
    }

    /// @notice Default framework setup
    function requestPermissions()
        external
        view
        override
        returns (Permissions[] memory requests)
    {
        Keycode TRSRY_KEYCODE = toKeycode("TRSRY");

        requests = new Permissions[](3);
        requests[0] = Permissions(
            TRSRY_KEYCODE,
            TRSRY.withdrawReserves.selector
        );
        requests[1] = Permissions(
            TRSRY_KEYCODE,
            TRSRY.increaseWithdrawApproval.selector
        );
        requests[2] = Permissions(toKeycode("MINTR"), MINTR.burnOhm.selector);
    }

    // Operation

    /// @notice lend to a cooler
    /// @param cooler to lend to
    /// @param amount of DAI to lend
    function lend(Cooler cooler, uint256 amount) external returns (uint256) {
        // Validate
        if (!factory.created(address(cooler))) revert OnlyFromFactory();
        if (cooler.collateral() != gOHM || cooler.debt() != dai)
            revert BadEscrow();

        // Compute and access collateral
        uint256 collateral = cooler.collateralFor(amount, LOAN_TO_COLLATERAL);
        gOHM.transferFrom(msg.sender, address(this), collateral);

        // Create loan request
        gOHM.approve(address(cooler), collateral);
        uint256 reqID = cooler.request(
            amount,
            INTEREST_RATE,
            LOAN_TO_COLLATERAL,
            DURATION
        );

        // Clear loan request by providing enough DAI
        sDai.withdraw(amount, address(this), address(this));
        dai.approve(address(cooler), amount);
        uint256 loanID = cooler.clear(reqID, true, true);

        // Increment loan receivables
        receivables += loanForCollateral(collateral);
        
        return loanID;
    }

    /// @notice provide terms for loan rollover
    /// @param cooler to provide terms
    /// @param id of loan in cooler
    function roll(Cooler cooler, uint256 id) external {
        // Provide rollover terms
        cooler.provideNewTermsForRoll(
            id,
            INTEREST_RATE,
            LOAN_TO_COLLATERAL,
            DURATION
        );

        // Collect applicable new collateral from user
        uint256 newCollateral = cooler.newCollateralFor(id);
        gOHM.transferFrom(msg.sender, address(this), newCollateral);

        // Roll loan
        gOHM.approve(address(cooler), newCollateral);
        cooler.roll(id);

        // Increment loan receivables
        receivables += loanForCollateral(newCollateral);
    }

    /// @notice callback to decrement loan receivables
    /// @param loanID of loan
    /// @param amount repaid
    function repay(uint256 loanID, uint256 amount) external {
        // Validate caller is cooler
        if (!factory.created(msg.sender)) revert OnlyFromFactory();
        // Validate lender is not address(0)
        (,,,,, address lender,,) = Cooler(msg.sender).loans(loanID);
        if (lender == address(0)) revert BadEscrow();

        // Decrement loan receivables
        receivables -= amount;
    }

    // Funding

    /// @notice fund loan liquidity from treasury
    function rebalance() external {
        if (fundTime == 0) fundTime = block.timestamp + FUND_CADENCE;
        else if (fundTime <= block.timestamp) fundTime += FUND_CADENCE;
        else revert TooEarlyToFund();

        uint256 balance = dai.balanceOf(address(this)) +
            sDai.maxWithdraw(address(this));

        // Rebalance funds on hand with treasury's reserves
        if (balance < FUND_AMOUNT) {
            uint256 amount = FUND_AMOUNT - balance;

            TRSRY.increaseWithdrawApproval(address(this), dai, amount);
            TRSRY.withdrawReserves(address(this), dai, amount);
            sweep();
        } else {
            // Withdraw from sDAI to the treasury
            sDai.withdraw(balance - FUND_AMOUNT, address(TRSRY), address(this));
        }
    }

    /// @notice Sweep excess DAI into vault
    function sweep() public {
        uint256 balance = dai.balanceOf(address(this));
        dai.approve(address(sDai), balance);
        sDai.deposit(balance, address(this));
    }

    /// @notice Return funds to treasury.
    /// @param token to transfer
    /// @param amount to transfer
    function defund(
        ERC20 token,
        uint256 amount
    ) external onlyRole("cooler_overseer") {
        if (token == gOHM) revert OnlyBurnable();
        token.transfer(address(TRSRY), amount);
    }

    /// @notice Allow any address to burn collateral returned to clearinghouse
    function burn() external {
        uint256 balance = gOHM.balanceOf(address(this));
        gOHM.approve(address(staking), balance);

        // Unstake gOHM then burn
        MINTR.burnOhm(
            address(this),
            staking.unstake(address(this), balance, false, false)
        );

        // Decrement loan receivables
        receivables -= loanForCollateral(balance);
    }

    // View functions
    
    /// @notice view function computing loan for a collateral amount
    /// @param collateral amount of gOHM collateral
    function loanForCollateral(uint256 collateral) public pure returns (uint256) {
        uint256 interestPercent = (INTEREST_RATE * DURATION) / 365 days;
        uint256 loan = collateral * LOAN_TO_COLLATERAL / 1e18;
        uint256 interest = loan * interestPercent / 1e18;
        return loan + interest;
    }
}