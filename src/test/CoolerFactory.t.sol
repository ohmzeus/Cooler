// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.15;

import {Test} from "forge-std/Test.sol";
import {UserFactory} from "test/lib/UserFactory.sol";

import {MockERC20} from "test/mocks/OlympusMocks.sol";

import {CoolerFactory} from "src/CoolerFactory.sol";

// Tests for CoolerFactory
//
// [X] generate
//     [X] generates a cooler for new user <> collateral <> debt combinations
//     [X] returns address if a cooler already exists
// [X] newEvent
//     [X] only generated coolers can emit events
//     [X] emitted logs match the input variables

contract CoolerFactoryTest is Test {

    MockERC20 internal collateral;
    MockERC20 internal debt;
    MockERC20 internal otherDebt;
    
    address alice;
    address bob;

    CoolerFactory internal coolerFactory;

    // CoolerFactory Expected events
    event Clear(address cooler, uint256 reqID);
    event Repay(address cooler, uint256 loanID, uint256 amount);
    event Rescind(address cooler, uint256 reqID);
    event Request(address cooler, address collateral, address debt, uint256 reqID);

    function setUp() public {
        vm.warp(51 * 365 * 24 * 60 * 60); // Set timestamp at roughly Jan 1, 2021 (51 years since Unix epoch)

        // Create accounts
        UserFactory userFactory = new UserFactory();
        address[] memory users = userFactory.create(2);
        alice = users[0];
        bob = users[1];

        // Deploy mocks 
        collateral = new MockERC20("Collateral", "COLLAT", 18);
        debt = new MockERC20("Debt", "DEBT", 18);
        otherDebt = new MockERC20("Other Debt", "OTHER", 18);

        // Deploy system contracts
        coolerFactory = new CoolerFactory();
    }

    // -- CoolerFactory Functions -------------------------------------------------
    function test_generate() public {

        vm.startPrank(alice);
        // First time (alice <> collateral <> debt) the cooler is generated
        address coolerAlice = coolerFactory.generate(collateral, debt);
        assertEq(true, coolerFactory.created(coolerAlice));
        assertEq(coolerAlice, coolerFactory.coolersFor(collateral, debt, 0));
        // Second time (alice <> collateral <> debt) the cooler is just read
        address readCoolerAlice = coolerFactory.generate(collateral, debt);
        assertEq(true, coolerFactory.created(readCoolerAlice));
        assertEq(readCoolerAlice, coolerFactory.coolersFor(collateral, debt, 0));
        vm.stopPrank();

        vm.prank(bob);
        // First time (bob <> collateral <> debt) the cooler is generated
        address coolerBob = coolerFactory.generate(collateral, debt);
        assertEq(true, coolerFactory.created(coolerBob));
        assertEq(coolerBob, coolerFactory.coolersFor(collateral, debt, 1));
        // First time (bob <> collateral <> other debt) the cooler is generated
        address otherCoolerBob = coolerFactory.generate(collateral, otherDebt);
        assertEq(true, coolerFactory.created(otherCoolerBob));
        assertEq(otherCoolerBob, coolerFactory.coolersFor(collateral, otherDebt, 0));
    }

    function test_newEvent() public {
        uint256 id = 0;
        uint256 amount = 1234;

        vm.prank(alice);
        address cooler = coolerFactory.generate(collateral, debt);

        vm.startPrank(cooler);
        // Clear Event
        vm.expectEmit(true, true, false, false);
        emit Clear(cooler, id);
        coolerFactory.newEvent(id, CoolerFactory.Events.Clear, amount);
        // Repay Event
        vm.expectEmit(true, true, true, false);
        emit Repay(cooler, id, amount);
        coolerFactory.newEvent(id, CoolerFactory.Events.Repay, amount);
        // Rescind Event
        vm.expectEmit(true, true, false, false);
        emit Rescind(cooler, id);
        coolerFactory.newEvent(id, CoolerFactory.Events.Rescind, amount);
        // Request Event
        vm.expectEmit(true, true, true, true);
        emit Request(cooler, address(collateral), address(debt), id);
        coolerFactory.newEvent(id, CoolerFactory.Events.Request, amount);
    }

    function testRevert_newEvent() public {
        uint256 id = 0;
        uint256 amount = 1234;

        // Only coolers can emit events
        vm.prank(alice);
        vm.expectRevert("Only Created");
        coolerFactory.newEvent(id, CoolerFactory.Events.Clear, amount);
    }
}