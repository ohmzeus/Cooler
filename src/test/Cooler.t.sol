// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {UserFactory} from "test/lib/UserFactory.sol";

import {MockERC20} from "test/mocks/OlympusMocks.sol";

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
// [ ] repay
//     [ ] only possible before expiry
//     [ ] loan is updated
//     [ ] direct (true): new collateral and debt balances are correct
//     [ ] direct (false): new collateral and debt balances are correct
// [ ] claimRepaid
//     [ ] only lender can claim repaid?
//     [ ] loan is updated
//     [ ] lender and cooler new debt balances are correct
// [ ] roll
//     [ ] only possible before expiry
//     [ ] only possible for active loans
//     [ ] loan is updated
//     [ ] user and cooler new collateral balances are correct
// [ ] delegate
//     [ ] only owner can delegate
//     [ ] collateral voting power is properly delegated
// [ ] clear
//     [ ] request cleared, a new loan is created, 
//     [ ] user and lender new debt balances are correct
// [ ] provideNewTermsForRoll
//     [ ] only lender can set new terms
//     [ ] request is properly updated
// [ ] defaulted
//     [ ] only possible after expiry
//     [ ] lender and cooler new collateral balances are correct
// [ ] approve
//     [ ] only the lender can approve a transfer
//     [ ] approval stored
// [ ] transfer
//     [ ] only the approved addresses can transfer
//     [ ] loan is properly updated
// [ ] toggleDirect
//     [ ] only the lender can toggle
//     [ ] loan is properly updated


contract CoolerTest is Test {

    MockERC20 internal collateral;
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
        collateral = new MockERC20("Collateral", "COLLAT", 18);
        debt = new MockERC20("Debt", "DEBT", 18);

        // Create accounts
        UserFactory userFactory = new UserFactory();
        address[] memory users = userFactory.create(3);
        owner = users[0];
        lender = users[1];
        others = users[2];
        deal(address(debt), lender, 500 * 1e18);
        deal(address(collateral), owner, 10 * 1e18);

        // Deploy system contracts
        coolerFactory = new CoolerFactory();
    }

    // -- Helper Functions ---------------------------------------------------
    function _initCooler() internal returns(Cooler) {
        vm.prank(owner);
        return Cooler(coolerFactory.generate(collateral, debt));
    }

    function _requestLoan(uint256 amount) internal returns(uint256, uint256) {
        uint256 reqCollateral = amount * DECIMALS / LOAN_TO_COLLATERAL;

        vm.startPrank(owner);
        // aprove collateral so that it can be transfered to the cooler
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

    // -- Cooler Functions ---------------------------------------------------
    function test_constructor() public {
        vm.prank(owner);
        cooler = Cooler(coolerFactory.generate(collateral, debt));
        assertEq(address(collateral), address(cooler.collateral()));
        assertEq(address(debt), address(cooler.debt()));
        assertEq(address(coolerFactory), address(cooler.factory()));
    }

    function test_request() public {
        // test inputs
        uint256 amount = 1234;
        // test setup
        cooler = _initCooler();
        uint256 reqCollateral = amount * DECIMALS / LOAN_TO_COLLATERAL;
        // balances before requesting the loan
        uint256 initOwnerCollateral = collateral.balanceOf(owner);
        uint256 initCoolerCollateral = collateral.balanceOf(address(cooler));

        vm.startPrank(owner);
        // aprove collateral so that it can be transfered to the cooler
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
    
    function test_rescind() public {
        // test inputs
        uint256 amount = 1234;
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
        uint256 amount = 1234;
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
        uint256 amount = 1234;
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
}