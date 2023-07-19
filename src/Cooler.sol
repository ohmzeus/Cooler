// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {Clone} from "clones/Clone.sol";

import {CoolerFactory} from "./CoolerFactory.sol";
import {IDelegate} from "./IDelegate.sol";

interface IClearinghouse {
    function repay(uint256 loanID, uint256 amount) external;
}

/// @notice A Cooler is a smart contract escrow that facilitates fixed-duration loans
///         for a specific user and debt-collateral pair.
///
/// @dev This contract uses Clones (https://github.com/wighawag/clones-with-immutable-args)
///      to save gas on deployment
contract Cooler is Clone {
    using SafeTransferLib for ERC20;

    // -- ERRORS -----------------------------------------------------

    error OnlyApproved();
    error Deactivated();
    error Default();
    error NoDefault();
    error NotRollable();
    error ZeroCollateralReturned();

    // -- DATA STRUCTURES --------------------------------------------

    Request[] public requests;
    struct Request {
        // A loan begins with a borrow request. It specifies:
        uint256 amount; // the amount they want to borrow,
        uint256 interest; // the annualized percentage they will pay as interest,
        uint256 loanToCollateral; // the loan-to-collateral ratio they want,
        uint256 duration; // and the length of time until the loan defaults.
        bool active; // Any lender can clear an active loan request.
    }

    Loan[] public loans;
    struct Loan {
        // A request is converted to a loan when a lender clears it.
        Request request; // The terms of the loan are saved, along with:
        uint256 amount; // the amount of debt owed,
        uint256 repaid; // the amount of debt tokens repaid but unclaimed,
        uint256 collateral; // the amount of collateral pledged,
        uint256 expiry; // the time when the loan defaults,
        address lender; // and the lender's address.
        bool repayDirect; // If this is false, repaid tokens must be claimed by lender.
        bool repayCallback; // If this is true, call repay() function on lender address.
    }

    // -- STATE VARIABLES --------------------------------------------

    // This makes the code look prettier.
    uint256 private constant DECIMALS = 1e18;

    // Facilitates transfer of lender ownership to new address
    mapping(uint256 => address) public approvals;

    // -- IMMUTABLE PARAMETERS ---------------------------------------

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

    // -- BORROWER ---------------------------------------------------

    /// @notice request a loan with given parameters
    /// @notice collateral is taken at time of request
    /// @param amount of debt tokens to borrow
    /// @param interest to pay (annualized % of 'amount')
    /// @param loanToCollateral debt tokens per collateral token pledged
    /// @param duration of loan tenure in seconds
    /// @param reqID index of request in requests[]
    function request(
        uint256 amount,
        uint256 interest,
        uint256 loanToCollateral,
        uint256 duration
    ) external returns (uint256 reqID) {
        reqID = requests.length;
        factory().newEvent(reqID, CoolerFactory.Events.Request, 0);
        requests.push(
            Request(amount, interest, loanToCollateral, duration, true)
        );
        collateral().safeTransferFrom(
            msg.sender,
            address(this),
            collateralFor(amount, loanToCollateral)
        );
    }

    /// @notice cancel a loan request and return collateral
    /// @param reqID index of request in requests[]
    function rescind(uint256 reqID) external {
        if (msg.sender != owner()) revert OnlyApproved();

        factory().newEvent(reqID, CoolerFactory.Events.Rescind, 0);

        Request storage req = requests[reqID];

        if (!req.active) revert Deactivated();

        req.active = false;
        collateral().safeTransfer(
            owner(),
            collateralFor(req.amount, req.loanToCollateral)
        );
    }

    /// @notice repay a loan to recoup collateral
    /// @param loanID index of loan in loans[]
    /// @param repaid debt tokens to repay
    function repay(uint256 loanID, uint256 repaid) external {
        Loan storage loan = loans[loanID];

        if (block.timestamp > loan.expiry) revert Default();

        if (repaid > loan.amount) repaid = loan.amount;

        uint256 decollateralized = (loan.collateral * repaid) / loan.amount;
        if (decollateralized == 0) revert ZeroCollateralReturned();

        factory().newEvent(loanID, CoolerFactory.Events.Repay, repaid);

        loan.amount -= repaid;
        loan.collateral -= decollateralized;

        address repayTo = loan.repayDirect ? loan.lender : address(this);
        if (!loan.repayDirect) loan.repaid += repaid;

        debt().safeTransferFrom(msg.sender, repayTo, repaid);
        collateral().safeTransfer(owner(), decollateralized);

        if (loan.repayCallback) IClearinghouse(loan.lender).repay(loanID, repaid);
    }

    /// @notice claim debt tokens for lender if repayDirect was false
    /// @param loanID index of loan in loans[]
    function claimRepaid(uint256 loanID) external {
        Loan storage loan = loans[loanID];
        uint256 claim = loan.repaid;
        loan.repaid = 0;
        debt().safeTransfer(loan.lender, claim);
    }

    /// @notice roll a loan over
    /// @notice uses terms from request
    /// @param loanID index of loan in loans[]
    function roll(uint256 loanID) external {
        Loan storage loan = loans[loanID];

        if (block.timestamp > loan.expiry) revert Default();

        if (!loan.request.active) revert NotRollable();

        uint256 newCollateral = newCollateralFor(loanID);
        uint256 newDebt = interestFor(
            loan.amount,
            loan.request.interest,
            loan.request.duration
        );

        loan.amount += newDebt;
        loan.collateral += newCollateral;
        loan.expiry += loan.request.duration;

        if (newCollateral > 0)
            collateral().safeTransferFrom(
                msg.sender,
                address(this),
                newCollateral
            );
    }

    /// @notice delegate voting power on collateral
    /// @param to address to delegate
    function delegate(address to) external {
        if (msg.sender != owner()) revert OnlyApproved();
        IDelegate(address(collateral())).delegate(to);
    }

    // -- LENDER -----------------------------------------------------

    /// @notice fill a requested loan as a lender
    /// @param reqID index of request in requests[]
    /// @param repayDirect lender should input false if concerned about debt token blacklisting
    /// @param repayCallback lender can insert callback at end for accounting
    /// @return loanID index of loan in loans[]
    function clear(
        uint256 reqID,
        bool repayDirect,
        bool repayCallback
    ) external returns (uint256 loanID) {
        Request storage req = requests[reqID];

        factory().newEvent(reqID, CoolerFactory.Events.Clear, 0);

        if (!req.active) revert Deactivated();
        else req.active = false;

        uint256 interest = interestFor(req.amount, req.interest, req.duration);
        uint256 collat = collateralFor(req.amount, req.loanToCollateral);
        uint256 expiration = block.timestamp + req.duration;

        loanID = loans.length;
        loans.push(
            Loan(
                req,
                req.amount + interest,
                0,
                collat,
                expiration,
                msg.sender,
                repayDirect,
                repayCallback
            )
        );
        debt().safeTransferFrom(msg.sender, owner(), req.amount);

        // Validate callback
        if (repayCallback) IClearinghouse(msg.sender).repay(loanID, 0);
    }

    /// @notice provide terms for loan to roll over
    /// @param loanID index of loan in loans[]
    /// @param interest to pay (annualized % of 'amount')
    /// @param loanToCollateral debt tokens per collateral token pledged
    /// @param duration of loan tenure in seconds
    function provideNewTermsForRoll(
        uint256 loanID,
        uint256 interest,
        uint256 loanToCollateral,
        uint256 duration
    ) external {
        Loan storage loan = loans[loanID];

        if (msg.sender != loan.lender) revert OnlyApproved();

        loan.request = Request(
            loan.amount,
            interest,
            loanToCollateral,
            duration,
            true
        );
    }

    /// @notice send collateral to lender upon default
    /// @param loanID index of loan in loans[]
    /// @return uint256 collateral amount
    function defaulted(uint256 loanID) external returns (uint256) {
        Loan memory loan = loans[loanID];
        delete loans[loanID];

        if (block.timestamp <= loan.expiry) revert NoDefault();

        collateral().safeTransfer(loan.lender, loan.collateral);
        return loan.collateral;
    }

    /// @notice approve transfer of loan ownership to new address
    /// @param to address to approve
    /// @param loanID index of loan in loans[]
    function approve(address to, uint256 loanID) external {
        Loan memory loan = loans[loanID];

        if (msg.sender != loan.lender) revert OnlyApproved();

        approvals[loanID] = to;
    }

    /// @notice execute approved transfer of loan ownership
    /// @param loanID index of loan in loans[]
    function transfer(uint256 loanID) external {
        if (msg.sender != approvals[loanID]) revert OnlyApproved();

        approvals[loanID] = address(0);
        loans[loanID].lender = msg.sender;
    }

    /// @notice turn direct repayment off or on
    /// @param loanID of lender's loan
    function toggleDirect(uint256 loanID) external {
        Loan storage loan = loans[loanID];

        if (msg.sender != loan.lender) revert OnlyApproved();

        loan.repayDirect = !loan.repayDirect;
    }

    // -- AUX FUNCTIONS ----------------------------------------------

    /// @notice compute collateral needed for loan amount at given loan to collateral ratio
    /// @param amount of collateral tokens
    /// @param loanToCollateral ratio for loan
    function collateralFor(
        uint256 amount,
        uint256 loanToCollateral
    ) public pure returns (uint256) {
        return (amount * DECIMALS) / loanToCollateral;
    }

    /// @notice compute collateral needed to roll loan
    /// @param loanID of loan to roll
    function newCollateralFor(uint256 loanID) public view returns (uint256) {
        Loan memory loan = loans[loanID];
        uint256 neededCollateral = collateralFor(loan.amount, loan.request.loanToCollateral);
        return
            neededCollateral > loan.collateral ?
            neededCollateral - loan.collateral :
            0;
    }

    /// @notice compute interest cost on amount for duration at given annualized rate
    /// @param amount of debt tokens
    /// @param rate of interest (annualized)
    /// @param duration of loan in seconds
    /// @return interest as a number of debt tokens
    function interestFor(
        uint256 amount,
        uint256 rate,
        uint256 duration
    ) public pure returns (uint256) {
        uint256 interest = (rate * duration) / 365 days;
        return (amount * interest) / DECIMALS;
    }

    /// @notice check if given loan is in default
    /// @param loanID index of loan in loans[]
    /// @return defaulted status
    function isDefaulted(uint256 loanID) external view returns (bool) {
        return block.timestamp > loans[loanID].expiry;
    }

    /// @notice check if given request is active
    /// @param reqID index of request in requests[]
    /// @return active status
    function isActive(uint256 reqID) external view returns (bool) {
        return requests[reqID].active;
    }
}
