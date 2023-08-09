// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {ROLESv1, RolesConsumer} from "olympus-v3/modules/ROLES/OlympusRoles.sol";
import {TRSRYv1} from "olympus-v3/modules/TRSRY/TRSRY.v1.sol";
import {MINTRv1} from "olympus-v3/modules/MINTR/MINTR.v1.sol";
import "olympus-v3/Kernel.sol";

import {IStaking} from "interfaces/IStaking.sol";

import {CoolerFactory, Cooler} from "src/CoolerFactory.sol";
import {CoolerCallback} from "src/CoolerCallback.sol";

/// @title  Olympus Clearinghouse.
/// @notice Olympus Clearinghouse (Policy) Contract.
/// @dev    The Olympus Clearinghouse is a lending facility built on top of Cooler Loans. The Clearinghouse
///         ensures that OHM holders can take loans against their gOHM holdings according to the parameters
///         approved by the community in OIP-144 and its subsequent RFCs. The Clearinghouse parameters are
///         immutable, because of that, if backing was to increase substantially, a new governance process
///         to fork this implementation with upgraded parameters should take place.
///         Despite the Cooler contracts allow lenders to transfer ownership of their repayment rights, the
///         Clearinghouse doesn't implement any functions to use that feature.
contract Clearinghouse is Policy, RolesConsumer, CoolerCallback {

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

    uint256 public fundTime;     // Timestamp at which rebalancing can occur.
    uint256 public receivables;  // Outstanding loan receivables.
                                 // Incremented when a loan is made or rolled.
                                 // Decremented when a loan is repaid or collateral is burned.

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
        // Initialize funding schedule.
        fundTime = block.timestamp;
    }

    /// @notice Default framework setup.
    function configureDependencies() external override returns (Keycode[] memory dependencies) {
        dependencies = new Keycode[](3);
        dependencies[0] = toKeycode("TRSRY");
        dependencies[1] = toKeycode("MINTR");
        dependencies[2] = toKeycode("ROLES");

        TRSRY = TRSRYv1(getModuleAddress(toKeycode("TRSRY")));
        MINTR = MINTRv1(getModuleAddress(toKeycode("MINTR")));
        ROLES = ROLESv1(getModuleAddress(toKeycode("ROLES")));
    }

    /// @notice Default framework setup.
    function requestPermissions() external view override returns (Permissions[] memory requests) {
        Keycode TRSRY_KEYCODE = toKeycode("TRSRY");

        requests = new Permissions[](5);
        requests[0] = Permissions(TRSRY_KEYCODE, TRSRY.setDebt.selector);
        requests[1] = Permissions(TRSRY_KEYCODE, TRSRY.repayDebt.selector);
        requests[2] = Permissions(TRSRY_KEYCODE, TRSRY.incurDebt.selector);
        requests[3] = Permissions(TRSRY_KEYCODE, TRSRY.increaseDebtorApproval.selector);
        requests[4] = Permissions(toKeycode("MINTR"), MINTR.burnOhm.selector);
    }

    // --- OPERATION -------------------------------------------------

    /// @notice Lend to a cooler.
    /// @dev    To simplify the UX and easily ensure that all holders get the same terms,
    ///         this function requests a new loan and clears it in the same transaction.
    /// @param  cooler_ to lend to.
    /// @param  amount_ of DAI to lend.
    /// @return the id of the granted loan.
    function lendToCooler(Cooler cooler_, uint256 amount_) external returns (uint256) {
        // Attempt a clearinghouse <> treasury rebalance.
        rebalance();
        // Validate that cooler was deployed by the trusted factory.
        if (!factory.created(address(cooler_))) revert OnlyFromFactory();
        // Validate cooler collateral and debt tokens.
        if (cooler_.collateral() != gOHM || cooler_.debt() != dai) revert BadEscrow();

        // Compute and access collateral.
        uint256 collateral = cooler_.collateralFor(amount_, LOAN_TO_COLLATERAL);
        gOHM.transferFrom(msg.sender, address(this), collateral);

        // Create loan request.
        gOHM.approve(address(cooler_), collateral);
        uint256 reqID = cooler_.requestLoan(amount_, INTEREST_RATE, LOAN_TO_COLLATERAL, DURATION);

        // Clear loan request by providing enough DAI.
        sDai.withdraw(amount_, address(this), address(this));
        dai.approve(address(cooler_), amount_);
        uint256 loanID = cooler_.clearRequest(reqID, true, true);

        // Increment loan receivables.
        receivables += loanForCollateral(collateral);
        
        return loanID;
    }

    /// @notice Rollover an existing loan.
    /// @dev    To simplify the UX and easily ensure that all holders get the same terms,
    ///         this function provides the governance-approved terms for a rollover and
    ///         does the loan rollover in the same transaction.
    /// @param  cooler_ to provide terms.
    /// @param  loanID_ of loan in cooler.
    function rollLoan(Cooler cooler_, uint256 loanID_) external {
        // Provide rollover terms.
        cooler_.provideNewTermsForRoll(loanID_, INTEREST_RATE, LOAN_TO_COLLATERAL, DURATION);

        // Collect applicable new collateral from user.
        uint256 newCollateral = cooler_.newCollateralFor(loanID_);
        gOHM.transferFrom(msg.sender, address(this), newCollateral);

        // Roll loan.
        gOHM.approve(address(cooler_), newCollateral);
        cooler_.rollLoan(loanID_);

        // Increment loan receivables.
        receivables += loanForCollateral(newCollateral);
    }

    /// @notice Callback to attept a treasury rebalance.
    /// *unused loadID_ of the load.
    function onRoll(uint256) external override {
        rebalance();
    }

    /// @notice Callback to decrement loan receivables.
    /// *unused loadID_ of the load.
    /// @param amount_ repaid (in DAI).
    function onRepay(uint256, uint256 amount_) external override {
        // Validate caller is cooler
        if (!factory.created(msg.sender)) revert OnlyFromFactory();

        // Decrement loan receivables.
        receivables -= amount_;
        // Attempt a clearinghouse <> treasury rebalance.
        rebalance();
    }

    /// @notice Callback to account for defaults. Adjusts Treasury debt and OHM supply.
    /// *unused loadID_ of the load.
    /// @param amount_ defaulted (in DAI).
    /// @param collateral_ that can be taken (in gOHM).
    function onDefault(uint256, uint256 amount_, uint256 collateral_) external override {
        // Validate caller is cooler.
        if (!factory.created(msg.sender)) revert OnlyFromFactory();

        // Update outstanding debt owed to the Treasury upon default.
        uint256 outstandingDebt = TRSRY.reserveDebt(sDai, address(this));
        // Since TRSRY denominates in sDAI, DAI must be converted beforehand.
        TRSRY.setDebt(address(this), sDai, outstandingDebt - sDai.previewDeposit(amount_));

        // Unstake and burn the collateral of the defaulted loan.
        gOHM.approve(address(staking), collateral_);
        MINTR.burnOhm(address(this), staking.unstake(address(this), collateral_, false, false));

        // Decrement loan receivables.
        receivables = (receivables > amount_) ? receivables - amount_ : 0;
        // Attempt a clearinghouse <> treasury rebalance.
        rebalance();
    }

    // --- FUNDING ---------------------------------------------------

    /// @notice Fund loan liquidity from treasury.
    /// @dev    Exposure is always capped at FUND_AMOUNT and rebalanced at up to FUND_CADANCE.
    ///         If several rebalances are available (because some were missed), calling this
    ///         function several times won't impact the funds controlled by the contract.
    /// @return False if too early to rebalance. Otherwise, true.
    function rebalance() public returns (bool) {
        if (fundTime > block.timestamp) return false;
        fundTime += FUND_CADENCE;
        // Since TRSRY is sDAI denominated, the Clearinghouse should always try to have all its
        // reserves in the DSR too.
        sweepIntoDSR();

        uint256 balance = sDai.maxWithdraw(address(this));

        // Rebalance funds on hand with treasury's reserves.
        if (balance < FUND_AMOUNT) {
            uint256 fundAmount = FUND_AMOUNT - balance;
            // Since TRSRY denominates in sDAI, a conversion must be done beforehand.
            uint256 amount = sDai.previewWithdraw(fundAmount);
            // Fund the clearinghouse with treasury assets.
            TRSRY.increaseDebtorApproval(address(this), sDai, amount);
            TRSRY.incurDebt(sDai, amount);
        } else if (balance > FUND_AMOUNT) {
            uint256 defundAmount = balance - FUND_AMOUNT;
            // Since TRSRY denominates in sDAI, a conversion must be done beforehand.
            uint256 amount = sDai.previewWithdraw(defundAmount);
            // Send sDAI back to the treasury
            sDai.approve(address(TRSRY), amount);
            TRSRY.repayDebt(address(this), sDai, amount);
        }
        return true;
    }

    /// @notice Sweep excess DAI into vault.
    function sweepIntoDSR() public {
        uint256 balance = dai.balanceOf(address(this));
        if (balance != 0) {
            dai.approve(address(sDai), balance);
            sDai.deposit(balance, address(this));
        }
    }

    /// @notice Return funds to treasury.
    /// @param  token_ to transfer.
    /// @param  amount_ to transfer.
    function defund(ERC20 token_, uint256 amount_) external onlyRole("cooler_overseer") {
        if (token_ == gOHM) revert OnlyBurnable();

        // If there is an outstanding debt, repay it.
        if (TRSRY.reserveDebt(token_, address(this)) != 0) {
            token_.approve(address(TRSRY), amount_);
            TRSRY.repayDebt(address(this), token_, amount_);
        }
        // Otherwise, transfer just the tokens.
        else {
            token_.transfer(address(TRSRY), amount_);
        }
    }

    // --- AUX FUNCTIONS ---------------------------------------------
    
    /// @notice view function computing loan for a collateral amount.
    /// @param  collateral_ amount of gOHM.
    /// @return debt (amount to be lent + interest) for a given collateral amount.
    function loanForCollateral(uint256 collateral_) public pure returns (uint256) {
        uint256 interestPercent = (INTEREST_RATE * DURATION) / 365 days;
        uint256 loan = collateral_ * LOAN_TO_COLLATERAL / 1e18;
        uint256 interest = loan * interestPercent / 1e18;
        return loan + interest;
    }
}