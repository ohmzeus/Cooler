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

contract ClearingHouse is Policy, RolesConsumer, CoolerCallback {

    // --- ERRORS ----------------------------------------------------

    error BadEscrow();
    error DurationMaximum();
    error OnlyBurnable();
    error TooEarlyToFund();
    error LengthDiscrepancy();
    
    // --- RELEVANT CONTRACTS ----------------------------------------

    ERC20 public immutable dai;
    ERC4626 public immutable sdai;
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
    ) Policy(Kernel(kernel_)) CoolerCallback(coolerFactory_) {
        gOHM = ERC20(gohm_);
        staking = IStaking(staking_);
        sdai = ERC4626(sdai_);
        dai = ERC20(sdai.asset());
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

        requests = new Permissions[](4);
        requests[0] = Permissions(TRSRY_KEYCODE, TRSRY.setDebt.selector);
        requests[1] = Permissions(TRSRY_KEYCODE, TRSRY.increaseWithdrawApproval.selector);
        requests[2] = Permissions(TRSRY_KEYCODE, TRSRY.withdrawReserves.selector);
        requests[3] = Permissions(toKeycode("MINTR"), MINTR.burnOhm.selector);
    }

    // --- OPERATION -------------------------------------------------

    /// @notice Lend to a cooler.
    /// @param cooler_ to lend to.
    /// @param amount_ of DAI to lend.
    /// @return the ID of the new loan.
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
        sdai.withdraw(amount_, address(this), address(this));
        dai.approve(address(cooler_), amount_);
        uint256 loanID = cooler_.clearRequest(reqID, true, true);

        // Increment loan receivables.
        receivables += debtForCollateral(collateral);
        
        return loanID;
    }

    /// @notice Provide terms for loan and execute the rollover.
    /// @param cooler_ to provide terms.
    /// @param loanID_ of loan in cooler.
    function rollLoan(Cooler cooler_, uint256 loanID_) external {
        // Provide rollover terms.
        cooler_.provideNewTermsForRoll(loanID_, INTEREST_RATE, LOAN_TO_COLLATERAL, DURATION);

        // Collect applicable new collateral from user.
        uint256 newCollateral = cooler_.newCollateralFor(loanID_);
        if (newCollateral > 0) {
            gOHM.transferFrom(msg.sender, address(this), newCollateral);
            gOHM.approve(address(cooler_), newCollateral);
        }

        // Roll loan.
        cooler_.rollLoan(loanID_);

        // Increment loan receivables.
        receivables += debtForCollateral(newCollateral);
    }

    /// @notice Batch several default claims to save gas.
    ///         The elements on both arrays must be paired based on their index.
    /// @param coolers_ Contracts where the default must be claimed.
    /// @param loans_ IDs of the defaulted loans.
    function claimDefaulted(address[] calldata coolers_, uint256[] calldata loans_) external {
        uint256 loans = loans_.length;
        if (loans != coolers_.length) revert LengthDiscrepancy();

        uint256 totalDebt;
        uint256 totalInterest;
        uint256 totalCollateral;
        for (uint256 i=0; i < loans;) {
            (uint256 debt, uint256 collateral) = Cooler(coolers_[i]).claimDefaulted(loans_[i]);
            uint256 interest = interestFromDebt(debt);
            unchecked {
                // Cannot overflow due to max supply limits for both tokens
                totalDebt += debt;
                totalInterest += interest;
                totalCollateral += collateral;
                // There will not exist more than 2**256 loans
                ++i;
            }
        }

        // Decrement loan receivables.
        receivables = (receivables > totalDebt) ? receivables - totalDebt : 0;
        // Update outstanding debt owed to the Treasury upon default.
        uint256 outstandingDebt = TRSRY.reserveDebt(dai, address(this));
        // debt owed to TRSRY = user debt - user interest
        TRSRY.setDebt({
            debtor_: address(this),
            token_: dai,
            amount_: outstandingDebt - (totalDebt - totalInterest)
        });
        // Unstake and burn the collateral of the defaulted loans.
        gOHM.approve(address(staking), totalCollateral);
        MINTR.burnOhm(address(this), staking.unstake(address(this), totalCollateral, false, false));
    }

    // --- CALLBACKS -----------------------------------------------------

    /// @notice Overridden callback to decrement loan receivables.
    /// @param *unused loadID_ of the load.
    /// @param amount_ repaid (in DAI).
    function _onRepay(uint256, uint256 amount_) internal override {
        _sweepIntoDSR(amount_);

        // Decrement loan receivables.
        receivables = (receivables > amount_) ? receivables - amount_ : 0;
    }
    
    /// @notice Unused callback since rollovers are handled by the clearinghouse.
    /// @dev Overriden and left empty to save gas.
    function _onRoll(uint256, uint256, uint256) internal override {}

    /// @notice Unused callback since defaults are handled by the clearinghouse.
    /// @dev Overriden and left empty to save gas.
    function _onDefault(uint256, uint256, uint256) internal override {}

    // --- FUNDING ---------------------------------------------------

    /// @notice Fund loan liquidity from treasury. Returns false if too early to rebalance.
    ///         Exposure is always capped at FUND_AMOUNT and rebalanced at up to FUND_CADANCE.
    ///         If several rebalances are available (because some were missed), calling this
    ///         function several times won't impact the funds controlled by the contract.
    function rebalance() public returns (bool) {
        if (fundTime > block.timestamp) return false;
        fundTime += FUND_CADENCE;

        uint256 daiBalance = sdai.maxWithdraw(address(this));
        uint256 outstandingDebt = TRSRY.reserveDebt(dai, address(this));
        // Rebalance funds on hand with treasury's reserves.
        if (daiBalance < FUND_AMOUNT) {
            // Since users loans are denominated in DAI, the clearinghouse
            // debt is set in DAI terms. It must be adjusted when funding.
            uint256 fundAmount = FUND_AMOUNT - daiBalance;
            TRSRY.setDebt({
                debtor_: address(this),
                token_: dai,
                amount_: outstandingDebt + fundAmount
            });

            // Since TRSRY holds sDAI, a conversion must be done before
            // funding the clearinghouse.
            uint256 sdaiAmount = sdai.previewWithdraw(fundAmount);
            TRSRY.increaseWithdrawApproval(address(this), sdai, sdaiAmount);
            TRSRY.withdrawReserves(address(this), sdai, sdaiAmount);

            // Sweep DAI into DSR if necessary.
            uint256 idle = dai.balanceOf(address(this));
            if (idle != 0) _sweepIntoDSR(idle);
        } else if (daiBalance > FUND_AMOUNT) {
            // Since users loans are denominated in DAI, the clearinghouse
            // debt is set in DAI terms. It must be adjusted when defunding.
            uint256 defundAmount = daiBalance - FUND_AMOUNT;
            TRSRY.setDebt({
                debtor_: address(this),
                token_: dai,
                amount_: (outstandingDebt > defundAmount) ? outstandingDebt - defundAmount : 0
            });

            // Since TRSRY holds sDAI, a conversion must be done before
            // sending sDAI back.
            uint256 sdaiAmount = sdai.previewWithdraw(defundAmount);
            sdai.approve(address(TRSRY), sdaiAmount);
            sdai.transfer(address(TRSRY), sdaiAmount);
        }
        return true;
    }

    /// @notice Sweep excess DAI into vault.
    function sweepIntoDSR() public {
        uint256 daiBalance = dai.balanceOf(address(this));
        _sweepIntoDSR(daiBalance);
    }

    /// @notice Sweep excess DAI into vault.
    function _sweepIntoDSR(uint256 amount_) internal {
        dai.approve(address(sdai), amount_);
        sdai.deposit(amount_, address(this));
    }

    /// @notice Return funds to treasury.
    /// @param token_ to transfer.
    /// @param amount_ to transfer.
    function defund(ERC20 token_, uint256 amount_) external onlyRole("cooler_overseer") {
        if (token_ == gOHM) revert OnlyBurnable();
        if (token_ == sdai) {
            // Since users loans are denominated in DAI, the clearinghouse
            // debt is set in DAI terms. It must be adjusted when defunding.
            uint256 outstandingDebt = TRSRY.reserveDebt(dai, address(this));
            uint256 daiAmount = sdai.previewRedeem(amount_);
            TRSRY.setDebt({
                debtor_: address(this),
                token_: dai,
                amount_: (outstandingDebt > daiAmount) ? outstandingDebt - daiAmount : 0
            });
        }
        
        token_.transfer(address(TRSRY), amount_);
    }

    // --- AUX FUNCTIONS ---------------------------------------------
    
    /// @notice view function to compute the total debt for a given collateral amount.
    /// @param collateral_ amount of gOHM.
    function debtForCollateral(uint256 collateral_) public pure returns (uint256) {
        uint256 interestPercent = (INTEREST_RATE * DURATION) / 365 days;
        uint256 loan = collateral_ * LOAN_TO_COLLATERAL / 1e18;
        uint256 interest = loan * interestPercent / 1e18;
        return loan + interest;
    }
    
    /// @notice view function to compute the interest for a given debt amount.
    /// @param debt_ amount of gOHM.
    function interestFromDebt(uint256 debt_) public pure returns (uint256) {
        uint256 interestPercent = (INTEREST_RATE * DURATION) / 365 days;
        return debt_ * interestPercent / 1e18;
    }
}