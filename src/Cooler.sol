// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {Clone} from "clones/Clone.sol";

import {IDelegate} from "interfaces/IDelegate.sol";
import {CoolerFactory} from "src/CoolerFactory.sol";
import {CoolerCallback} from "src/CoolerCallback.sol";

/// @title  Cooler Loans.
/// @notice A Cooler is a smart contract escrow that facilitates fixed-duration, peer-to-peer
///         loans for a user-defined debt-collateral pair.
/// @dev    This contract uses Clones (https://github.com/wighawag/clones-with-immutable-args)
///         to save gas on deployment.
contract Cooler is Clone {
    using SafeTransferLib for ERC20;

    // --- ERRORS ----------------------------------------------------

    error OnlyApproved();
    error Deactivated();
    error Default();
    error NoDefault();
    error NotRollable();
    error ZeroCollateralReturned();
    error NotCoolerCallback();

    // --- DATA STRUCTURES -------------------------------------------

    /// @notice A loan begins with a borrow request.
    struct Request {
        uint256 amount;             // Amount to be borrowed.
        uint256 interest;           // Annualized percentage to be paid as interest.
        uint256 loanToCollateral;   // Requested loan-to-collateral ratio.
        uint256 duration;           // Time to repay the loan before it defaults.
        bool active;                // Any lender can clear an active loan request.
    }

    /// @notice A request is converted to a loan when a lender clears it.
    struct Loan {
        Request request;        // Loan terms specified in the request.
        uint256 amount;         // Amount of debt owed to the lender.
        uint256 unclaimed;      // Amount of debt tokens repaid but unclaimed.
        uint256 collateral;     // Amount of collateral pledged.
        uint256 expiry;         // Time when the loan defaults.
        address lender;         // Lender's address.
        bool repayDirect;       // If this is false, repaid tokens must be claimed by lender.
        bool callback;          // If this is true, the lender must inherit CoolerCallback.
    }

    // --- IMMUTABLES ------------------------------------------------

    // This makes the code look prettier.
    uint256 private constant DECIMALS_INTEREST = 1e18;

    /// @notice This address owns the collateral in escrow.
    function owner() public pure returns (address _owner) {
        return _getArgAddress(0x0);
    }

    /// @notice This token is borrowed against.
    function collateral() public pure returns (ERC20 _collateral) {
        return ERC20(_getArgAddress(0x14));
    }

    /// @notice This token is lent.
    function debt() public pure returns (ERC20 _debt) {
        return ERC20(_getArgAddress(0x28));
    }
    
    /// @notice This contract created the Cooler
    function factory() public pure returns (CoolerFactory _factory) {
        return CoolerFactory(_getArgAddress(0x3c));
    }

    // --- STATE VARIABLES -------------------------------------------

    /// @notice Arrays stores all the loan requests.
    Request[] public requests;

    /// @notice Arrays stores all the granted loans.
    Loan[] public loans;

    /// @notice Facilitates transfer of lender ownership to new addresses
    mapping(uint256 => address) public approvals;

    // --- BORROWER --------------------------------------------------

    /// @notice Request a loan with given parameters.
    ///         Collateral is taken at time of request.
    /// @param  amount_ of debt tokens to borrow.
    /// @param  interest_ to pay (annualized % of 'amount_'). Expressed in DECIMALS_INTEREST.
    /// @param  loanToCollateral_ debt tokens per collateral token pledged. Expressed in 10**debt().decimals().
    /// @param  duration_ of loan tenure in seconds.
    /// @return reqID of the created request. Equivalent to the index of request in requests[].
    function requestLoan(
        uint256 amount_,
        uint256 interest_,
        uint256 loanToCollateral_,
        uint256 duration_
    ) external returns (uint256 reqID) {
        reqID = requests.length;
        requests.push(
            Request({
                amount: amount_,
                interest: interest_,
                loanToCollateral: loanToCollateral_,
                duration: duration_,
                active: true
            })
        );

        // The collateral is taken upfront. Will be escrowed
        // until the loan is repaid or defaulted.
        collateral().safeTransferFrom(
            msg.sender,
            address(this),
            collateralFor(amount_, loanToCollateral_)
        );

        // Log the event.
        factory().newEvent(reqID, CoolerFactory.Events.RequestLoan, 0);
    }

    /// @notice Cancel a loan request and get the collateral back.
    /// @param  reqID_ index of request in requests[].
    function rescindRequest(uint256 reqID_) external {
        if (msg.sender != owner()) revert OnlyApproved();

        Request storage req = requests[reqID_];

        if (!req.active) revert Deactivated();

        // Update storage and send collateral back to the owner.
        req.active = false;
        collateral().safeTransfer(owner(), collateralFor(req.amount, req.loanToCollateral));

        // Log the event.
        factory().newEvent(reqID_, CoolerFactory.Events.RescindRequest, 0);
    }

    /// @notice Repay a loan to get the collateral back.
    /// @dev    Despite a malicious lender could reenter with the callback, the
    ///         usage of `msg.sender` prevents any economical benefit to the
    ///         attacker, since they would be repaying the loan themselves.
    /// @param  loanID_ index of loan in loans[]
    /// @param  repaid_ debt tokens to be repaid.
    /// @return collateral given back to the borrower.
    function repayLoan(uint256 loanID_, uint256 repaid_) external returns (uint256) {
        Loan memory loan = loans[loanID_];

        if (block.timestamp > loan.expiry) revert Default();

        if (repaid_ > loan.amount) repaid_ = loan.amount;

        uint256 decollateralized = (loan.collateral * repaid_) / loan.amount;
        if (decollateralized == 0) revert ZeroCollateralReturned();

        // Update loan memory.
        loan.amount -= repaid_;
        loan.collateral -= decollateralized;

        address repayTo;
        // Check whether repayment needs to be manually claimed or not.
        if (loan.repayDirect) {
            repayTo = loan.lender;
        } else {
            repayTo = address(this);
            loan.unclaimed += repaid_;
        }

        // Save updated loan info in storage.
        loans[loanID_] = loan;

        // Transfer repaid debt back to the lender and (de)collateral back to the owner.
        debt().safeTransferFrom(msg.sender, repayTo, repaid_);
        collateral().safeTransfer(owner(), decollateralized);

        // Log the event.
        factory().newEvent(loanID_, CoolerFactory.Events.RepayLoan, repaid_);

        // If necessary, trigger lender callback.
        if (loan.callback) CoolerCallback(loan.lender).onRepay(loanID_, repaid_);
        return decollateralized;
    }

    /// @notice Roll a loan over with new terms.
    ///         provideNewTermsForRoll must have been called beforehand by the lender.
    /// @param  loanID_ index of loan in loans[].
    function rollLoan(uint256 loanID_) external {
        Loan memory loan = loans[loanID_];

        if (block.timestamp > loan.expiry) revert Default();
        if (!loan.request.active) revert NotRollable();

        // Check whether rolling the loan requires pledging more collateral or not (if there was a previous repayment).
        uint256 newCollateral = newCollateralFor(loanID_);
        uint256 newDebt = interestFor(loan.amount, loan.request.interest, loan.request.duration);

        // Update memory accordingly.
        loan.amount += newDebt;
        loan.collateral += newCollateral;
        loan.expiry += loan.request.duration;
        loan.request.active = false;

        // Save updated loan info in storage.
        loans[loanID_] = loan;

        if (newCollateral > 0) {
            collateral().safeTransferFrom(msg.sender, address(this), newCollateral);
        }

        // If necessary, trigger lender callback.
        if (loan.callback) CoolerCallback(loan.lender).onRoll(loanID_, newDebt, newCollateral);
    }

    /// @notice Delegate voting power on collateral.
    /// @param  to_ address to delegate.
    function delegateVoting(address to_) external {
        if (msg.sender != owner()) revert OnlyApproved();
        IDelegate(address(collateral())).delegate(to_);
    }

    // --- LENDER ----------------------------------------------------

    /// @notice Fill a requested loan as a lender.
    /// @param  reqID_ index of request in requests[].
    /// @param  repayDirect_ lender should input false if concerned about debt token blacklisting.
    /// @param  isCallback_ true if the lender implements the CoolerCallback abstract. False otherwise.
    /// @return loanID of the granted loan. Equivalent to the index of loan in loans[].
    function clearRequest(
        uint256 reqID_,
        bool repayDirect_,
        bool isCallback_
    ) external returns (uint256 loanID) {
        Request memory req = requests[reqID_];

        // IF necessary, ensure lender implements the CoolerCallback abstract.
        if (isCallback_ && !CoolerCallback(msg.sender).isCoolerCallback()) revert NotCoolerCallback();

        // Ensure loan request is active. 
        if (!req.active) revert Deactivated();

        // Clear the loan request in both, memory and storage.
        req.active = false;
        requests[reqID_].active = false;

        // Calculate and store loan terms.
        uint256 interest = interestFor(req.amount, req.interest, req.duration);
        uint256 collat = collateralFor(req.amount, req.loanToCollateral);
        uint256 expiration = block.timestamp + req.duration;
        loanID = loans.length;
        loans.push(
            Loan({
                request: req,
                amount: req.amount + interest,
                unclaimed: 0,
                collateral: collat,
                expiry: expiration,
                lender: msg.sender,
                repayDirect: repayDirect_,
                callback: isCallback_
            })
        );

        // Transfer debt tokens to the owner of the request.
        debt().safeTransferFrom(msg.sender, owner(), req.amount);

        // Log the event.
        factory().newEvent(reqID_, CoolerFactory.Events.ClearRequest, 0);
    }

    /// @notice Provide new terms for loan to be rolled over.
    /// @param  loanID_ index of loan in loans[].
    /// @param  interest_ to pay (annualized % of 'amount_'). Expressed in DECIMALS_INTEREST.
    /// @param  loanToCollateral_ debt tokens per collateral token pledged. Expressed in 10**debt().decimals().
    /// @param  duration_ of loan tenure in seconds.
    function provideNewTermsForRoll(
        uint256 loanID_,
        uint256 interest_,
        uint256 loanToCollateral_,
        uint256 duration_
    ) external {
        Loan storage loan = loans[loanID_];

        if (msg.sender != loan.lender) revert OnlyApproved();

        loan.request =
            Request(
                loan.amount,
                interest_,
                loanToCollateral_,
                duration_,
                true
            );
    }

    /// @notice Claim debt tokens if repayDirect was false.
    /// @param  loanID_ index of loan in loans[].
    function claimRepaid(uint256 loanID_) external {
        Loan memory loan = loans[loanID_];

        // Update storage.
        uint256 claim = loan.unclaimed;
        delete loans[loanID_].unclaimed;

        // Transfer repaid debt back to the lender.
        debt().safeTransfer(loan.lender, claim);
    }

    /// @notice Claim collateral upon loan default.
    /// @param loanID_ index of loan in loans[]
    /// @return defaulted debt by the borrower, collateral kept by the lender, elapsed time since expiry.
    function claimDefaulted(uint256 loanID_) external returns (uint256, uint256, uint256) {
        Loan memory loan = loans[loanID_];
        delete loans[loanID_];

        if (block.timestamp <= loan.expiry) revert NoDefault();

        // Transfer defaulted collateral to the lender.
        collateral().safeTransfer(loan.lender, loan.collateral);

        // Log the event.
        factory().newEvent(loanID_, CoolerFactory.Events.DefaultLoan, 0);

        // If necessary, trigger lender callback.
        if (loan.callback) CoolerCallback(loan.lender).onDefault(loanID_, loan.amount, loan.collateral);
        return (loan.amount, loan.collateral, block.timestamp - loan.expiry);
    }

    /// @notice Approve transfer of loan ownership rights to a new address.
    /// @param  to_ address to be approved.
    /// @param  loanID_ index of loan in loans[].
    function approveTransfer(address to_, uint256 loanID_) external {
        if (msg.sender != loans[loanID_].lender) revert OnlyApproved();

        // Update transfer approvals.
        approvals[loanID_] = to_;
    }

    /// @notice Execute loan ownership transfer. Must be previously approved by the lender.
    /// @param  loanID_ index of loan in loans[].
    function transferOwnership(uint256 loanID_) external {
        if (msg.sender != approvals[loanID_]) revert OnlyApproved();

        // Update the load lender.
        loans[loanID_].lender = msg.sender;
        // Clear transfer approvals.
        approvals[loanID_] = address(0);
    }

    /// @notice Set direct repayment of a given loan.
    /// @param  loanID_ of lender's loan.
    /// @param  direct_ true if a direct repayment is desired. False otherwise.
    function setDirectRepay(uint256 loanID_, bool direct_) external {
        if (msg.sender != loans[loanID_].lender) revert OnlyApproved();

        // Update the repayment method.
        loans[loanID_].repayDirect = direct_;
    }

    // --- AUX FUNCTIONS ---------------------------------------------

    /// @notice Compute collateral needed for loan amount at given loan to collateral ratio.
    /// @param  amount_ of collateral tokens.
    /// @param  loanToCollateral_ ratio for loan.
    function collateralFor(uint256 amount_, uint256 loanToCollateral_) public view returns (uint256) {
        return (amount_ * (10 ** collateral().decimals())) / loanToCollateral_;
    }

    /// @notice compute collateral needed to roll loan.
    /// @param  loanID_ of loan to roll.
    function newCollateralFor(uint256 loanID_) public view returns (uint256) {
        Loan memory loan = loans[loanID_];
        // Accounts for all outstanding debt (borrowed amount + interest).
        uint256 neededCollateral = collateralFor(
            loan.amount,
            loan.request.loanToCollateral
        );

        return
            neededCollateral > loan.collateral ?
            neededCollateral - loan.collateral :
            0;
    }

    /// @notice Compute interest cost on amount for duration at given annualized rate.
    /// @param  amount_ of debt tokens.
    /// @param  rate_ of interest (annualized).
    /// @param  duration_ of loan in seconds.
    /// @return Interest in debt token terms.
    function interestFor(uint256 amount_, uint256 rate_, uint256 duration_) public pure returns (uint256) {
        uint256 interest = (rate_ * duration_) / 365 days;
        return (amount_ * interest) / DECIMALS_INTEREST;
    }

    /// @notice Check if given loan is in default.
    /// @param  loanID_ index of loan in loans[].
    /// @return Defaulted status.
    function isDefaulted(uint256 loanID_) external view returns (bool) {
        return block.timestamp > loans[loanID_].expiry;
    }

    /// @notice Check if a given request is active.
    /// @param  reqID_ index of request in requests[].
    /// @return Active status.
    function isActive(uint256 reqID_) external view returns (bool) {
        return requests[reqID_].active;
    }

    /// @notice Getter for Request data as a struct.
    /// @param  reqID_ index of request in requests[].
    /// @return Request struct.
    function getRequest(uint256 reqID_) external view returns (Request memory) {
        return requests[reqID_];
    }

    /// @notice Getter for Loan data as a struct.
    /// @param loanID_ index of loan in loans[].
    /// @return Loan struct.
    function getLoan(uint256 loanID_) external view returns (Loan memory) {
        return loans[loanID_];
    }
}
