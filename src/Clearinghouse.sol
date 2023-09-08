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
///         Although the Cooler contracts allow lenders to transfer ownership of their repayment rights, the
///         Clearinghouse doesn't implement any functions to use that feature.
contract Clearinghouse is Policy, RolesConsumer, CoolerCallback {

    // --- ERRORS ----------------------------------------------------

    error BadEscrow();
    error DurationMaximum();
    error OnlyBurnable();
    error TooEarlyToFund();
    error LengthDiscrepancy();
    error OnlyBorrower();
    error OnlyLender();

    // --- EVENTS ----------------------------------------------------

    event Deactivated();
    event Reactivated();
    
    // --- RELEVANT CONTRACTS ----------------------------------------

    ERC20 public immutable dai;             // Debt token
    ERC4626 public immutable sdai;          // Idle DAI will wrapped into sDAI
    ERC20 public immutable gOHM;            // Collateral token
    IStaking public immutable staking;      // Necessary to unstake (and burn) OHM from defaults
    
    // --- MODULES ---------------------------------------------------

    TRSRYv1 public TRSRY;      // Olympus V3 Treasury Module
    MINTRv1 public MINTR;      // Olympus V3 Minter Module

    // --- PARAMETER BOUNDS ------------------------------------------

    uint256 public constant INTEREST_RATE = 5e15;               // 0.5% anually
    uint256 public constant LOAN_TO_COLLATERAL = 3000e18;       // 3,000 DAI/gOHM
    uint256 public constant DURATION = 121 days;                // Four months
    uint256 public constant FUND_CADENCE = 7 days;              // One week
    uint256 public constant FUND_AMOUNT = 18_000_000e18;        // 18 million
    uint256 public constant MAX_REWARD = 1e17;                  // 0.1 gOHM

    // --- STATE VARIABLES -------------------------------------------

    /// @notice determines whether the contract can be funded or not.
    bool public active;

    /// @notice timestamp at which the next rebalance can occur.
    uint256 public fundTime;

    // TODO change to interest receivable
    /// @notice Outstanding interest receivables.
    /// Incremented when a loan is taken or rolled.
    /// Decremented when a loan is repaid or collateral is burned.
    uint256 public interestReceivables;

    // --- INITIALIZATION --------------------------------------------

    constructor(
        address gohm_,
        address staking_,
        address sdai_,
        address coolerFactory_,
        address kernel_
    ) Policy(Kernel(kernel_)) CoolerCallback(coolerFactory_) {
        // Store the relevant contracts.
        gOHM = ERC20(gohm_);
        staking = IStaking(staking_);
        sdai = ERC4626(sdai_);
        dai = ERC20(sdai.asset());
        
        // Initialize the contract status and its funding schedule.
        active = true;
        fundTime = block.timestamp;
    }

    /// @notice Default framework setup. Configure dependencies for olympus-v3 modules.
    /// @dev    This function will be called when the `executor` installs the Clearinghouse
    ///         policy in the olympus-v3 `Kernel`.
    function configureDependencies() external override returns (Keycode[] memory dependencies) {
        dependencies = new Keycode[](3);
        dependencies[0] = toKeycode("TRSRY");
        dependencies[1] = toKeycode("MINTR");
        dependencies[2] = toKeycode("ROLES");

        TRSRY = TRSRYv1(getModuleAddress(toKeycode("TRSRY")));
        MINTR = MINTRv1(getModuleAddress(toKeycode("MINTR")));
        ROLES = ROLESv1(getModuleAddress(toKeycode("ROLES")));
    }

    /// @notice Default framework setup. Request permissions for interacting with olympus-v3 modules.
    /// @dev    This function will be called when the `executor` installs the Clearinghouse
    ///         policy in the olympus-v3 `Kernel`.
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

        // Transfer in collateral owed
        uint256 collateral = cooler_.collateralFor(amount_, LOAN_TO_COLLATERAL);
        gOHM.transferFrom(msg.sender, address(this), collateral);

        // Increment interest to be expected
        (, uint256 interest) = getLoanForCollateral(collateral);
        interestReceivables += interest;

        // Create a new loan request.
        gOHM.approve(address(cooler_), collateral);
        uint256 reqID = cooler_.requestLoan(amount_, INTEREST_RATE, LOAN_TO_COLLATERAL, DURATION);

        // Clear the created loan request by providing enough DAI.
        sdai.withdraw(amount_, address(this), address(this));
        dai.approve(address(cooler_), amount_);
        uint256 loanID = cooler_.clearRequest(reqID, address(this), true);
        
        return loanID;
    }

    // Repay current loan interest due then extend loan duration and interest to original terms
    function extendLoan(Cooler cooler_, uint256 loanID_) external {
        // Attempt a clearinghouse <> treasury rebalance.
        rebalance();

        Cooler.Loan memory loan = cooler_.getLoan(loanID_);

        // Ensure we are the lender
        if (loan.lender != address(this)) revert OnlyLender();

        // Ensure caller is the borrower
        if (cooler_.owner() != msg.sender) revert OnlyBorrower();

        // Calculate interest due
        uint256 durationPassed = block.timestamp - loan.loanStart;
        uint256 interestDue = interestForLoan(loan.principle, durationPassed);

        // Transfer in interest due
        dai.approve(msg.sender, interestDue);
        dai.transferFrom(
            msg.sender,
            loan.recipient,
            interestDue
        );

        // Signal to cooler to repay interest due and extend loan
        cooler_.extendLoanTerms(loanID_);

        // TODO need to simplify this
        // Remove interest due, then add new interest
        interestReceivables -= interestDue;
        interestReceivables += interestForLoan(loan.principle, loan.request.duration);
    }

    /// @notice Batch several default claims to save gas.
    ///         The elements on both arrays must be paired based on their index.
    /// @dev    Implements an auction style reward system that linearly increases up to a max reward.
    /// @param  coolers_ Array of contracts where the default must be claimed.
    /// @param  loans_ Array of defaulted loan ids.
    function claimDefaulted(address[] calldata coolers_, uint256[] calldata loans_) external {
        uint256 loans = loans_.length;
        if (loans != coolers_.length) revert LengthDiscrepancy();

        uint256 totalPrinciple;
        uint256 totalInterest;
        uint256 totalCollateral;
        uint256 keeperRewards;
        for (uint256 i=0; i < loans;) {
            // Validate that cooler was deployed by the trusted factory.
            if (!factory.created(coolers_[i])) revert OnlyFromFactory();
            
            // Claim defaults and update cached metrics.
            (uint256 principle, uint256 interest ,uint256 collateral, uint256 elapsed) = Cooler(coolers_[i]).claimDefaulted(loans_[i]);

            // TODO make sure recievables is updated properly with interest split
            unchecked {
                // Cannot overflow due to max supply limits for both tokens
                totalPrinciple += principle;
                totalInterest += interest;
                totalCollateral += collateral;
                // There will not exist more than 2**256 loans
                ++i;
            }

            // Cap rewards to 5% of the collateral to avoid OHM holder's dillution.
            uint256 maxAuctionReward = collateral * 5e16 / 1e18;

            // Cap rewards to avoid exorbitant amounts.
            uint256 maxReward = (maxAuctionReward < MAX_REWARD)
                ? maxAuctionReward
                : MAX_REWARD;

            // Calculate rewards based on the elapsed time since default.
            keeperRewards = (elapsed < 7 days)
                ? keeperRewards + maxReward * elapsed / 7 days
                : keeperRewards + maxReward;
        }

        // Decrement loan receivables.
        interestReceivables = (interestReceivables > totalInterest) ? interestReceivables - totalInterest : 0;

        // Update outstanding debt owed to the Treasury upon default.
        uint256 outstandingDebt = TRSRY.reserveDebt(dai, address(this));

        // debt owed to TRSRY = user debt - user interest
        TRSRY.setDebt({
            debtor_: address(this),
            token_: dai,
            amount_: (outstandingDebt > totalPrinciple)
                ? outstandingDebt - totalPrinciple
                : 0
        });

        // Reward keeper.
        gOHM.transfer(msg.sender, keeperRewards);

        // Unstake and burn the collateral of the defaulted loans.
        gOHM.approve(address(staking), totalCollateral - keeperRewards);
        MINTR.burnOhm(address(this), staking.unstake(address(this), totalCollateral - keeperRewards, false, false));
    }

    // --- CALLBACKS -----------------------------------------------------

    /// @notice Overridden callback to decrement interest receivables.
    function _onRepay(uint256, uint256 principlePaid_, uint256 interestPaid_) internal override {
        _sweepIntoDSR(principlePaid_ + interestPaid_);

        // Decrement loan receivables.
        interestReceivables = (interestReceivables > interestPaid_)
            ? interestReceivables - interestPaid_
            : 0;
    }
    
    /// @notice Unused callback since defaults are handled by the clearinghouse.
    /// @dev Overriden and left empty to save gas.
    function _onDefault(uint256, uint256, uint256, uint256) internal override {}

    // --- FUNDING ---------------------------------------------------

    /// @notice Fund loan liquidity from treasury.
    /// @dev    Exposure is always capped at FUND_AMOUNT and rebalanced at up to FUND_CADANCE.
    ///         If several rebalances are available (because some were missed), calling this
    ///         function several times won't impact the funds controlled by the contract.
    ///         If the emergency shutdown is triggered, a rebalance will send funds back to
    ///         the treasury.
    /// @return False if too early to rebalance. Otherwise, true.
    function rebalance() public returns (bool) {
        // If the contract is deactivated, defund.
        uint256 maxFundAmount = active ? FUND_AMOUNT : 0;        
        // Update funding schedule if necessary.
        if (fundTime > block.timestamp) return false;
        fundTime += FUND_CADENCE;

        uint256 daiBalance = sdai.maxWithdraw(address(this));
        uint256 outstandingDebt = TRSRY.reserveDebt(dai, address(this));
        // Rebalance funds on hand with treasury's reserves.
        if (daiBalance < maxFundAmount) {
            // Since users loans are denominated in DAI, the clearinghouse
            // debt is set in DAI terms. It must be adjusted when funding.
            uint256 fundAmount = maxFundAmount - daiBalance;
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
        } else if (daiBalance > maxFundAmount) {
            // Since users loans are denominated in DAI, the clearinghouse
            // debt is set in DAI terms. It must be adjusted when defunding.
            uint256 defundAmount = daiBalance - maxFundAmount;
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
    /// @param  token_ to transfer.
    /// @param  amount_ to transfer.
    function defund(ERC20 token_, uint256 amount_) public onlyRole("cooler_overseer") {
        if (token_ == gOHM) revert OnlyBurnable();
        if (token_ == sdai || token_ == dai) {
            // Since users loans are denominated in DAI, the clearinghouse
            // debt is set in DAI terms. It must be adjusted when defunding.
            uint256 outstandingDebt = TRSRY.reserveDebt(dai, address(this));
            uint256 daiAmount = (token_ == sdai)
                ? sdai.previewRedeem(amount_)
                : amount_;
    
            TRSRY.setDebt({
                debtor_: address(this),
                token_: dai,
                amount_: (outstandingDebt > daiAmount) ? outstandingDebt - daiAmount : 0
            });
        }

        token_.transfer(address(TRSRY), amount_);
    }

    /// @notice Deactivate the contract and return funds to treasury.
    function emergencyShutdown() external onlyRole("emergency_shutdown") {
        active = false;

        // If necessary, defund sDAI.
        uint256 sdaiBalance = sdai.balanceOf(address(this));
        if (sdaiBalance != 0) defund(sdai, sdaiBalance);

        // If necessary, defund DAI.
        uint256 daiBalance = dai.balanceOf(address(this));
        if (daiBalance != 0) defund(dai, daiBalance);

        emit Deactivated();
    }

    /// @notice Reactivate the contract.
    function reactivate() external onlyRole("cooler_overseer") {
        active = true;

        emit Reactivated();
    }

    // --- AUX FUNCTIONS ---------------------------------------------
    
    // TODO Can make test to verify getLoanForCollateral == getCollateralForLoan

    /// @notice view function computing collateral for a loan amount.
    function getCollateralForLoan(uint256 principle_) external pure returns (uint256) {
        return principle_ * 1e18 / LOAN_TO_COLLATERAL;
    }
    
    /// @notice view function computing loan for a collateral amount.
    /// @param  collateral_ amount of gOHM.
    /// @return debt (amount to be lent + interest) for a given collateral amount.
    function getLoanForCollateral(uint256 collateral_) public pure returns (uint256, uint256) {
        uint256 principle = collateral_ * LOAN_TO_COLLATERAL / 1e18;
        uint256 interest = interestForLoan(principle, DURATION);
        return (principle, interest);
    }

    /// @notice view function to compute the interest for given principle amount.
    /// @param principle_ amount of DAI being lent.
    /// @param duration_ elapsed time in seconds.
    function interestForLoan(uint256 principle_, uint256 duration_) public pure returns (uint256) {
        uint256 interestPercent = (INTEREST_RATE * duration_) / 365 days;
        return principle_ * interestPercent / 1e18;
    }
    
    /// @notice Get total receivable DAI for the treasury
    /// @dev    Includes both principle and interest
    function getTotalReceivable() external view returns (uint256) {
        return TRSRY.reserveDebt(dai, address(this)) + interestReceivables;
    }
}
