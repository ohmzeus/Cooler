// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../../lib/ds-test/src/test.sol";
import "./MockTreasury.sol";
import "./TestCH.sol";

/// @dev todo: proxied repay

contract ContractTest is DSTest {
    Treasury private treasury;
    ERC20 private gOHM;
    ERC20 private dai;
    CoolerFactory private factory;
    ClearingHouse private clearinghouse;
    Cooler private cooler;

    uint duration = 365 days;
    uint interest = 2e16;
    uint loanToCollateral = 25e20;

    uint time = 100_000;

    function setUp() public {
        treasury = new Treasury();
        gOHM = new ERC20("gOHM", "gOHM");
        dai = new ERC20("DAI", "DAI");
        factory = new CoolerFactory();
        clearinghouse = new ClearingHouse(address(this), address(this), gOHM, dai, factory, address(treasury));

        uint mintAmount = 2e24; // Fund 2 million
        dai.mint(address(treasury), mintAmount);
        clearinghouse.fund(mintAmount); 

        cooler = Cooler(factory.generate(gOHM, dai));

        gOHM.mint(address(this), mintAmount);
    }

    function request() internal returns (uint reqID) {
        uint cooler0 = gOHM.balanceOf(address(cooler));

        uint collateral = 1e18; // one token
        uint amount = collateral * loanToCollateral / 1e18;
        
        gOHM.approve(address(cooler), collateral);
        
        reqID = cooler.request(amount, interest, loanToCollateral, duration);

        // Collateral should be transferred
        assertTrue(gOHM.balanceOf(address(cooler)) == cooler0 + collateral);
    }

    function rescind(uint reqID) internal {
        uint balance0 = gOHM.balanceOf(address(this));
        (uint amount,, uint ltc,,) = cooler.requests(reqID);

        cooler.rescind(reqID);

        assertTrue(gOHM.balanceOf(address(this)) == balance0 + (amount * 1e18 / ltc));
    }

    function clear(uint index) internal returns (uint loanID) {
        loanID = clearinghouse.clear(cooler, index);

        assertTrue(dai.balanceOf(address(this)) == loanToCollateral);
    }

    function repay(uint percent) internal {
        uint daiBalance0 = dai.balanceOf(address(clearinghouse));
        uint gBalance0 = gOHM.balanceOf(address(this));

        (,uint loan, uint collateral,,) = cooler.loans(0);

        uint amountDAI = loan * percent / 100;
        uint amountgOHM = collateral * percent / 100;
        
        dai.mint(address(this), amountDAI);
        dai.approve(address(cooler), amountDAI);
        
        cooler.repay(0, amountDAI, time);
        
        uint daiBalance1 = dai.balanceOf(address(clearinghouse));
        uint gBalance1 = gOHM.balanceOf(address(this));

        assertTrue(daiBalance0 + amountDAI == daiBalance1);
        assertTrue(gBalance0 + amountgOHM == gBalance1);
    }

    function roll(uint loanID) internal {
        (,uint loan0, uint collateral0, uint expiry0,) = cooler.loans(loanID);

        uint addToLoan = loan0 * interest / 1e18;
        uint addToCollateral = collateral0 * interest / 1e18;

        gOHM.approve(address(cooler), addToCollateral);

        cooler.roll(loanID, time);

        (,uint loan1, uint collateral1, uint expiry1,) = cooler.loans(loanID);

        assertTrue(loan0 + addToLoan == loan1);
        assertTrue(collateral0 + addToCollateral == collateral1);
        assertTrue(expiry0 + duration == expiry1);
    }

    function processDefault(uint loanID) internal {
        (,,uint collateral, uint expiry, address lender) = cooler.loans(loanID);
        uint balance0 = gOHM.balanceOf(address(lender));

        cooler.defaulted(loanID, expiry + 1);

        assertTrue(gOHM.balanceOf(lender) == balance0 + collateral);
    }

    function withdrawTokens() internal {
        uint daiBalance = dai.balanceOf(address(clearinghouse));
        uint gOHMBalance = gOHM.balanceOf(address(clearinghouse));
        uint treasuryBalanceDAI = dai.balanceOf(address(treasury));
        uint treasuryBalancegOHM = gOHM.balanceOf(address(treasury));

        clearinghouse.defund(dai, daiBalance);
        clearinghouse.defund(gOHM, gOHMBalance);

        assertTrue(dai.balanceOf(address(treasury)) == daiBalance + treasuryBalanceDAI);
        assertTrue(gOHM.balanceOf(address(treasury)) == gOHMBalance + treasuryBalancegOHM);
    }

    function test() public {
        setUp();
        uint reqID;
        uint loanID;

        // Request and rescind request
        rescind(request());

        // Request and clear loan
        reqID = request();
        loanID = clear(reqID);

        // Test repay
        (,uint loan0,,,) = cooler.loans(loanID);

        repay(0); // Repay nothing
        (,uint loan1,,,) = cooler.loans(loanID);
        assertTrue(loan0 == loan1); // Nothing should have happened

        repay(50); // Repay half
        (,uint loan2,,,) = cooler.loans(loanID);
        assertTrue(loan1 == loan2 * 2);

        // Test roll
        roll(loanID);
        (,uint loan3,,,) = cooler.loans(loanID);

        // Make sure repay still works
        repay(69);
        (,uint loan4,,,) = cooler.loans(loanID);
        assertTrue(loan3 * 31 / 100 == loan4);

        // Test default
        processDefault(loanID);

        // Transfer balances to treasury
        withdrawTokens();
    }
}