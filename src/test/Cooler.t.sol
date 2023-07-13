// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import {Test} from "forge-std/Test.sol";
import {UserFactory} from "test/lib/UserFactory.sol";

import {MockERC20} from "test/mocks/OlympusMocks.sol";

import {Cooler} from "src/Cooler.sol";
import {CoolerFactory} from "src/CoolerFactory.sol";

// Tests for Cooler
//
// [ ] request
//     [ ] new request is stored and an event is emitted
//     [ ] user and cooler new collateral balances are correct
// [ ] rescind
//     [ ] only owner can rescind
//     [ ] request is updated and an event is emitted
//     [ ] user and cooler new collateral balances are correct
// [ ] repay
//     [ ] only possible before expiry
//     [ ] loan is updated and an event is emitted
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
//     [ ] request cleared, a new loan is created, and an event is emitted
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
    MockERC20 internal otherDebt;
    
    address admin;
    address lender;
    address others;

    CoolerFactory internal coolerFactory;
    Cooler internal cooler;

    function setUp() public {
        vm.warp(51 * 365 * 24 * 60 * 60); // Set timestamp at roughly Jan 1, 2021 (51 years since Unix epoch)

        // Create accounts
        UserFactory userFactory = new UserFactory();
        address[] memory users = userFactory.create(2);
        admin = users[0];
        lender = users[1];
        others = users[2];

        // Deploy mocks 
        collateral = new MockERC20("Collateral", "COLLAT", 18);
        debt = new MockERC20("Debt", "DEBT", 18);

        // Deploy system contracts
        coolerFactory = new CoolerFactory();

        vm.prank(admin);
        cooler = coolerFactory.generate(collateral, debt);
    }

    // -- Cooler Functions -------------------------------------------------
    // function test_() public {
    // }
}