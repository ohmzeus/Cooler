# Cooler Loans

With the successful conclusion of OIP-XXX, Olympus will implement a lending facility that will allow users holders to take fixed term loans against their gOHM.

Such lending facility has been built on top of 3 smartcontracts:
- `CoolerFactory.sol`
- `Cooler.sol`
- `ClearingHouse.sol`

A `Cooler` is an escrow contract that facilitates fixed-duration, peer-to-peer loans for a user-defined debt-collateral pair. On top of that, the `CoolerFactory` is a contract in charge of deploying new coolers for any user who wants to access the lending facility.

The lending facility is called `Clearinghouse`. This smart contract has been built to be integrated with `Olympus V3` and the `Default Framework`. As such, the `Clearinghouse` is a `Policy` that will have permissions to incur debt from the Treasury (to issue the loans), as well as burning OHM (to reduce supply whenever a borrower defaults).

![](/cooler-loans-diagram.svg)

## CoolerFactory.sol
- Keeps track of all the deployed contracts.
- Deploys a new Cooler if the combination of user-debt-collateral doesn't exist yet. Uses clones with immutable arguments to save gas.
- In charge of logging the Cooler events.
## Cooler.sol
- Keeps track of all the requests/loans and their status.
- Escrows the collateral during the lending period.
- Handles clearings, repayments, rollovers and defaults.
- Offers callbacks to the lender after key actions happen.
## Clearinghouse.sol
- Implements the mandate of the Olympus community in OIP-XXX by clearing loans at the governance-approved terms.
- Tracks the outstanding debt and interest that should be received upon repayment.
- Its lending capacity is limited by a `FUND_AMOUTN` and a `FUND_CADENCE`.
- Deposits all its idle DAI into the DSR.

