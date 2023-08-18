# Cooler Loans

With the successful conclusion of OIP-144 and its subsequent RFCs, Olympus will implement a lending facility that to allow users to take fixed term loans against their gOHM.

Such lending facility has been built on top of 3 smartcontracts:

## Cooler.sol

> src/Cooler.sol

A `Cooler` is an escrow contract that facilitates fixed-duration, peer-to-peer loans for a user-defined debt-collateral pair.

- Keeps track of all the requests/loans and their status.
- Escrows the collateral during the lending period.
- Handles clearings, repayments, rollovers and defaults.
- Offers callbacks to the lender after key actions happen.

## CoolerFactory.sol

> src/CoolerFactory.sol

- Keeps track of all the deployed contracts.
- Deploys a new Cooler if the combination of user-debt-collateral doesn't exist yet.
- Uses clones with immutable arguments to save gas.
- In charge of logging the Cooler events.

## Clearinghouse.sol

> src/ClearingHouse.sol

The lending facility is called `Clearinghouse`. This smart contract has been built to be integrated with [Olympus V3](https://github.com/OlympusDAO/olympus-v3) and the [Default Framework](https://github.com/fullyallocated/Default). As such, the `Clearinghouse` is a `Policy` that will have permissions to incur debt from the Treasury (to issue the loans), as well as burning OHM (to reduce supply whenever a borrower defaults).

- Implements the mandate of the Olympus community in OIP-144 by offering loans at the governance-approved terms.
- Tracks the outstanding debt and interest that the protocol should be received upon repayment.
- Its lending capacity is limited by a `FUND_AMOUNT` and a `FUND_CADENCE`.
- Despite offering the loans in DAI, since it deposits all its idle funds into the DSR, holds sDAI.
- Implements permissioned functions to shutdown, defund, and reactivate the lending facility.

## Diagram

The following diagram aims to provide a high-level overview of the lending facility architecture. For further context, the contracts and their comments should be read.

![](/cooler-loans-diagram.svg)