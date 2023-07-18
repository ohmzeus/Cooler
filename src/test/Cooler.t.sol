// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {UserFactory} from "test/lib/UserFactory.sol";

import {MockERC20, MockGohm} from "test/mocks/OlympusMocks.sol";

import {Cooler} from "src/Cooler.sol";
import {CoolerFactory} from "src/CoolerFactory.sol";

// Tests for Cooler
//
// [X] constructor
//     [X] immutable variables are properly stored
// [X] request
//     [X] new request is stored 
//     [X] user and cooler new collateral balances are correct
// [X] rescind
//     [X] only owner can rescind
//     [X] only active requests can be rescinded
//     [X] request is updated 
//     [X] user and cooler new collateral balances are correct
// [X] clear
//     [X] only active requests can be cleared
//     [X] request cleared and a new loan is created
//     [X] user and lender new debt balances are correct
// [X] repay
//     [X] only possible before expiry
//     [X] loan is updated
//     [X] direct (true): new collateral and debt balances are correct
//     [X] direct (false): new collateral and debt balances are correct
// [X] claimRepaid
//     [X] loan is updated
//     [X] lender and cooler new debt balances are correct
// [X] toggleDirect
//     [X] only the lender can toggle
//     [X] loan is properly updated
// [X] roll
//     [X] only possible before expiry
//     [X] only possible for active loans
//     [X] loan is updated
//     [X] user and cooler new collateral balances are correct
// [X] provideNewTermsForRoll
//     [X] only lender can set new terms
//     [X] request is properly updated
// [X] defaulted
//     [X] only possible after expiry
//     [X] lender and cooler new collateral balances are correct
// [X] delegate
//     [X] only owner can delegate
//     [X] collateral voting power is properly delegated
// [X] approve
//     [X] only the lender can approve a transfer
//     [X] approval stored
// [X] transfer
//     [X] only the approved addresses can transfer
//     [X] loan is properly updated

contract CoolerTest is Test {

    MockGohm internal collateral;
    MockERC20 internal debt;
    
    address owner;
    address lender;
    address others;

    CoolerFactory internal coolerFactory;
    Cooler internal cooler;
    
    // CoolerFactory Expected events
    event Clear(address cooler, uint256 reqID);
    event Repay(address cooler, uint256 loanID, uint256 amount);
    event Rescind(address cooler, uint256 reqID);
    event Request(address cooler, address collateral, address debt, uint256 reqID);


    // Parameter Bounds
    uint256 public constant INTEREST_RATE = 5e15; // 0.5%
    uint256 public constant LOAN_TO_COLLATERAL = 10 * 1e18; // 10 debt : 1 collateral
    uint256 public constant DURATION = 30 days; // 1 month
    uint256 public constant DECIMALS = 1e18;

    function setUp() public {
        vm.warp(51 * 365 * 24 * 60 * 60); // Set timestamp at roughly Jan 1, 2021 (51 years since Unix epoch)

        // Deploy mocks 
        collateral = new MockGohm("Collateral", "COLLAT", 18);
        debt = new MockERC20("Debt", "DEBT", 18);

        // Create accounts
        UserFactory userFactory = new UserFactory();
        address[] memory users = userFactory.create(3);
        owner = users[0];
        lender = users[1];
        others = users[2];
        deal(address(debt), lender, 5000 * 1e18);
        deal(address(collateral), owner, 1000 * 1e18);

        // Deploy system contracts
        coolerFactory = new CoolerFactory();
    }

    // -- Helper Functions ---------------------------------------------------

    function _initCooler() internal returns(Cooler) {
        vm.prank(owner);
        return Cooler(coolerFactory.generate(collateral, debt));
    }

    function _requestLoan(uint256 amount) internal returns(uint256, uint256) {
        uint256 reqCollateral = _collateralFor(amount);

        vm.startPrank(owner);
        // aprove collateral so that it can be transferred by cooler
        collateral.approve(address(cooler), amount);
        uint256 reqID = cooler.request(
            amount,
            INTEREST_RATE,
            LOAN_TO_COLLATERAL,
            DURATION
        );
        vm.stopPrank();
        return (reqID, reqCollateral);
    }

    function _clearLoan(uint256 reqID, uint256 reqAmount, bool directRepay) internal returns(uint256) {
        vm.startPrank(lender);
        // aprove debt so that it can be transferred from the cooler
        debt.approve(address(cooler), reqAmount);
        uint256 loanID = cooler.clear(reqID, directRepay);
        vm.stopPrank();
        return loanID;
    }

    function _collateralFor(uint256 amount) public pure returns (uint256) {
        return amount * DECIMALS / LOAN_TO_COLLATERAL;
    }

    function _interestFor(
        uint256 amount,
        uint256 rate,
        uint256 duration 
    ) public pure returns (uint256) {
        uint256 interest = (rate * duration) / 365 days;
        return (amount * interest) / DECIMALS;
    }

    // -- Cooler: Constructor ---------------------------------------------------

    function test_constructor() public {
        vm.prank(owner);
        cooler = Cooler(coolerFactory.generate(collateral, debt));
        assertEq(address(collateral), address(cooler.collateral()));
        assertEq(address(debt), address(cooler.debt()));
        assertEq(address(coolerFactory), address(cooler.factory()));
    }

    // -- Cooler: Request ---------------------------------------------------

    function test_request() public {
        // test inputs
        uint256 amount = 1234 * 1e18;
        // test setup
        cooler = _initCooler();
        uint256 reqCollateral = amount * DECIMALS / LOAN_TO_COLLATERAL;
        // balances before requesting the loan
        uint256 initOwnerCollateral = collateral.balanceOf(owner);
        uint256 initCoolerCollateral = collateral.balanceOf(address(cooler));

        vm.startPrank(owner);
        // aprove collateral so that it can be transferred by cooler
        collateral.approve(address(cooler), amount);
        uint256 reqID = cooler.request(
            amount,
            INTEREST_RATE,
            LOAN_TO_COLLATERAL,
            DURATION
        );
        vm.stopPrank();

        (uint256 reqAmount, uint256 reqInterest, uint256 reqRatio, uint256 reqDuration, bool reqActive) = cooler.requests(reqID);
        // check: request storage
        assertEq(0, reqID);
        assertEq(amount, reqAmount);
        assertEq(INTEREST_RATE, reqInterest);
        assertEq(LOAN_TO_COLLATERAL, reqRatio);
        assertEq(DURATION, reqDuration);
        assertEq(true, reqActive);
        // check: collateral balances
        assertEq(collateral.balanceOf(owner), initOwnerCollateral - reqCollateral);
        assertEq(collateral.balanceOf(address(cooler)), initCoolerCollateral + reqCollateral);
    }

    // -- Cooler: Rescind ---------------------------------------------------

    function test_rescind() public {
        // test inputs
        uint256 amount = 1234 * 1e18;
        // test setup
        cooler = _initCooler();
        (uint256 reqID, uint256 reqCollateral) = _requestLoan(amount);
        // balances after requesting the loan
        uint256 initOwnerCollateral = collateral.balanceOf(owner);
        uint256 initCoolerCollateral = collateral.balanceOf(address(cooler));

        vm.prank(owner);
        cooler.rescind(reqID);
        (,,,, bool reqActive) = cooler.requests(reqID);
        // check: request storage
        assertEq(false, reqActive);
        // check: collateral balances
        assertEq(collateral.balanceOf(owner), initOwnerCollateral + reqCollateral);
        assertEq(collateral.balanceOf(address(cooler)), initCoolerCollateral - reqCollateral);
    }

    function testRevert_rescind_onlyOwner() public {
        // test inputs
        uint256 amount = 1234 * 1e18;
        // test setup
        cooler = _initCooler();
        (uint256 reqID, ) = _requestLoan(amount);

        // only owner can rescind
        vm.prank(others);
        vm.expectRevert(Cooler.OnlyApproved.selector);
        cooler.rescind(reqID);
    }

    function testRevert_rescind_onlyActive() public {
        // test inputs
        uint256 amount = 1234 * 1e18;
        // test setup
        cooler = _initCooler();
        (uint256 reqID, ) = _requestLoan(amount);

        vm.startPrank(owner);
        cooler.rescind(reqID);
        // only possible to rescind active requests
        vm.expectRevert(Cooler.Deactivated.selector);
        cooler.rescind(reqID);
        vm.stopPrank();
    }

    // -- Cooler: Clear ---------------------------------------------------

    function test_clear() public {
        // test inputs
        uint256 amount = 1234 * 1e18;
        bool directRepay = true;
        // test setup
        cooler = _initCooler();
        (uint256 reqID, ) = _requestLoan(amount);
        // balances after requesting the loan
        uint256 initOwnerDebt = debt.balanceOf(owner);
        uint256 initLenderDebt = debt.balanceOf(lender);

        vm.startPrank(lender);
        // aprove debt so that it can be transferred by cooler
        debt.approve(address(cooler), amount);
        uint256 loanID = cooler.clear(reqID, directRepay);
        vm.stopPrank();

        { // block scoping to prevent "stack too deep" compiler error
        (,,,, bool reqActive) = cooler.requests(reqID);
        // check: request storage
        assertEq(false, reqActive);
        }
        { // block scoping to prevent "stack too deep" compiler error
        (, uint256 loanAmount, uint256 loanRepaid, uint256 loanCollat, uint256 loanExpiry, address loanLender, bool loanDirect) = cooler.loans(loanID);
        // check: loan storage
        assertEq(amount + _interestFor(amount, INTEREST_RATE, DURATION), loanAmount);
        assertEq(0, loanRepaid);
        assertEq(_collateralFor(amount), loanCollat);
        assertEq(block.timestamp + DURATION, loanExpiry);
        assertEq(lender, loanLender);
        assertEq(true, loanDirect);
        }
        // check: debt balances
        assertEq(debt.balanceOf(owner), initOwnerDebt + amount);
        assertEq(debt.balanceOf(lender), initLenderDebt - amount);
    }

    function testRevert_clear_onlyActive() public {
        // test inputs
        uint256 amount = 1234 * 1e18;
        bool directRepay = true;
        // test setup
        cooler = _initCooler();
        (uint256 reqID, ) = _requestLoan(amount);

        vm.prank(owner);
        cooler.rescind(reqID);

        vm.startPrank(lender);
        // aprove debt so that it can be transferred by cooler
        debt.approve(address(cooler), amount);
        // only possible to rescind active requests
        vm.expectRevert(Cooler.Deactivated.selector);
        cooler.clear(reqID, directRepay);
        vm.stopPrank();
    }

    // -- Cooler: Repay ---------------------------------------------------

    function test_repay_direct_true() public {
        // test inputs
        bool directRepay = true;
        uint256 amount = 1234 * 1e18;
        uint256 repayAmount = 567 * 1e18;
        uint256 initLoanCollat = _collateralFor(amount);
        uint256 initLoanAmount = amount + _interestFor(amount, INTEREST_RATE, DURATION);
        uint256 decollatAmount = initLoanCollat * repayAmount / initLoanAmount;
        // test setup
        cooler = _initCooler();
        (uint256 reqID, ) = _requestLoan(amount);
        uint256 loanID = _clearLoan(reqID, amount, directRepay);

        { // block scoping to prevent "stack too deep" compiler error
        // balances after clearing the loan
        uint256 initOwnerDebt = debt.balanceOf(owner);
        uint256 initLenderDebt = debt.balanceOf(lender);
        uint256 initOwnerCollat = collateral.balanceOf(owner);
        uint256 initCoolerCollat = collateral.balanceOf(address(cooler));

        vm.startPrank(owner);
        // aprove debt so that it can be transferred by cooler
        debt.approve(address(cooler), amount);
        cooler.repay(loanID, repayAmount);
        vm.stopPrank();

        // check: debt and collateral balances
        assertEq(debt.balanceOf(owner), initOwnerDebt - repayAmount);
        assertEq(debt.balanceOf(lender), initLenderDebt + repayAmount);
        assertEq(collateral.balanceOf(owner), initOwnerCollat + decollatAmount);
        assertEq(collateral.balanceOf(address(cooler)), initCoolerCollat - decollatAmount);
        }

        { // block scoping to prevent "stack too deep" compiler error
        (, uint256 loanAmount, uint256 loanRepaid, uint256 loanCollat,,,) = cooler.loans(loanID);
        // check: loan storage
        assertEq(initLoanAmount - repayAmount, loanAmount);
        assertEq(0, loanRepaid);
        assertEq(initLoanCollat - decollatAmount, loanCollat);
        }
    }
    
    function test_repay_direct_false() public {
        // test inputs
        bool directRepay = false;
        uint256 amount = 1234 * 1e18;
        uint256 repayAmount = 567 * 1e18;
        uint256 initLoanCollat = _collateralFor(amount);
        uint256 initLoanAmount = amount + _interestFor(amount, INTEREST_RATE, DURATION);
        uint256 decollatAmount = initLoanCollat * repayAmount / initLoanAmount;
        // test setup
        cooler = _initCooler();
        (uint256 reqID, ) = _requestLoan(amount);
        uint256 loanID = _clearLoan(reqID, amount, directRepay);

        { // block scoping to prevent "stack too deep" compiler error
        // balances after clearing the loan
        uint256 initOwnerDebt = debt.balanceOf(owner);
        uint256 initCoolerDebt = debt.balanceOf(address(cooler));
        uint256 initOwnerCollat = collateral.balanceOf(owner);
        uint256 initCoolerCollat = collateral.balanceOf(address(cooler));

        vm.startPrank(owner);
        // aprove debt so that it can be transferred by cooler
        debt.approve(address(cooler), amount);
        cooler.repay(loanID, repayAmount);
        vm.stopPrank();

        // check: debt and collateral balances
        assertEq(debt.balanceOf(owner), initOwnerDebt - repayAmount);
        assertEq(debt.balanceOf(address(cooler)), initCoolerDebt + repayAmount);
        assertEq(collateral.balanceOf(owner), initOwnerCollat + decollatAmount);
        assertEq(collateral.balanceOf(address(cooler)), initCoolerCollat - decollatAmount);
        }

        { // block scoping to prevent "stack too deep" compiler error
        (, uint256 loanAmount, uint256 loanRepaid, uint256 loanCollat,,,) = cooler.loans(loanID);
        // check: loan storage
        assertEq(initLoanAmount - repayAmount, loanAmount);
        assertEq(repayAmount, loanRepaid);
        assertEq(initLoanCollat - decollatAmount, loanCollat);
        }
    }
    
    function testRevert_repay_defaulted() public {
        // test inputs
        bool directRepay = true;
        uint256 amount = 1234 * 1e18;
        uint256 repayAmount = 567 * 1e18;
        // test setup
        cooler = _initCooler();
        (uint256 reqID, ) = _requestLoan(amount);
        uint256 loanID = _clearLoan(reqID, amount, directRepay);

        // block.timestamp > loan expiry
        vm.warp(block.timestamp + DURATION + 1);

        vm.startPrank(owner);
        // aprove debt so that it can be transferred by cooler
        debt.approve(address(cooler), amount);
        // can't repay a defaulted loan
        vm.expectRevert(Cooler.Default.selector);
        cooler.repay(loanID, repayAmount);
        vm.stopPrank();
    }

    // -- Cooler: Claim Repaid ---------------------------------------------------
    
    function test_claimRepaid() public {
        // test inputs
        bool directRepay = false;
        uint256 amount = 1234 * 1e18;
        uint256 repayAmount = 567 * 1e18;
        // test setup
        cooler = _initCooler();
        (uint256 reqID, ) = _requestLoan(amount);
        uint256 loanID = _clearLoan(reqID, amount, directRepay);

        vm.startPrank(owner);
        // aprove debt so that it can be transferred by cooler
        debt.approve(address(cooler), amount);
        cooler.repay(loanID, repayAmount);
        vm.stopPrank();

        { // block scoping to prevent "stack too deep" compiler error
        // balances after repaying the loan
        uint256 initLenderDebt = debt.balanceOf(lender);
        uint256 initCoolerDebt = debt.balanceOf(address(cooler));

        vm.prank(lender);
        cooler.claimRepaid(loanID);

        // check: debt balances
        assertEq(debt.balanceOf(lender), initLenderDebt + repayAmount);
        assertEq(debt.balanceOf(address(cooler)), initCoolerDebt - repayAmount);
        }

        (,, uint256 loanRepaid,,,,) = cooler.loans(loanID);
        // check: loan storage
        assertEq(0, loanRepaid);
    }

    // -- Cooler: Toggle Direct ---------------------------------------------------

    function test_toggleDirect() public {
        // test inputs
        bool directRepay = true;
        uint256 amount = 1234 * 1e18;
        // test setup
        cooler = _initCooler();
        (uint256 reqID, ) = _requestLoan(amount);
        uint256 loanID = _clearLoan(reqID, amount, directRepay);

        vm.startPrank(lender);
        // turn direct repay off
        cooler.toggleDirect(loanID);
        (,,,,,, bool repayDirect) = cooler.loans(loanID);
        // check: loan storage
        assertEq(false, repayDirect);
        
        // turn direct repay on
        cooler.toggleDirect(loanID);
        (,,,,,, repayDirect) = cooler.loans(loanID);
        // check: loan storage
        assertEq(true, repayDirect);
        vm.stopPrank();
    }

    function testRevert_toggleDirect_onlyLender() public {
        // test inputs
        bool directRepay = true;
        uint256 amount = 1234 * 1e18;
        // test setup
        cooler = _initCooler();
        (uint256 reqID, ) = _requestLoan(amount);
        uint256 loanID = _clearLoan(reqID, amount, directRepay);

        vm.prank(others);
        // only lender turn toggle the direct repay
        vm.expectRevert(Cooler.OnlyApproved.selector);
        cooler.toggleDirect(loanID);
    }

    // -- Cooler: Defaulted ---------------------------------------------------

    function test_defaulted() public {
        // test inputs
        bool directRepay = true;
        uint256 amount = 1234 * 1e18;
        // test setup
        cooler = _initCooler();
        (uint256 reqID, ) = _requestLoan(amount);
        uint256 loanID = _clearLoan(reqID, amount, directRepay);

        // block.timestamp > loan expiry
        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(lender);
        cooler.defaulted(loanID);

        (, uint256 loanAmount, uint256 loanRepaid, uint256 loanCollat, uint256 loanExpiry, address loanLender, bool repayDirect) = cooler.loans(loanID);
        // check: loan storage
        assertEq(0, loanAmount);
        assertEq(0, loanRepaid);
        assertEq(0, loanCollat);
        assertEq(0, loanExpiry);
        assertEq(address(0), loanLender);
        assertEq(false, repayDirect);
    }

    function testRevert_defaulted_notExpired() public {
        // test inputs
        bool directRepay = true;
        uint256 amount = 1234 * 1e18;
        // test setup
        cooler = _initCooler();
        (uint256 reqID, ) = _requestLoan(amount);
        uint256 loanID = _clearLoan(reqID, amount, directRepay);

        // block.timestamp <= loan expiry
        vm.warp(block.timestamp + DURATION);

        vm.prank(lender);
        // can't default a non-expired loan
        vm.expectRevert(Cooler.NoDefault.selector);
        cooler.defaulted(loanID);
    }

    // -- Cooler: Delegate ---------------------------------------------------

    function test_delegate() public {
        // test inputs
        uint256 amount = 1234 * 1e18;
        // test setup
        cooler = _initCooler();
        _requestLoan(amount);

        vm.prank(owner);
        cooler.delegate(others);
        assertEq(others, collateral.delegatee());
    }

    function testRevert_delegate_onlyOwner() public {
        // test inputs
        uint256 amount = 1234 * 1e18;
        // test setup
        cooler = _initCooler();
        _requestLoan(amount);

        vm.prank(others);
        vm.expectRevert(Cooler.OnlyApproved.selector);
        cooler.delegate(others);
    }

    // -- Cooler: Approve ---------------------------------------------------

    function test_approve() public {
        // test inputs
        bool directRepay = true;
        uint256 amount = 1234 * 1e18;
        // test setup
        cooler = _initCooler();
        (uint256 reqID, ) = _requestLoan(amount);
        uint256 loanID = _clearLoan(reqID, amount, directRepay);

        vm.prank(lender);
        cooler.approve(others, loanID);

        assertEq(others, cooler.approvals(loanID));
    }

    function testRevert_approve_onlyLender() public {
        // test inputs
        bool directRepay = true;
        uint256 amount = 1234 * 1e18;
        // test setup
        cooler = _initCooler();
        (uint256 reqID, ) = _requestLoan(amount);
        uint256 loanID = _clearLoan(reqID, amount, directRepay);

        vm.prank(others);
        vm.expectRevert(Cooler.OnlyApproved.selector);
        cooler.approve(others, loanID);
    }

    // -- Cooler: Transfer ---------------------------------------------------

    function test_transfer() public {
        // test inputs
        bool directRepay = true;
        uint256 amount = 1234 * 1e18;
        // test setup
        cooler = _initCooler();
        (uint256 reqID, ) = _requestLoan(amount);
        uint256 loanID = _clearLoan(reqID, amount, directRepay);

        // the lender approves the transfer
        vm.prank(lender);
        cooler.approve(others, loanID);
        // the transfer is accepted
        vm.prank(others);
        cooler.transfer(loanID);

        (,,,,, address loanLender,) = cooler.loans(loanID);
        // check: loan storage
        assertEq(others, loanLender);
        assertEq(address(0), cooler.approvals(loanID));
    }

    function testRevert_transfer_onlyApproved() public {
        // test inputs
        bool directRepay = true;
        uint256 amount = 1234 * 1e18;
        // test setup
        cooler = _initCooler();
        (uint256 reqID, ) = _requestLoan(amount);
        uint256 loanID = _clearLoan(reqID, amount, directRepay);

        vm.prank(others);
        vm.expectRevert(Cooler.OnlyApproved.selector);
        cooler.transfer(loanID);
    }

    // -- Cooler: New Roll Terms---------------------------------------------------

    function test_newRollTerms() public {
        // test inputs
        bool directRepay = true;
        uint256 amount = 1234 * 1e18;
        // test setup
        cooler = _initCooler();
        (uint256 reqID, ) = _requestLoan(amount);
        uint256 loanID = _clearLoan(reqID, amount, directRepay);

        vm.prank(lender);
        cooler.provideNewTermsForRoll(
            loanID,
            INTEREST_RATE * 2,
            LOAN_TO_COLLATERAL / 2,
            DURATION * 2
        );

        (Cooler.Request memory request, uint256 loanAmount,,,,,) = cooler.loans(loanID);
        // check: request storage
        assertEq(loanAmount, request.amount);
        assertEq(INTEREST_RATE * 2, request.interest);
        assertEq(LOAN_TO_COLLATERAL / 2, request.loanToCollateral);
        assertEq(DURATION * 2, request.duration);
        assertEq(true, request.active);
    }

    function testRevert_newRollTerms_onlyLender() public {
        // test inputs
        bool directRepay = true;
        uint256 amount = 1234 * 1e18;
        // test setup
        cooler = _initCooler();
        (uint256 reqID, ) = _requestLoan(amount);
        uint256 loanID = _clearLoan(reqID, amount, directRepay);

        vm.prank(others);
        vm.expectRevert(Cooler.OnlyApproved.selector);
        cooler.provideNewTermsForRoll(
            loanID,
            INTEREST_RATE * 2,
            LOAN_TO_COLLATERAL / 2,
            DURATION * 2
        );
    }

    // -- Cooler: Roll ---------------------------------------------------

    function test_roll() public {
        // test inputs
        bool directRepay = true;
        uint256 amount = 1234 * 1e18;
        // test setup
        cooler = _initCooler();
        (uint256 reqID, ) = _requestLoan(amount);
        uint256 loanID = _clearLoan(reqID, amount, directRepay);

        vm.prank(lender);
        cooler.provideNewTermsForRoll(
            loanID,
            INTEREST_RATE * 2,
            LOAN_TO_COLLATERAL / 2,
            DURATION * 2
        );
        
        { // block scoping to prevent "stack too deep" compiler error
        // balances after providing new terms to roll the loan
        uint256 initOwnerCollat = collateral.balanceOf(owner);
        uint256 initCoolerCollat = collateral.balanceOf(address(cooler));
        // aux calculations to get the newCollat amount after rolling the loan
        (, uint256 loanAmount,, uint256 loanCollat,,,) = cooler.loans(loanID);
        uint256 rollCollat = loanAmount * DECIMALS / (LOAN_TO_COLLATERAL / 2);
        uint256 newCollat = rollCollat > loanCollat ? rollCollat - loanCollat : 0;
   
        vm.startPrank(owner);
        // aprove collateral so that it can be transferred by cooler
        collateral.approve(address(cooler), newCollat);
        cooler.roll(loanID);
        vm.stopPrank();

        // check: debt balances
        assertEq(collateral.balanceOf(owner), initOwnerCollat - newCollat);
        assertEq(collateral.balanceOf(address(cooler)), initCoolerCollat + newCollat);
        }
    }

    function testRevert_roll_onlyActive() public {
        // test inputs
        bool directRepay = true;
        uint256 amount = 1234 * 1e18;
        // test setup
        cooler = _initCooler();
        (uint256 reqID, ) = _requestLoan(amount);
        uint256 loanID = _clearLoan(reqID, amount, directRepay);
   
        vm.prank(owner);
        // not rollable unless lender provides new terms for rolling
        vm.expectRevert(Cooler.NotRollable.selector);
        cooler.roll(loanID);
    }

    function testRevert_roll_defaulted() public {
        // test inputs
        bool directRepay = true;
        uint256 amount = 1234 * 1e18;
        // test setup
        cooler = _initCooler();
        (uint256 reqID, ) = _requestLoan(amount);
        uint256 loanID = _clearLoan(reqID, amount, directRepay);
   
        vm.prank(lender);
        cooler.provideNewTermsForRoll(
            loanID,
            INTEREST_RATE * 2,
            LOAN_TO_COLLATERAL / 2,
            DURATION * 2
        );
        
        // block.timestamp > loan expiry
        vm.warp(block.timestamp + DURATION * 2 + 1);

        vm.prank(owner);
        // can't roll an expired loan
        vm.expectRevert(Cooler.Default.selector);
        cooler.roll(loanID);
    }
}