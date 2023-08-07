# Cooler Loans Review

## Overall

- Needs more detail on the contract flows, as there's a lot of back and forth
- Many of the functions are missing the `@return` natspec comment

## Cooler Factory

- Needs deployment scripts to ensure that it will be deployed with the correct parameters

## ClearingHouse

- Add note that ownership transfer is disabled for this implementation
- Add contract-level documentation: what it does, etc
- rebalance
  - `balance` should be clear that it is denominated in DAI
  - `amount`` should be clear that it is the sDAI withdrawal amount (shares)
- lendToCooler
  - Called by frontend. Should document this.
  - Can there be multiple open requests?
  - Cooler.clearRequest should be named fulfilled to be more intuitive. The event should be named consistently too.
  - Can Cooler.loans and ClearingHouse.receivables get out of sync? Different interest calculations
- rollover
  - loan.expiry adds duration to the previous value. Shouldn't it be duration from the current time? Document this behaviour.
  - loan.amount = req.amount + interest. When rolling over, request amount will be loan.amount. Needs to be documented.
  - Should have event for rollover
- claimDefaulted
  - No incentive for users to call. Needs a keeper, similar to the Heart. Good to keep separate to Cooler, otherwise we would need to give minting permissions
  - Why pass coolers and loans as parameters? How will this info be assembled? Should be easier/convenience method.
  - Should emit event
