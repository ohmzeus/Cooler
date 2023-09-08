// // SPDX-License-Identifier: Unlicense
// pragma solidity ^0.8.15;

// import {Test} from "forge-std/Test.sol";
// import {console2} from "forge-std/console2.sol";
// import {UserFactory} from "test/lib/UserFactory.sol";

// import {MockGohm} from "test/mocks/MockGohm.sol";
// import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
// import {MockMaliciousLender} from "test/mocks/MockMaliciousLender.sol";

// import {Cooler} from "src/Cooler.sol";
// import {CoolerFactory} from "src/CoolerFactory.sol";

// // Tests for Cooler
// //
// // [X] constructor
// //     [X] immutable variables are properly stored
// // [X] requestLoan
// //     [X] new request is stored 
// //     [X] user and cooler new collateral balances are correct
// // [X] rescindRequest
// //     [X] only owner can rescind
// //     [X] only active requests can be rescinded
// //     [X] request is updated 
// //     [X] user and cooler new collateral balances are correct
// // [X] clearRequest
// //     [X] only active requests can be cleared
// //     [X] request cleared and a new loan is created
// //     [X] user and lender new debt balances are correct
// // [X] repayLoan
// //     [X] only possible before expiry
// //     [X] loan is updated
// //     [X] direct (true): new collateral and debt balances are correct
// //     [X] direct (false): new collateral and debt balances are correct
// //     [X] callback (true): cannot perform a reentrancy attack
// // [X] claimRepaid
// //     [X] loan is updated
// //     [X] lender and cooler new debt balances are correct
// // [X] setDirectRepay
// //     [X] only the lender can toggle
// //     [X] loan is properly updated
// // [X] rollLoan
// //     [X] only possible before expiry
// //     [X] only possible for active loans
// //     [X] loan is updated
// //     [X] request is deactivated
// //     [X] user and cooler new collateral balances are correct
// //     [X] callback (true): cannot perform a reentrancy attack
// // [X] provideNewTermsForRoll
// //     [X] only lender can set new terms
// //     [X] request is properly updated
// // [X] claimDefaulted
// //     [X] only possible after expiry
// //     [X] lender and cooler new collateral balances are correct
// //     [X] callback (true): cannot perform a reentrancy attack
// // [X] delegateVoting
// //     [X] only owner can delegate
// //     [X] collateral voting power is properly delegated
// // [X] approveTransfer
// //     [X] only the lender can approve a transfer
// //     [X] approval stored
// // [X] transferOwnership
// //     [X] only the approved addresses can transfer
// //     [X] loan is properly updated

// contract CoolerTest is Test {

//     MockGohm internal collateral;
//     MockERC20 internal debt;
    
//     address owner;
//     address lender;
//     address others;

//     CoolerFactory internal coolerFactory;
//     Cooler internal cooler;
    
//     // CoolerFactory Expected events
//     event Clear(address cooler, uint256 reqID);
//     event Repay(address cooler, uint256 loanID, uint256 amount);
//     event Rescind(address cooler, uint256 reqID);
//     event Request(address cooler, address collateral, address debt, uint256 reqID);


//     // Parameter Bounds
//     uint256 public constant INTEREST_RATE = 5e15; // 0.5%
//     uint256 public constant LOAN_TO_COLLATERAL = 10 * 1e18; // 10 debt : 1 collateral
//     uint256 public constant DURATION = 30 days; // 1 month
//     uint256 public constant DECIMALS = 1e18;
//     uint256 public constant MAX_DEBT = 5000 * 1e18;
//     uint256 public constant MAX_COLLAT = 1000 * 1e18;

//     function setUp() public {
//         vm.warp(51 * 365 * 24 * 60 * 60); // Set timestamp at roughly Jan 1, 2021 (51 years since Unix epoch)

//         // Deploy mocks 
//         collateral = new MockGohm("Collateral", "COLLAT", 18);
//         debt = new MockERC20("Debt", "DEBT", 18);

//         // Create accounts
//         UserFactory userFactory = new UserFactory();
//         address[] memory users = userFactory.create(3);
//         owner = users[0];
//         lender = users[1];
//         others = users[2];
//         deal(address(debt), lender, MAX_DEBT);
//         deal(address(debt), others, MAX_DEBT);
//         deal(address(collateral), owner, MAX_COLLAT);
//         deal(address(collateral), others, MAX_COLLAT);

//         // Deploy system contracts
//         coolerFactory = new CoolerFactory();
//     }

//     // -- Helper Functions ---------------------------------------------------

//     function _initCooler() internal returns(Cooler) {
//         vm.prank(owner);
//         return Cooler(coolerFactory.generateCooler(collateral, debt));
//     }

//     function _requestLoan(uint256 amount_) internal returns(uint256, uint256) {
//         uint256 reqCollateral = _collateralFor(amount_);

//         vm.startPrank(owner);
//         // aprove collateral so that it can be transferred by cooler
//         collateral.approve(address(cooler), amount_);
//         uint256 reqID = cooler.requestLoan(
//             amount_,
//             INTEREST_RATE,
//             LOAN_TO_COLLATERAL,
//             DURATION
//         );
//         vm.stopPrank();
//         return (reqID, reqCollateral);
//     }

//     function _clearLoan(
//         uint256 reqID_,
//         uint256 reqAmount_,
//         bool directRepay_,
//         bool callbackRepay_
//     ) internal returns(uint256) {
//         vm.startPrank(lender);
//         // aprove debt so that it can be transferred from the cooler
//         debt.approve(address(cooler), reqAmount_);
//         // if repayTo == false, don't send repayment to the lender
//         address repayTo = (directRepay_) ? lender : others;
//         uint256 loanID = cooler.clearRequest(reqID_, repayTo, callbackRepay_);        
//         vm.stopPrank();
//         return loanID;
//     }

//     function _collateralFor(uint256 amount_) public pure returns (uint256) {
//         return amount_ * DECIMALS / LOAN_TO_COLLATERAL;
//     }

//     function _interestFor(
//         uint256 amount_,
//         uint256 rate_,
//         uint256 duration_
//     ) public pure returns (uint256) {
//         uint256 interest = (rate_ * duration_) / 365 days;
//         return (amount_ * interest) / DECIMALS;
//     }

//     // -- Cooler: Constructor ---------------------------------------------------

//     function test_constructor() public {
//         vm.prank(owner);
//         cooler = Cooler(coolerFactory.generateCooler(collateral, debt));
//         assertEq(address(collateral), address(cooler.collateral()));
//         assertEq(address(debt), address(cooler.debt()));
//         assertEq(address(coolerFactory), address(cooler.factory()));
//     }

//     // -- REQUEST LOAN ---------------------------------------------------

//     function testFuzz_requestLoan(uint256 amount_) public {
//         // test inputs
//         amount_ = bound(amount_, 0, MAX_DEBT);
//         // test setup
//         cooler = _initCooler();
//         uint256 reqCollateral = amount_ * DECIMALS / LOAN_TO_COLLATERAL;
//         // balances before requesting the loan
//         uint256 initOwnerCollateral = collateral.balanceOf(owner);
//         uint256 initCoolerCollateral = collateral.balanceOf(address(cooler));

//         vm.startPrank(owner);
//         // aprove collateral so that it can be transferred by cooler
//         collateral.approve(address(cooler), amount_);
//         uint256 reqID = cooler.requestLoan(
//             amount_,
//             INTEREST_RATE,
//             LOAN_TO_COLLATERAL,
//             DURATION
//         );
//         vm.stopPrank();

//         (uint256 reqAmount, uint256 reqInterest, uint256 reqRatio, uint256 reqDuration, bool reqActive) = cooler.requests(reqID);
//         // check: request storage
//         assertEq(0, reqID);
//         assertEq(amount_, reqAmount);
//         assertEq(INTEREST_RATE, reqInterest);
//         assertEq(LOAN_TO_COLLATERAL, reqRatio);
//         assertEq(DURATION, reqDuration);
//         assertEq(true, reqActive);
//         // check: collateral balances
//         assertEq(collateral.balanceOf(owner), initOwnerCollateral - reqCollateral);
//         assertEq(collateral.balanceOf(address(cooler)), initCoolerCollateral + reqCollateral);
//     }

//     // -- RESCIND LOAN ---------------------------------------------------

//     function testFuzz_rescindLoan(uint256 amount_) public {
//         // test inputs
//         amount_ = bound(amount_, 0, MAX_DEBT);
//         // test setup
//         cooler = _initCooler();
//         (uint256 reqID, uint256 reqCollateral) = _requestLoan(amount_);
//         // balances after requesting the loan
//         uint256 initOwnerCollateral = collateral.balanceOf(owner);
//         uint256 initCoolerCollateral = collateral.balanceOf(address(cooler));

//         vm.prank(owner);
//         cooler.rescindRequest(reqID);
//         (,,,, bool reqActive) = cooler.requests(reqID);
//         // check: request storage
//         assertEq(false, reqActive);
//         // check: collateral balances
//         assertEq(collateral.balanceOf(owner), initOwnerCollateral + reqCollateral);
//         assertEq(collateral.balanceOf(address(cooler)), initCoolerCollateral - reqCollateral);
//     }

//     function testFuzz_rescindLoan_multipleRequestAndRecindFirstOne(uint256 amount_) public {
//         // test inputs
//         uint256 amount1_ = bound(amount_, 0, MAX_DEBT / 3);
//         uint256 amount2_ = 2 * amount1_;
//         // test setup
//         cooler = _initCooler();

//         // Request ID = 1
//         vm.startPrank(owner);
//         // aprove collateral so that it can be transferred by cooler
//         collateral.approve(address(cooler), amount1_);
//         uint256 reqID1 = cooler.requestLoan(
//             amount1_,
//             INTEREST_RATE,
//             LOAN_TO_COLLATERAL,
//             DURATION
//         );
//         vm.stopPrank();

//         (uint256 reqAmount1, uint256 reqInterest1, uint256 reqRatio1, uint256 reqDuration1, bool reqActive1) = cooler.requests(reqID1);
//         // check: request storage
//         assertEq(0, reqID1);
//         assertEq(amount1_, reqAmount1);
//         assertEq(INTEREST_RATE, reqInterest1);
//         assertEq(LOAN_TO_COLLATERAL, reqRatio1);
//         assertEq(DURATION, reqDuration1);
//         assertEq(true, reqActive1);

//         // Request ID = 2
//         vm.startPrank(others);
//         // aprove collateral so that it can be transferred by cooler
//         collateral.approve(address(cooler), amount2_);
//         uint256 reqID2 = cooler.requestLoan(
//             amount2_,
//             INTEREST_RATE,
//             LOAN_TO_COLLATERAL,
//             DURATION
//         );
//         vm.stopPrank();

//         (uint256 reqAmount2, uint256 reqInterest2, uint256 reqRatio2, uint256 reqDuration2, bool reqActive2) = cooler.requests(reqID2);
//         // check: request storage
//         assertEq(1, reqID2);
//         assertEq(amount2_, reqAmount2);
//         assertEq(INTEREST_RATE, reqInterest2);
//         assertEq(LOAN_TO_COLLATERAL, reqRatio2);
//         assertEq(DURATION, reqDuration2);
//         assertEq(true, reqActive2);

//         // Rescind Request ID = 1
//         vm.prank(owner);
//         cooler.rescindRequest(reqID1);

//         (reqAmount1, reqInterest1, reqRatio1, reqDuration1, reqActive1) = cooler.requests(reqID1);
//         (reqAmount2, reqInterest2, reqRatio2, reqDuration2, reqActive2) = cooler.requests(reqID2);
//         // check: request storage
//         assertEq(0, reqID1);
//         assertEq(amount1_, reqAmount1);
//         assertEq(INTEREST_RATE, reqInterest1);
//         assertEq(LOAN_TO_COLLATERAL, reqRatio1);
//         assertEq(DURATION, reqDuration1);
//         assertEq(false, reqActive1);
//         assertEq(1, reqID2);
//         assertEq(amount2_, reqAmount2);
//         assertEq(INTEREST_RATE, reqInterest2);
//         assertEq(LOAN_TO_COLLATERAL, reqRatio2);
//         assertEq(DURATION, reqDuration2);
//         assertEq(true, reqActive2);
//     }

//     function testRevertFuzz_rescind_onlyOwner(uint256 amount_) public {
//         // test inputs
//         amount_ = bound(amount_, 0, MAX_DEBT);
//         // test setup
//         cooler = _initCooler();
//         (uint256 reqID, ) = _requestLoan(amount_);

//         // only owner can rescind
//         vm.prank(others);
//         vm.expectRevert(Cooler.OnlyApproved.selector);
//         cooler.rescindRequest(reqID);
//     }

//     function testRevertFuzz_rescind_onlyActive(uint256 amount_) public {
//         // test inputs
//         amount_ = bound(amount_, 0, MAX_DEBT);
//         // test setup
//         cooler = _initCooler();
//         (uint256 reqID, ) = _requestLoan(amount_);

//         vm.startPrank(owner);
//         cooler.rescindRequest(reqID);
//         // only possible to rescind active requests
//         vm.expectRevert(Cooler.Deactivated.selector);
//         cooler.rescindRequest(reqID);
//         vm.stopPrank();
//     }

//     // -- CLEAR REQUEST --------------------------------------------------

//     function testFuzz_clearRequest(uint256 amount_) public {
//         // test inputs
//         amount_ = bound(amount_, 0, MAX_DEBT);
//         bool callbackRepay = false;
//         // test setup
//         cooler = _initCooler();
//         (uint256 reqID, ) = _requestLoan(amount_);
//         // balances after requesting the loan
//         uint256 initOwnerDebt = debt.balanceOf(owner);
//         uint256 initLenderDebt = debt.balanceOf(lender);

//         vm.startPrank(lender);
//         // aprove debt so that it can be transferred by cooler
//         debt.approve(address(cooler), amount_);
//         uint256 loanID = cooler.clearRequest(reqID, lender, callbackRepay);
//         vm.stopPrank();

//         { // block scoping to prevent "stack too deep" compiler error
//         (,,,, bool reqActive) = cooler.requests(reqID);
//         // check: request storage
//         assertEq(false, reqActive);
//         }

//         Cooler.Loan memory loan = cooler.getLoan(loanID);
//         // check: loan storage
//         assertEq(amount_ + _interestFor(amount_, INTEREST_RATE, DURATION), loan.principle);
//         assertEq(_collateralFor(amount_), loan.collateral);
//         assertEq(block.timestamp + DURATION, loan.expiry);
//         assertEq(lender, loan.lender);
//         assertEq(lender, loan.recipient);
//         assertEq(false, loan.callback);

//         // check: debt balances
//         assertEq(debt.balanceOf(owner), initOwnerDebt + amount_);
//         assertEq(debt.balanceOf(lender), initLenderDebt - amount_);
//     }

//     function testRevertFuzz_clear_onlyActive(uint256 amount_) public {
//         // test inputs
//         amount_ = bound(amount_, 0, MAX_DEBT);
//         bool callbackRepay = false;
//         // test setup
//         cooler = _initCooler();
//         (uint256 reqID, ) = _requestLoan(amount_);

//         vm.prank(owner);
//         cooler.rescindRequest(reqID);

//         vm.startPrank(lender);
//         // aprove debt so that it can be transferred by cooler
//         debt.approve(address(cooler), amount_);
//         // only possible to rescind active requests
//         vm.expectRevert(Cooler.Deactivated.selector);
//         cooler.clearRequest(reqID, lender, callbackRepay);
//         vm.stopPrank();
//     }

//     // -- REPAY LOAN ---------------------------------------------------

//     function testFuzz_repayLoan_directTrue_callbackFalse(uint256 amount_, uint256 repayAmount_) public {
//         // test inputs
//         repayAmount_ = bound(repayAmount_, 1e10, MAX_DEBT);  // min > 0 to have some decollateralization
//         amount_ = bound(amount_, repayAmount_, MAX_DEBT);
//         bool directRepay = true;
//         bool callbackRepay = false;
//         // cache init vaules
//         uint256 initLoanCollat = _collateralFor(amount_);
//         uint256 initLoanAmount = amount_ + _interestFor(amount_, INTEREST_RATE, DURATION);
//         uint256 decollatAmount = initLoanCollat * repayAmount_ / initLoanAmount;
//         // test setup
//         cooler = _initCooler();
//         (uint256 reqID, ) = _requestLoan(amount_);
//         uint256 loanID = _clearLoan(reqID, amount_, directRepay, callbackRepay);

//         { // block scoping to prevent "stack too deep" compiler error
//         // balances after clearing the loan
//         uint256 initOwnerDebt = debt.balanceOf(owner);
//         uint256 initLenderDebt = debt.balanceOf(lender);
//         uint256 initOwnerCollat = collateral.balanceOf(owner);
//         uint256 initCoolerCollat = collateral.balanceOf(address(cooler));

//         vm.startPrank(owner);
//         // aprove debt so that it can be transferred by cooler
//         debt.approve(address(cooler), amount_);
//         cooler.repayLoan(loanID, repayAmount_);
//         vm.stopPrank();

//         // check: debt and collateral balances
//         assertEq(debt.balanceOf(owner), initOwnerDebt - repayAmount_, "owner: debt balance");
//         assertEq(debt.balanceOf(lender), initLenderDebt + repayAmount_, "cooler: debt balance");
//         assertEq(collateral.balanceOf(owner), initOwnerCollat + decollatAmount, "owner: collat balance");
//         assertEq(collateral.balanceOf(address(cooler)), initCoolerCollat - decollatAmount, "cooler: collat balance");
//         }

//         Cooler.Loan memory loan = cooler.getLoan(loanID);
//         // check: loan storage
//         assertEq(initLoanAmount - repayAmount_, loan.principle, "outstanding debt");
//         assertEq(initLoanCollat - decollatAmount, loan.collateral, "outstanding collat");
//     }
    
//     function testFuzz_repayLoan_directFalse_callbackFalse(uint256 amount_, uint256 repayAmount_) public {
//         // test inputs
//         repayAmount_ = bound(repayAmount_, 1e10, MAX_DEBT);  // min > 0 to have some decollateralization
//         amount_ = bound(amount_, repayAmount_, MAX_DEBT);
//         bool directRepay = false;
//         bool callbackRepay = false;
//         // cache init vaules
//         uint256 initLoanCollat = _collateralFor(amount_);
//         uint256 initLoanAmount = amount_ + _interestFor(amount_, INTEREST_RATE, DURATION);
//         uint256 decollatAmount = initLoanCollat * repayAmount_ / initLoanAmount;
//         // test setup
//         cooler = _initCooler();
//         (uint256 reqID, ) = _requestLoan(amount_);
//         uint256 loanID = _clearLoan(reqID, amount_, directRepay, callbackRepay);

//         { // block scoping to prevent "stack too deep" compiler error
//         // balances after clearing the loan
//         uint256 initOwnerDebt = debt.balanceOf(owner);
//         uint256 initCoolerDebt = debt.balanceOf(address(cooler));
//         uint256 initOwnerCollat = collateral.balanceOf(owner);
//         uint256 initCoolerCollat = collateral.balanceOf(address(cooler));

//         vm.startPrank(owner);
//         // aprove debt so that it can be transferred by cooler
//         debt.approve(address(cooler), amount_);
//         cooler.repayLoan(loanID, repayAmount_);
//         vm.stopPrank();

//         // check: debt and collateral balances
//         assertEq(debt.balanceOf(owner), initOwnerDebt - repayAmount_, "owner: debt balance");
//         assertEq(debt.balanceOf(address(cooler)), initCoolerDebt + repayAmount_, "cooler: debt balance");
//         assertEq(collateral.balanceOf(owner), initOwnerCollat + decollatAmount, "owner: collat balance");
//         assertEq(collateral.balanceOf(address(cooler)), initCoolerCollat - decollatAmount, "cooler: collat balance");
//         }

//         Cooler.Loan memory loan = cooler.getLoan(loanID);
//         // check: loan storage
//         assertEq(initLoanAmount - repayAmount_, loan.principle, "outstanding debt");
//         assertEq(initLoanCollat - decollatAmount, loan.collateral, "outstanding collat");
//     }

//     function testRevertFuzz_repay_ReentrancyAttack(uint256 amount_, uint256 repayAmount_) public {
//         // test inputs
//         repayAmount_ = bound(repayAmount_, 1e10, MAX_DEBT);  // min > 0 to have some decollateralization
//         amount_ = bound(amount_, repayAmount_, MAX_DEBT);
//         bool callbackRepay = true;
//         // test setup
//         cooler = _initCooler();
//         (uint256 reqID, ) = _requestLoan(amount_);
        
//         // Create a malicious lender that reenters on defaults
//         MockMaliciousLender attacker = new MockMaliciousLender(address(coolerFactory));
//         deal(address(debt), address(attacker), amount_);

//         vm.startPrank(address(attacker));
//         // aprove debt so that it can be transferred from the cooler
//         debt.approve(address(cooler), amount_);
//         uint256 loanID = cooler.clearRequest(reqID, lender, callbackRepay);
//         vm.stopPrank();

//         // block.timestamp < loan expiry
//         vm.warp(block.timestamp + DURATION / 2);

//         vm.startPrank(owner);
//         debt.approve(address(cooler), repayAmount_);
//         // A reentrancy attack on repayLoan wouldn't provide any economical benefit to the
//         // attacker, since it would cause the malicious lender to repay the loan on behalf
//         // of the owner. In this test, the attacker hasn't approved further debt spending
//         // and therefor the transfer will fail.
//         vm.expectRevert("TRANSFER_FROM_FAILED");
//         cooler.repayLoan(loanID, repayAmount_);
//         vm.stopPrank();
//     }
    
//     function testRevertFuzz_repayLoan_defaulted(uint256 amount_, uint256 repayAmount_) public {
//         // test inputs
//         repayAmount_ = bound(repayAmount_, 1e10, MAX_DEBT);  // min > 0 to have some decollateralization
//         amount_ = bound(amount_, repayAmount_, MAX_DEBT);
//         bool directRepay = true;
//         bool callbackRepay = false;
//         // test setup
//         cooler = _initCooler();
//         (uint256 reqID, ) = _requestLoan(amount_);
//         uint256 loanID = _clearLoan(reqID, amount_, directRepay, callbackRepay);

//         // block.timestamp > loan expiry
//         vm.warp(block.timestamp + DURATION + 1);

//         vm.startPrank(owner);
//         // aprove debt so that it can be transferred by cooler
//         debt.approve(address(cooler), amount_);
//         // can't repay a defaulted loan
//         vm.expectRevert(Cooler.Default.selector);
//         cooler.repayLoan(loanID, repayAmount_);
//         vm.stopPrank();
//     }

//     // -- SET DIRECT REPAYMENT -------------------------------------------

//     function testFuzz_setRepaymentAddress(uint256 amount_) public {
//         // test inputs
//         amount_ = bound(amount_, 0, MAX_DEBT);
//         bool directRepay = true;
//         bool callbackRepay = false;
//         // test setup
//         cooler = _initCooler();
//         (uint256 reqID, ) = _requestLoan(amount_);
//         uint256 loanID = _clearLoan(reqID, amount_, directRepay, callbackRepay);

//         vm.startPrank(lender);
//         // turn direct repay off
//         cooler.setRepaymentAddress(loanID, address(0));
//         Cooler.Loan memory loan = cooler.getLoan(loanID);
//         // check: loan storage
//         assertEq(address(0), loan.recipient);
        
//         // turn direct repay on
//         cooler.setRepaymentAddress(loanID, lender);
//         loan = cooler.getLoan(loanID);
//         // check: loan storage
//         assertEq(lender, loan.recipient);
//         vm.stopPrank();
//     }

//     function testRevertFuzz_setRepaymentAddress_onlyLender(uint256 amount_) public {
//         // test inputs
//         amount_ = bound(amount_, 0, MAX_DEBT);
//         bool directRepay = true;
//         bool callbackRepay = false;
//         // test setup
//         cooler = _initCooler();
//         (uint256 reqID, ) = _requestLoan(amount_);
//         uint256 loanID = _clearLoan(reqID, amount_, directRepay, callbackRepay);

//         vm.prank(others);
//         // only lender turn toggle the direct repay
//         vm.expectRevert(Cooler.OnlyApproved.selector);
//         cooler.setRepaymentAddress(loanID, address(0));
//     }

//     // -- CLAIM DEFAULTED ------------------------------------------------

//     function testFuzz_claimDefaulted(uint256 amount_) public {
//         // test inputs
//         amount_ = bound(amount_, 0, MAX_DEBT);
//         bool directRepay = true;
//         bool callbackRepay = false;
//         // test setup
//         cooler = _initCooler();
//         (uint256 reqID, ) = _requestLoan(amount_);
//         uint256 loanID = _clearLoan(reqID, amount_, directRepay, callbackRepay);

//         // block.timestamp > loan expiry
//         vm.warp(block.timestamp + DURATION + 1);

//         vm.prank(lender);
//         cooler.claimDefaulted(loanID);

//         Cooler.Loan memory loan = cooler.getLoan(loanID);
        
//         // check: loan storage
//         assertEq(0, loan.principle);
//         assertEq(0, loan.collateral);
//         assertEq(0, loan.expiry);
//         assertEq(address(0), loan.lender);
//         assertEq(address(0), loan.recipient);
//         assertEq(false, loan.callback);
//     }

//     function test_claimDefaulted_multipleLoansAndFirstOneDefaults(uint256 amount_) public {
//         // test inputs
//         uint256 amount1_ = bound(amount_, 0, MAX_DEBT / 3);
//         uint256 amount2_ = 2 * amount1_;
//         bool callbackRepay = false;
//         bool directRepay = true;
//         // test setup
//         cooler = _initCooler();
//         // Request ID = 1
//         vm.startPrank(owner);
//         collateral.approve(address(cooler), amount1_);
//         uint256 reqID1 = cooler.requestLoan(amount1_, INTEREST_RATE, LOAN_TO_COLLATERAL, DURATION);
//         vm.stopPrank();
//         // Request ID = 2
//         vm.startPrank(others);
//         collateral.approve(address(cooler), amount2_);
//         uint256 reqID2 = cooler.requestLoan(amount2_, INTEREST_RATE / 2, LOAN_TO_COLLATERAL, DURATION * 2);
//         vm.stopPrank();
//         // Clear both requests
//         vm.startPrank(lender);
//         debt.approve(address(cooler), amount1_ + amount2_);
//         uint256 loanID1 = cooler.clearRequest(reqID1, directRepay, callbackRepay);
//         uint256 loanID2 = cooler.clearRequest(reqID2, directRepay, callbackRepay);
//         vm.stopPrank();

//         // block.timestamp > loan expiry
//         vm.warp(block.timestamp + DURATION + 1);

//         // claim defaulted loan ID = 1
//         vm.prank(lender);
//         cooler.claimDefaulted(loanID1);
        
//         Cooler.Loan memory loan1 = cooler.getLoan(loanID1);
//         Cooler.Loan memory loan2 = cooler.getLoan(loanID2);
        
//         // check: loan ID = 1 storage
//         assertEq(0, loan1.principle, "loanAmount1");
//         assertEq(0, loan1.collateral, "loanCollat1");
//         assertEq(0, loan1.expiry, "loanExpiry1");
//         assertEq(address(0), loan1.lender, "loanLender1");
//         assertEq(address(0), loan1.recipient, "loanRecipient1");
//         assertEq(false, loan1.callback, "loanCallback1");
        
//         // check: loan ID = 2 storage
//         assertEq(amount2_ + _interestFor(amount2_, INTEREST_RATE/2, DURATION*2), loan2.principle, "loanAmount2");
//         assertEq(_collateralFor(amount2_), loan2.collateral, "loanCollat2");
//         assertEq(51 * 365 * 24 * 60 * 60 + DURATION * 2, loan2.expiry, "loanExpiry2");
//         assertEq(lender, loan2.lender, "loanLender2");
//         assertEq(lender, loan2.recipient, "loanDirect2");
//         assertEq(false, loan2.callback, "loanCallback2");
//     }

//     function testRevertFuzz_claimDefaulted_ReentrancyAttack(uint256 amount_) public {
//         // test inputs
//         uint256 amount1_ = bound(amount_, 0, MAX_DEBT / 3);
//         uint256 amount2_ = 2 * amount1_;
//         bool callbackRepay = false;
//         bool directRepay = true;
//         // test setup
//         cooler = _initCooler();
//         // Request ID = 1
//         vm.startPrank(owner);
//         collateral.approve(address(cooler), amount1_);
//         uint256 reqID1 = cooler.requestLoan(amount1_, INTEREST_RATE, LOAN_TO_COLLATERAL, DURATION);
//         vm.stopPrank();
//         // Request ID = 2
//         vm.startPrank(others);
//         collateral.approve(address(cooler), amount2_);
//         uint256 reqID2 = cooler.requestLoan(amount2_, INTEREST_RATE, LOAN_TO_COLLATERAL, DURATION);
//         vm.stopPrank();
        
//         // Create a malicious lender that reenters on defaults
//         MockMaliciousLender attacker = new MockMaliciousLender(address(coolerFactory));
//         deal(address(debt), address(attacker), amount1_ + amount2_);

//         vm.startPrank(address(attacker));
//         // aprove debt so that it can be transferred from the cooler
//         debt.approve(address(cooler), amount1_ + amount2_);
//         uint256 loanID1 = cooler.clearRequest(reqID1, directRepay, callbackRepay);
//         uint256 loanID2 = cooler.clearRequest(reqID2, directRepay, callbackRepay);
//         vm.stopPrank();

//         // block.timestamp > loan expiry
//         vm.warp(block.timestamp + DURATION + 1);

//         vm.prank(lender);
//         cooler.claimDefaulted(loanID1);

//         // A reentrancy attack on claimDefaulted() doesn't have any impact thanks to the usage of the
//         // Check-Effects-Interaction pattern. Since the loan storage is emptied at the begining,
//         // a reentrancy attack is useless and ends in a second transfer of 0 collateral tokens to the attacker.
//         assertEq(cooler.collateralFor(amount2_, LOAN_TO_COLLATERAL), collateral.balanceOf(address(cooler)));
//     }

//     function testRevertFuzz_defaulted_notExpired(uint256 amount_) public {
//         // test inputs
//         amount_ = bound(amount_, 0, MAX_DEBT);
//         bool directRepay = true;
//         bool callbackRepay = false;
//         // test setup
//         cooler = _initCooler();
//         (uint256 reqID, ) = _requestLoan(amount_);
//         uint256 loanID = _clearLoan(reqID, amount_, directRepay, callbackRepay);

//         // block.timestamp <= loan expiry
//         vm.warp(block.timestamp + DURATION);

//         vm.prank(lender);
//         // can't default a non-expired loan
//         vm.expectRevert(Cooler.NoDefault.selector);
//         cooler.claimDefaulted(loanID);
//     }

//     // -- DELEGATE VOTING ------------------------------------------------

//     function testFuzz_delegateVoting(uint256 amount_) public {
//         // test inputs
//         amount_ = bound(amount_, 0, MAX_DEBT);
//         // test setup
//         cooler = _initCooler();
//         _requestLoan(amount_);

//         vm.prank(owner);
//         cooler.delegateVoting(others);
//         assertEq(others, collateral.delegatee());
//     }

//     function testRevertFuzz_delegateVoting_onlyOwner(uint256 amount_) public {
//         // test inputs
//         amount_ = bound(amount_, 0, MAX_DEBT);
//         // test setup
//         cooler = _initCooler();
//         _requestLoan(amount_);

//         vm.prank(others);
//         vm.expectRevert(Cooler.OnlyApproved.selector);
//         cooler.delegateVoting(others);
//     }

//     // -- APPROVE TRANSFER ---------------------------------------------------

//     function testFuzz_approve(uint256 amount_) public {
//         // test inputs
//         amount_ = bound(amount_, 0, MAX_DEBT);
//         bool directRepay = true;
//         bool callbackRepay = false;
//         // test setup
//         cooler = _initCooler();
//         (uint256 reqID, ) = _requestLoan(amount_);
//         uint256 loanID = _clearLoan(reqID, amount_, directRepay, callbackRepay);

//         vm.prank(lender);
//         cooler.approveTransfer(others, loanID);

//         assertEq(others, cooler.approvals(loanID));
//     }

//     function testRevertFuzz_approve_onlyLender(uint256 amount_) public {
//         // test inputs
//         amount_ = bound(amount_, 0, MAX_DEBT);
//         bool directRepay = true;
//         bool callbackRepay = false;
//         // test setup
//         cooler = _initCooler();
//         (uint256 reqID, ) = _requestLoan(amount_);
//         uint256 loanID = _clearLoan(reqID, amount_, directRepay, callbackRepay);

//         vm.prank(others);
//         vm.expectRevert(Cooler.OnlyApproved.selector);
//         cooler.approveTransfer(others, loanID);
//     }

//     // -- TRANSFER OWNERSHIP ---------------------------------------------

//     function testFuzz_transfer(uint256 amount_) public {
//         // test inputs
//         amount_ = bound(amount_, 0, MAX_DEBT);
//         bool directRepay = true;
//         bool callbackRepay = false;
//         // test setup
//         cooler = _initCooler();
//         (uint256 reqID, ) = _requestLoan(amount_);
//         uint256 loanID = _clearLoan(reqID, amount_, directRepay, callbackRepay);

//         // the lender approves the transfer
//         vm.prank(lender);
//         cooler.approveTransfer(others, loanID);
//         // the transfer is accepted
//         vm.prank(others);
//         cooler.transferOwnership(loanID);

//         (,,,,, address loanLender,,) = cooler.loans(loanID);
//         // check: loan storage
//         assertEq(others, loanLender);
//         assertEq(address(0), cooler.approvals(loanID));
//     }

//     function testRevertFuzz_transfer_onlyApproved(uint256 amount_) public {
//         // test inputs
//         amount_ = bound(amount_, 0, MAX_DEBT);
//         bool directRepay = true;
//         bool callbackRepay = false;
//         // test setup
//         cooler = _initCooler();
//         (uint256 reqID, ) = _requestLoan(amount_);
//         uint256 loanID = _clearLoan(reqID, amount_, directRepay, callbackRepay);

//         vm.prank(others);
//         vm.expectRevert(Cooler.OnlyApproved.selector);
//         cooler.transferOwnership(loanID);
//     }

//     // -- ROLL LOAN ------------------------------------------------------

//     function testFuzz_rollLoan(uint256 amount_) public {
//         // test inputs
//         amount_ = bound(amount_, 0, MAX_DEBT / 2);
//         bool directRepay = true;
//         bool callbackRepay = false;
//         // test setup
//         cooler = _initCooler();
//         (uint256 reqID, ) = _requestLoan(amount_);
//         uint256 loanID = _clearLoan(reqID, amount_, directRepay, callbackRepay);

//         vm.prank(lender);
//         cooler.provideNewTermsForRoll(
//             loanID,
//             INTEREST_RATE * 2,
//             LOAN_TO_COLLATERAL / 2,
//             DURATION * 2
//         );
        
//         { // block scoping to prevent "stack too deep" compiler error
//         // balances after providing new terms to roll the loan
//         uint256 initOwnerCollat = collateral.balanceOf(owner);
//         uint256 initCoolerCollat = collateral.balanceOf(address(cooler));
//         // aux calculations to get the newCollat amount_ after rolling the loan
//         (, uint256 loanAmount,, uint256 loanCollat,,,,) = cooler.loans(loanID);
//         uint256 rollCollat = loanAmount * DECIMALS / (LOAN_TO_COLLATERAL / 2);
//         uint256 newCollat = rollCollat > loanCollat ? rollCollat - loanCollat : 0;
   
//         vm.startPrank(owner);
//         // aprove collateral so that it can be transferred by cooler
//         collateral.approve(address(cooler), newCollat);
//         cooler.rollLoan(loanID);
//         vm.stopPrank();

//         // check: debt balances
//         assertEq(collateral.balanceOf(owner), initOwnerCollat - newCollat);
//         assertEq(collateral.balanceOf(address(cooler)), initCoolerCollat + newCollat);
//         }
//         Cooler.Loan memory loan = cooler.getLoan(loanID);
//         // check: loan storage
//         assertEq(loan.request.active, false);
//     }

//     function testRevertFuzz_roll_onlyActive(uint256 amount_) public {
//         // test inputs
//         amount_ = bound(amount_, 0, MAX_DEBT);
//         bool directRepay = true;
//         bool callbackRepay = false;
//         // test setup
//         cooler = _initCooler();
//         (uint256 reqID, ) = _requestLoan(amount_);
//         uint256 loanID = _clearLoan(reqID, amount_, directRepay, callbackRepay);
   
//         vm.prank(owner);
//         // not rollable unless lender provides new terms for rolling
//         vm.expectRevert(Cooler.NotRollable.selector);
//         cooler.rollLoan(loanID);
//     }

//     function testRevertFuzz_roll_ReentrancyAttack(uint256 amount_) public {
//         // test inputs
//         amount_ = bound(amount_, 0, MAX_DEBT / 2);
//         bool directRepay = true;
//         bool callbackRepay = true;
//         // test setup
//         cooler = _initCooler();
//         (uint256 reqID, ) = _requestLoan(amount_);
        
//         // Create a malicious lender that reenters on defaults
//         MockMaliciousLender attacker = new MockMaliciousLender(address(coolerFactory));
//         deal(address(debt), address(attacker), amount_);

//         vm.startPrank(address(attacker));
//         // aprove debt so that it can be transferred from the cooler
//         debt.approve(address(cooler), amount_);
//         uint256 loanID = cooler.clearRequest(reqID, directRepay, callbackRepay);
//         vm.stopPrank();

//         // block.timestamp < loan expiry
//         vm.warp(block.timestamp + DURATION / 2);

//         vm.prank(address(attacker));
//         cooler.provideNewTermsForRoll(
//             loanID,
//             INTEREST_RATE * 2,
//             LOAN_TO_COLLATERAL / 2,
//             DURATION * 2
//         );

//         (, uint256 loanAmount,, uint256 loanCollat,,,,) = cooler.loans(loanID);
//         uint256 rollCollat = loanAmount * DECIMALS / (LOAN_TO_COLLATERAL / 2);
//         uint256 newCollat = rollCollat > loanCollat ? rollCollat - loanCollat : 0;

//         vm.startPrank(owner);
//         // aprove collateral so that it can be transferred by cooler
//         collateral.approve(address(cooler), newCollat);
//         // A reentrancy attack on rollLoan() doesn't have any impact thanks to the usage of the
//         // Check-Effects-Interaction pattern. Since the loan request is deactivated at the begining,
//         // a reentrancy attack attemp reverts with a NotRollable() error.
//         vm.expectRevert(Cooler.NotRollable.selector);
//         cooler.rollLoan(loanID);
//         vm.stopPrank();
//     }

//     function testRevertFuzz_roll_defaulted(uint256 amount_) public {
//         // test inputs
//         amount_ = bound(amount_, 0, MAX_DEBT);
//         bool directRepay = true;
//         bool callbackRepay = false;
//         // test setup
//         cooler = _initCooler();
//         (uint256 reqID, ) = _requestLoan(amount_);
//         uint256 loanID = _clearLoan(reqID, amount_, directRepay, callbackRepay);
   
//         vm.prank(lender);
//         cooler.provideNewTermsForRoll(
//             loanID,
//             INTEREST_RATE * 2,
//             LOAN_TO_COLLATERAL / 2,
//             DURATION * 2
//         );
        
//         // block.timestamp > loan expiry
//         vm.warp(block.timestamp + DURATION * 2 + 1);

//         vm.prank(owner);
//         // can't roll an expired loan
//         vm.expectRevert(Cooler.Default.selector);
//         cooler.rollLoan(loanID);
//     }
// }