# Known Issues

## Rounding Errors Cause No APR Difference for Durations with a Difference of Less Than 85 Minutes

### Description
Due to rounding errors in the `_getFragmentsAPR` function, there is no differences in the calculated APRs for durations with a difference of less than 85 minutes.

### Impact
The APR differences may not accurately reflect the actual staking durations for periods less than 85 minutes apart.

### Resolution
APR precision of 0.01% increments is deemed sufficient for all intents and purposes.


## Inadequate Rewards Check in `unstakeAndClaim` Function

### Description
In the `unstakeAndClaim` function, if the stake duration has passed, rewards are transferred to the user. Otherwise, rewards are forfeited back to the contract. The issue arises when the contract does not have any available rewards, causing an unfair restriction on the user.

### Scenario
User A stakes an amount for 1 year. After 6 months, User A has earned some rewards, but the contract has no available rewards. Currently, User A is forced to keep staking for another 6 months unnecessarily.

### Impact
Potential waiting period without rewards before unstaking when the contract has no available rewards.

### Resolution
Users can freely choose the commitment period. 
The remaining PSM available for distribution is public knowledge and retrievable from the contract. 
Users are responsible to choose their commitment period in line with their expectations of reward potential.
