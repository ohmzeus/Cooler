// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.15;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {UserFactory} from "test/lib/UserFactory.sol";

//import {MockERC20, MockGohm, MockStaking} from "test/mocks/OlympusMocks.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";

import {Permissions, Keycode, fromKeycode, toKeycode} from "olympus-v3/Kernel.sol";
import {RolesAdmin, Kernel, Actions} from "olympus-v3/policies/RolesAdmin.sol";
import {OlympusRoles, ROLESv1} from "olympus-v3/modules/ROLES/OlympusRoles.sol";
import {OlympusMinter, MINTRv1} from "olympus-v3/modules/MINTR/OlympusMinter.sol";
import {OlympusTreasury, TRSRYv1} from "olympus-v3/modules/TRSRY/OlympusTreasury.sol";
//import {Actions} from "olympus-v3/Kernel.sol";

import {ClearingHouse, Cooler, CoolerFactory} from "src/ClearingHouse.sol";
//import {Cooler, Loan, Request} from "src/Cooler.sol";

// Tests for ClearingHouse
//
// ClearingHouse Setup and Permissions
// [X] configureDependencies
// [X] requestPermissions
//
// ClearingHouse Functions
// [ ] rebalance
//     [ ] can't rebalance faster than the funding cadence
//     [ ] Treasury approvals for the clearing house are correct
//     [ ] if necessary, sends excess DSR funds back to the Treasury
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

contract MockStaking {
    function unstake(
        address,
        uint256 amount,
        bool,
        bool
    ) external pure returns (uint256) {
        return amount;
    }
}

/// @dev Although we are have sDAI in the treasury, the sDAI will be equal to
///      DAI values everytime we convert between them. This is because no external
///      DAI is being added to the sDAI vault, so the exchange rate is 1:1. This
///      does not cause any issues with our testing.
contract ClearingHouseTest is Test {
    MockERC20 internal gohm;
    MockERC20 internal ohm;
    MockERC20 internal dai;
    MockERC4626 internal sdai;

    Kernel public kernel;
    OlympusRoles internal ROLES;
    OlympusMinter internal MINTR;
    OlympusTreasury internal TRSRY;
    RolesAdmin internal rolesAdmin;
    ClearingHouse internal clearinghouse;
    CoolerFactory internal factory;
    Cooler internal testCooler;

    address internal user;
    address internal overseer;
    uint256 internal initialSDai;

    function setUp() public {
        address[] memory users = (new UserFactory()).create(2);
        user = users[0];
        overseer = users[1];

        MockStaking staking = new MockStaking();
        factory = new CoolerFactory();

        ohm = new MockERC20("olympus", "OHM", 9);
        gohm = new MockERC20("olympus", "gOHM", 18);
        dai = new MockERC20("dai", "DAI", 18);
        sdai = new MockERC4626(dai, "sDai", "sDAI");

        kernel = new Kernel(); // this contract will be the executor

        TRSRY = new OlympusTreasury(kernel);
        MINTR = new OlympusMinter(kernel, address(ohm));
        ROLES = new OlympusRoles(kernel);

        clearinghouse = new ClearingHouse(
            address(gohm),
            address(staking),
            address(sdai),
            address(factory),
            address(kernel)
        );
        rolesAdmin = new RolesAdmin(kernel);

        kernel.executeAction(Actions.InstallModule, address(TRSRY));
        kernel.executeAction(Actions.InstallModule, address(MINTR));
        kernel.executeAction(Actions.InstallModule, address(ROLES));

        kernel.executeAction(Actions.ActivatePolicy, address(clearinghouse));
        kernel.executeAction(Actions.ActivatePolicy, address(rolesAdmin));

        /// Configure access control
        rolesAdmin.grantRole("cooler_overseer", overseer);

        // Setup clearinghouse initial conditions
        uint mintAmount = 200_000_000e18; // Init treasury with 200 million

        dai.mint(address(TRSRY), mintAmount);
        //dai.approve(address(sdai), dai.balanceOf(address(this)));
        //sdai.deposit(dai.balanceOf(address(this)), address(TRSRY));

        // Initial rebalance, fund clearinghouse and set
        // fundTime to current timestamp
        clearinghouse.rebalance();

        testCooler = Cooler(factory.generate(gohm, dai));

        gohm.mint(overseer, mintAmount);

        // Skip 1 week ahead to allow rebalances
        skip(1 weeks);

        // Initial funding of clearinghouse is equal to FUND_AMOUNT
        assertEq(sdai.maxWithdraw(address(clearinghouse)), clearinghouse.FUND_AMOUNT());
    }

    // --- HELPER FUNCTIONS ----------------------------------------------

    function _createLoanForUser(uint256 loanAmount_) internal returns (Cooler cooler, uint256 gohmNeeded, uint256 loanID) {
        vm.startPrank(user);
        cooler = Cooler(factory.generate(gohm, dai));

        // Ensure user has enough collateral
        gohmNeeded = cooler.collateralFor(loanAmount_, clearinghouse.LOAN_TO_COLLATERAL());
        gohm.mint(user, gohmNeeded);

        gohm.approve(address(clearinghouse), gohmNeeded);
        loanID = clearinghouse.lend(cooler, loanAmount_);
        vm.stopPrank();
    }

    function _skipDays(uint8 days_) internal {
        vm.warp(block.timestamp + days_ * 1 days);
        if (block.timestamp >= clearinghouse.fundTime()) {
            clearinghouse.rebalance();
        }
    }

    // --- SETUP, DEPENDENCIES, AND PERMISSIONS --------------------------
    
    function test_configureDependencies() public {
        Keycode[] memory expectedDeps = new Keycode[](3);
        expectedDeps[0] = toKeycode("TRSRY");
        expectedDeps[1] = toKeycode("MINTR");
        expectedDeps[2] = toKeycode("ROLES");

        Keycode[] memory deps = clearinghouse.configureDependencies();
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
        
        Permissions[] memory perms = clearinghouse.requestPermissions();
        assertEq(perms.length, expectedPerms.length);
        for (uint256 i = 0; i < perms.length; i++) {
            assertEq(fromKeycode(perms[i].keycode), fromKeycode(expectedPerms[i].keycode));
            assertEq(perms[i].funcSelector, expectedPerms[i].funcSelector);
        }
    }

    // --- LEND ----------------------------------------------------------

    function testRevert_LendMaliciousCooler() public {
        // Clearinghouse only accepts coolers created by the CoolerFactory
        Cooler malicious = new Cooler(address(this), gohm, dai);
        vm.expectRevert(ClearingHouse.OnlyFromFactory.selector);
        clearinghouse.lend(malicious, 1e18);
    }

    function testRevert_LendNotGohmDai() public {
        MockERC20 wagmi = new MockERC20("wagmi", "WAGMI", 18);
        MockERC20 ngmi = new MockERC20("ngmi", "NGMI", 18);

        // Clearinghouse only accepts gOHM-DAI
        Cooler badCooler1 = Cooler(factory.generate(wagmi, ngmi));
        vm.expectRevert(ClearingHouse.BadEscrow.selector);
        clearinghouse.lend(badCooler1, 1e18);
        // Clearinghouse only accepts gOHM-DAI
        Cooler badCooler2 = Cooler(factory.generate(gohm, ngmi));
        vm.expectRevert(ClearingHouse.BadEscrow.selector);
        clearinghouse.lend(badCooler2, 1e18);
        // Clearinghouse only accepts gOHM-DAI
        Cooler badCooler3 = Cooler(factory.generate(wagmi, dai));
        vm.expectRevert(ClearingHouse.BadEscrow.selector);
        clearinghouse.lend(badCooler3, 1e18);
    }
    
    function test_LendToCooler(uint256 loanAmount_) public {
        // Loan Amount cannot exceed Clearinghouse funding
        loanAmount_ = bound(loanAmount_, 0, clearinghouse.FUND_AMOUNT());

        (Cooler cooler, uint256 gohmNeeded, ) = _createLoanForUser(loanAmount_);

        assertEq(gohm.balanceOf(address(cooler)), gohmNeeded, "Cooler gOHM balance incorrect");
        assertEq(dai.balanceOf(address(user)), loanAmount_, "User DAI balance incorrect");
        assertEq(dai.balanceOf(address(cooler)), 0, "Cooler DAI balance incorrect");
        assertEq(clearinghouse.receivables(), clearinghouse.loanForCollateral(gohmNeeded), "Clearinghouse receivables incorrect");
    }

    function test_RollLoan(uint256 loanAmount_) public {
        bound(loanAmount_, 0, clearinghouse.FUND_AMOUNT());

        (Cooler cooler, uint256 gohmNeeded, uint256 loanID) = _createLoanForUser(loanAmount_);

        Cooler.Loan memory initLoan = cooler.getLoan(loanID);

        // Move forward 2 months (half duration of loan)
        _skipDays(120);

        // Roll loan
        clearinghouse.roll(cooler, loanID);

        Cooler.Loan memory newLoan = cooler.getLoan(loanID);

        // TODO verify these assertions
        assertEq(gohm.balanceOf(address(cooler)), gohmNeeded, "Cooler gOHM balance incorrect");
        assertEq(newLoan.amount, initLoan.amount, "Loan amount incorrect");
        assertEq(newLoan.repaid, initLoan.repaid, "Loan repaid incorrect");
        assertEq(newLoan.collateral, initLoan.collateral, "Loan collateral incorrect");
        assertEq(newLoan.expiry, initLoan.expiry + initLoan.request.duration, "Loan expiry incorrect");
    }

    // TODO use provideNewTermsForRoll function, then call roll and verify
    function test_RollLoanNewTerms() public {}

    function test_RebalancePullFunds() public {
        uint256 oneMillion = 1e24;
        uint256 daiBal = sdai.maxWithdraw(address(clearinghouse));

        // Burn 1 mil from clearinghouse to simulate assets being lent
        vm.prank(address(clearinghouse));
        sdai.withdraw(oneMillion, address(0x0), address(clearinghouse));

        assertEq(sdai.maxWithdraw(address(clearinghouse)), daiBal - oneMillion);

        // Test if clearinghouse pulls in 1 mil DAI from treasury 
        uint256 prevTrsryDaiBal = dai.balanceOf(address(TRSRY));

        clearinghouse.rebalance();
        daiBal = sdai.maxWithdraw(address(clearinghouse));

        assertEq(prevTrsryDaiBal - oneMillion, dai.balanceOf(address(TRSRY)));
        assertEq(daiBal, clearinghouse.FUND_AMOUNT());
    }

    function test_RebalanceReturnFunds() public {
        uint256 oneMillion = 1e24;
        uint256 initDaiBal = sdai.maxWithdraw(address(clearinghouse));

        // Mint 1 million to clearinghouse and sweep to simulate assets being repaid
        dai.mint(address(clearinghouse), oneMillion);
        clearinghouse.sweep();

        assertEq(sdai.maxWithdraw(address(clearinghouse)), initDaiBal + oneMillion);

        uint256 prevTrsryDaiBal = dai.balanceOf(address(TRSRY));
        uint256 prevDaiBal = sdai.maxWithdraw(address(clearinghouse));

        clearinghouse.rebalance();

        assertEq(prevTrsryDaiBal + oneMillion, dai.balanceOf(address(TRSRY)));
        assertEq(prevDaiBal - oneMillion, sdai.maxWithdraw(address(clearinghouse)));
    }

    function testRevert_RebalanceEarly() public {
        clearinghouse.rebalance();
        vm.expectRevert(ClearingHouse.TooEarlyToFund.selector);
        clearinghouse.rebalance();
    }

    // Should be able to rebalance multiple times if past due
    function test_RebalancePastDue() public {
        // Already skipped 1 week ahead in setup. Do once more and call rebalance twice.
        skip(2 weeks);
        for(uint i; i < 3; i++) {
            clearinghouse.rebalance();
        }
    }

    function test_Sweep() public {
        uint256 sdaiBal = sdai.balanceOf(address(clearinghouse));

        // Mint 1 million to clearinghouse and sweep to simulate assets being repaid
        dai.mint(address(clearinghouse), 1e24);
        clearinghouse.sweep();

        assertEq(sdai.balanceOf(address(clearinghouse)), sdaiBal + 1e24);
    }

    function test_Defund() public {
        uint256 sdaiTrsryBal = sdai.balanceOf(address(TRSRY));
        vm.prank(overseer);
        clearinghouse.defund(sdai, 1e24);
        assertEq(sdai.balanceOf(address(TRSRY)), sdaiTrsryBal + 1e24);
    }

    function test_DefundNotGohm() public {
        vm.expectRevert(ClearingHouse.OnlyBurnable.selector);
        vm.prank(overseer);
        clearinghouse.defund(gohm, 1e24);
    }

    // TODO have loan default and test if gOHM is burned
    function test_BurnExcess() public {}
}