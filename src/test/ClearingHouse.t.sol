// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {UserFactory} from "test/lib/UserFactory.sol";

import {MockERC20, MockGohm, MockStaking} from "test/mocks/OlympusMocks.sol";

import "olympus-v3/Kernel.sol";
import {RolesAdmin} from "olympus-v3/policies/RolesAdmin.sol";
import {OlympusRoles} from "olympus-v3/modules/ROLES/OlympusRoles.sol";
import {OlympusMinter, MINTRv1} from "olympus-v3/modules/MINTR/OlympusMinter.sol";
import {OlympusTreasury, TRSRYv1} from "olympus-v3/modules/TRSRY/OlympusTreasury.sol";

import {ClearingHouse, Cooler, CoolerFactory} from "src/ClearingHouse.sol";

// Tests for ClearingHouse
//
// ClearingHouse Setup and Permissions
// [ ] configureDependencies
// [ ] requestPermissions
//
// ClearingHouse Functions
// [ ] rebalance
//     [ ] can't rebalance faster than the funding cadence
//     [ ] Treasury approvals for the clearing house are correct
//     [ ] if necessary, sends excees DSR funds back to the Treasury
// [ ] sweep
//     [ ] excess DAI is deposited into DSR
// [ ] defund
//     [ ] only "cooler_overseer" can call
//     [ ] sends input ERC20 token back to the Treasury
// [ ] lend
//     [ ] only lend to coolers issued by coolerFactory
//     [ ] only collateral = gOHM and only debt = DAI
//     [ ] loan request is logged
//     [ ] user and cooler new gOHM balances are correct
//     [ ] user and Treasury new DAI balances are correct
// [ ] roll
//     [ ] user and cooler new gOHM balances are correct
// [ ] burn
//     [ ] OHM supply is properly reduced

contract ClearingHouseTest is Test {

    MockGohm internal gohm;
    MockERC20 internal ohm;
    MockERC20 internal sohm;
    MockERC20 internal reserve;
    MockStaking internal staking;

    Kernel internal kernel;
    OlympusRoles internal ROLES;
    OlympusMinter internal MINTR;
    OlympusTreasury internal TRSRY;
    RolesAdmin internal rolesAdmin;
    ClearingHouse internal clearingHouse;
    CoolerFactory internal coolerFactory;

    address internal admin;
    address internal policy;

    // Parameter Bounds
    uint256 public constant INTEREST_RATE = 5e15; // 0.5%
    uint256 public constant LOAN_TO_COLLATERAL = 3000 * 1e18; // 3,000
    uint256 public constant DURATION = 121 days; // Four months
    uint256 public constant FUND_CADENCE = 7 days; // One week
    uint256 public constant FUND_AMOUNT = 18 * 1e24; // 18 million
/*
    function setUp() public {
        vm.warp(51 * 365 * 24 * 60 * 60); // Set timestamp at roughly Jan 1, 2021 (51 years since Unix epoch)

        // Create accounts
        UserFactory userFactory = new UserFactory();
        address[] memory users = userFactory.create(2);
        admin = users[0];
        policy = users[1];

        // Deploy mocks 
        gohm = new MockGohm(260);
        ohm = new MockERC20("OHM", "OHM", 9);
        sohm = new MockERC20("sOHM", "sOHM", 9);
        reserve = new MockERC20("DSR DAI", "sDAI", 18);
        staking = new MockStaking(address(ohm), address(sohm), address(gohm), 2200, 0, 2200);

        // Deploy system contracts
        kernel = new Kernel();
        ROLES = new OlympusRoles(kernel);
        TRSRY = new OlympusTreasury(kernel);
        MINTR = new OlympusMinter(kernel, address(ohm));
        rolesAdmin = new RolesAdmin(kernel);
        coolerFactory = new CoolerFactory();
        clearingHouse = new ClearingHouse(
            address(gohm),
            address(staking),
            address(reserve),
            address(coolerFactory),
            address(kernel)
        );
    }

    // -- ClearingHouse Setup and Permissions -------------------------------------------------
    function test_configureDependencies() public {
        Keycode[] memory expectedDeps = new Keycode[](3);
        expectedDeps[0] = toKeycode("TRSRY");
        expectedDeps[1] = toKeycode("MINTR");
        expectedDeps[2] = toKeycode("ROLES");

        Keycode[] memory deps = clearingHouse.configureDependencies();
        assertEq(deps.length, expectedDeps.length);
        assertEq(fromKeycode(deps[0]), fromKeycode(expectedDeps[0]));
        assertEq(fromKeycode(deps[1]), fromKeycode(expectedDeps[1]));
        assertEq(fromKeycode(deps[2]), fromKeycode(expectedDeps[2]));
    }

    function test_requestPermissions() public {
        Permissions[] memory expectedPerms = new Permissions[](3);
        Keycode TRSRY_KEYCODE = toKeycode("TRSRY");
        Keycode MINTR_KEYCODE = toKeycode("MINTR");
        expectedPerms[0] = Permissions(TRSRY_KEYCODE, TRSRY.withdrawReserves.selector);
        expectedPerms[1] = Permissions(TRSRY_KEYCODE, TRSRY.increaseWithdrawApproval.selector);
        expectedPerms[2] = Permissions(MINTR_KEYCODE, MINTR.burnOhm.selector);
        
        Permissions[] memory perms = clearingHouse.requestPermissions();
        assertEq(perms.length, expectedPerms.length);
        for (uint256 i = 0; i < perms.length; i++) {
            assertEq(fromKeycode(perms[i].keycode), fromKeycode(expectedPerms[i].keycode));
            assertEq(perms[i].funcSelector, expectedPerms[i].funcSelector);
        }
    }
    */
}