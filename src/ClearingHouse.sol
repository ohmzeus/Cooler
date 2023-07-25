// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {ROLESv1, RolesConsumer} from "olympus-v3/modules/ROLES/OlympusRoles.sol";
import {TRSRYv1} from "olympus-v3/modules/TRSRY/TRSRY.v1.sol";
import {MINTRv1} from "olympus-v3/modules/MINTR/MINTR.v1.sol";
import "olympus-v3/Kernel.sol";

import {CoolerFactory, Cooler} from "src/CoolerFactory.sol";
import {ICoolerCallback} from "src/ICoolerCallback.sol";

import {console2 as console} from "forge-std/console2.sol";

interface IStaking {
    function unstake(
        address to,
        uint256 amount,
        bool trigger,
        bool rebasing
    ) external returns (uint256);
}

contract ClearingHouse is Policy, RolesConsumer, ICoolerCallback {

    // --- ERRORS ----------------------------------------------------

    error OnlyFromFactory();
    error BadEscrow();
    error DurationMaximum();
    error OnlyBurnable();
    error TooEarlyToFund();
    
    // --- RELEVANT CONTRACTS ----------------------------------------

    CoolerFactory public immutable factory;
    ERC20 public immutable dai;
    ERC4626 public immutable sDai;
    ERC20 public immutable gOHM;
    IStaking public immutable staking;
    
    // --- MODULES ---------------------------------------------------

    TRSRYv1 public TRSRY;
    MINTRv1 public MINTR;

    // --- PARAMETER BOUNDS ------------------------------------------

    uint256 public constant INTEREST_RATE = 5e15;               // 0.5%
    uint256 public constant LOAN_TO_COLLATERAL = 3000e18;       // 3,000
    uint256 public constant DURATION = 121 days;                // Four months
    uint256 public constant FUND_CADENCE = 7 days;              // One week
    uint256 public constant FUND_AMOUNT = 18_000_000e18;        // 18 million

    uint256 public fundTime;     // Timestamp at which rebalancing can occur
    uint256 public receivables;  // Outstanding loan receivables
                                 // Incremented when a loan is made or rolled
                                 // Decremented when a loan is repaid or collateral is burned

    // --- INITIALIZATION --------------------------------------------

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

        requests = new Permissions[](5);
        requests[0] = Permissions(
            TRSRY_KEYCODE,
            TRSRY.setDebt.selector
        );
        requests[1] = Permissions(
            TRSRY_KEYCODE,
            TRSRY.repayDebt.selector
        );
        requests[2] = Permissions(
            TRSRY_KEYCODE,
            TRSRY.incurDebt.selector
        );
        requests[3] = Permissions(
            TRSRY_KEYCODE,
            TRSRY.increaseDebtorApproval.selector
        );
        requests[4] = Permissions(toKeycode("MINTR"), MINTR.burnOhm.selector);
    }

    // --- OPERATION -------------------------------------------------

    /// @notice lend to a cooler
    /// @param cooler to lend to
    /// @param amount of DAI to lend
    function lend(Cooler cooler, uint256 amount) external returns (uint256) {
        // Attemp a treasury rebalance
        rebalance();
        // Validate that cooler was deployed by the trusted factory.
        if (!factory.created(address(cooler))) revert OnlyFromFactory();
        // Validate cooler collateral and debt tokens.
        if (cooler.collateral() != gOHM || cooler.debt() != dai) revert BadEscrow();

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

    /// @notice callback to attept a treasury rebalance
    /// @param loanID of loan
    function onRoll(uint256 loanID) external override {
        // Attemp a treasury rebalance
        rebalance();
    }

    /// @notice callback to decrement loan receivables
    /// @param loanID of loan
    /// @param amount repaid
    function onRepay(uint256 loanID, uint256 amount) external override {
        // Validate caller is cooler
        if (!factory.created(msg.sender)) revert OnlyFromFactory();
        // Validate lender is the clearing house
        (,,,,, address lender,,) = Cooler(msg.sender).loans(loanID);
        if (lender != address(this)) revert BadEscrow();

        // Decrement loan receivables
        receivables -= amount;
        // Attemp a treasury rebalance
        rebalance();
    }

    // --- FUNDING ---------------------------------------------------

    /// @notice Fund loan liquidity from treasury. Returns false if too early to rebalance.
    ///         Exposure is always capped at FUND_AMOUNT and rebalanced at FUND_CADANCE.
    function rebalance() public returns (bool) {
        if (fundTime > block.timestamp) return false;
        fundTime = block.timestamp + FUND_CADENCE;

        uint256 balance = dai.balanceOf(address(this)) + sDai.maxWithdraw(address(this));

        // Rebalance funds on hand with treasury's reserves
        if (balance < FUND_AMOUNT) {
            uint256 amount = FUND_AMOUNT - balance;
            // Fund the clearinghouse with treasury assets.
            TRSRY.increaseDebtorApproval(address(this), dai, amount);
            TRSRY.incurDebt(dai, amount);
            sweep();
        } else {
            // Withdraw from sDAI to the treasury
            sDai.withdraw(balance - FUND_AMOUNT, address(TRSRY), address(this));
        }
        return true;
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
    function defund(ERC20 token, uint256 amount) external onlyRole("cooler_overseer") {
        if (token == gOHM) revert OnlyBurnable();

        // Return funds to the Treasury by using `repayDebt`
        try TRSRY.repayDebt(address(this), token, amount) {}
        // Use a regular ERC20 transfer as a fallback function
        // for tokens weren't borrowed from Treasury
        catch { token.transfer(address(TRSRY), amount); }
    }

    /// @notice Callback to account for defaults. Adjusts Treasury debt and OHM supply.
    /// @param loanID of loan
    function onDefault(uint256 loanID) external override {
        // Validate caller is cooler
        if (!factory.created(msg.sender)) revert OnlyFromFactory();
        // Validate lender is the clearinghouse
        (, uint256 amount,, uint256 collateral,, address lender,,) = Cooler(msg.sender).loans(loanID);
        if (lender != address(this)) revert BadEscrow();

        // Update outstanding debt owed to the Treasury upon default.
        uint256 outstandingDebt = TRSRY.reserveDebt(dai, address(this));
        TRSRY.setDebt(address(this), dai, outstandingDebt - amount);

        // Unstake and burn the collateral of the defaulted loan.
        gOHM.approve(address(staking), collateral);
        MINTR.burnOhm(
            address(this),
            staking.unstake(address(this), collateral, false, false)
        );

        // Decrement loan receivables
        receivables -= amount;
        // Attemp a treasury rebalance
        rebalance();
    }

    // --- AUX FUNCTIONS ---------------------------------------------
    
    /// @notice view function computing loan for a collateral amount
    /// @param collateral amount of gOHM collateral
    function loanForCollateral(uint256 collateral) public pure returns (uint256) {
        uint256 interestPercent = (INTEREST_RATE * DURATION) / 365 days;
        uint256 loan = collateral * LOAN_TO_COLLATERAL / 1e18;
        uint256 interest = loan * interestPercent / 1e18;
        return loan + interest;
    }
}