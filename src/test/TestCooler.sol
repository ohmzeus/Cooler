// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../lib/mininterfaces.sol";

/// @notice A Cooler is a smart contract escrow that facilitates fixed-duration loans
///         for a specific debt-collateral pair.
/// @dev    NOTE this is a testing contract and should NOT be used in prod.
contract Cooler {
    // Errors

    error OnlyApproved();
    error Deactivated();
    error Default();
    error NoDefault();

    // Data Structures

    Request[] public requests;
    struct Request { // A loan begins with a borrow request. It specifies:
        uint256 amount; // the amount they want to borrow,
        uint256 interest; // the percentage they will pay as interest,
        uint256 loanToCollateral; // the loan-to-collateral ratio they want,
        uint256 duration; // and the length of time until the loan defaults.
        bool active; // Any lender can clear an active loan request.
    } 

    Loan[] public loans;
    struct Loan { // A request is converted to a loan when a lender clears it.
        Request request; // The terms of the loan are saved, along with:
        uint256 amount; // the amount of debt owed,
        uint256 collateral; // the amount of collateral pledged,
        uint256 expiry; // the time when the loan defaults,
        address lender; // and the lender's address.
    }

    // Immutables

    // This address owns the collateral in escrow.
    address private immutable owner;
    // This token is borrowed against.
    ERC20 public immutable collateral;
    // This token is lent.
    ERC20 public immutable debt;

    // This makes the code look prettier.
    uint256 private constant decimals = 1e18;

    // Initialization

    constructor (address o, ERC20 c, ERC20 d) {
        owner = o;
        collateral = c;
        debt = d;
    }

    // Borrower

    /// @notice request a loan with given parameters
    /// @notice collateral is taken at time of request
    /// @param amount of debt tokens to borrow
    /// @param interest to pay (% of 'amount')
    /// @param loanToCollateral debt tokens per collateral token pledged
    /// @param duration of loan tenure in seconds
    /// @return reqID requests index
    function request (
        uint256 amount,
        uint256 interest,
        uint256 loanToCollateral,
        uint256 duration
    ) external returns (uint256 reqID) {
        reqID = requests.length;
        requests.push(
            Request(amount, interest, loanToCollateral, duration, true)
        );
        collateral.transferFrom(msg.sender, address(this), collateralFor(amount, loanToCollateral));
    }

    /// @notice cancel a loan request and return collateral
    function rescind (uint256 reqID) external {
        if (msg.sender != owner) 
            revert OnlyApproved();

        Request storage req = requests[reqID];
        req.active = false;
        collateral.transfer(owner, collateralFor(req.amount, req.loanToCollateral));
    }

    /// @notice repay a loan to recoup collateral
    /// @param loanID index of loan to repay
    /// @param repaid debt tokens to repay
    function repay (uint256 loanID, uint256 repaid, uint256 time) external {
        Loan storage loan = loans[loanID];

        if (time > loan.expiry) 
            revert Default();
        
        uint256 decollateralized = loan.collateral * repaid / loan.amount;

        if (repaid == loan.amount) delete loans[loanID];
        else {
            loan.amount -= repaid;
            loan.collateral -= decollateralized;
        }

        debt.transferFrom(msg.sender, loan.lender, repaid);
        collateral.transfer(owner, decollateralized);
    }

    /// @notice roll a loan over
    /// @notice uses terms from request
    function roll (uint256 loanID, uint256 time) external {
        Loan storage loan = loans[loanID];
        Request memory req = loan.request;

        if (time > loan.expiry) 
            revert Default();

        uint256 newCollateral = collateralFor(loan.amount, req.loanToCollateral) - loan.collateral;
        uint256 newDebt = interestFor(loan.amount, req.interest);

        loan.amount += newDebt;
        loan.expiry += req.duration;
        loan.collateral += newCollateral;
        
        collateral.transferFrom(msg.sender, address(this), newCollateral);
    }

    /// @notice delegate voting power on collateral
    function delegate (address to) external {
        if (msg.sender != owner) 
            revert OnlyApproved();
        IDelegateERC20(address(collateral)).delegate(to);
    }

    // Lender

    /// @notice fill a requested loan as a lender
    function clear (uint256 reqID) external returns (uint256 loanID) {
        Request storage req = requests[reqID];

        if (!req.active) 
            revert Deactivated();
        else req.active = false;

        uint256 interest = interestFor(req.amount, req.interest);
        uint256 collat = collateralFor(req.amount, req.loanToCollateral);
        uint256 expiration = block.timestamp + req.duration;

        loanID = loans.length;
        loans.push(
            Loan(req, req.amount + interest, collat, expiration, msg.sender)
        );
        debt.transferFrom(msg.sender, owner, req.amount);
    }

    /// @notice send collateral to lender upon default
    /// @param loanID of defaulted loan
    /// @return uint256 collateral amount
    function defaulted (uint256 loanID, uint256 time) external returns (uint256) {
        Loan memory loan = loans[loanID];
        delete loans[loanID];

        if (time <= loan.expiry) 
            revert NoDefault();

        collateral.transfer(loan.lender, loan.collateral);
        return loan.collateral;
    }

    // Views

    /// @notice compute collateral needed for loan amount at given loan to collateral ratio
    function collateralFor(uint256 amount, uint256 loanToCollateral) public pure returns (uint256) {
        return amount * decimals / loanToCollateral;
    }

    /// @notice compute interest cost on amount at given rate
    function interestFor(uint256 amount, uint256 rate) public pure returns (uint256) {
        return amount * rate / decimals;
    }

    /// @notice check if given loan is in default
    function isDefaulted(uint256 loanID) external view returns (bool) {
        return block.timestamp > loans[loanID].expiry;
    }

    /// @notice check if given request is active
    function isActive(uint256 reqID) external view returns (bool) {
        return requests[reqID].active;
    }
}