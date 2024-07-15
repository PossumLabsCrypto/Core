# Known Issues

## Rounding Errors Cause No APR Difference for Durations with a Difference of Less Than 85 Minutes

### Description
Due to rounding errors in the `_getFragmentsAPR` function, there is no differences in the calculated APRs for durations with a difference of less than 85 minutes. This can lead to unfair distribution of rewards.

### Impact
This issue results in unfair distribution of rewards, as the APR differences may not accurately reflect the actual staking durations for periods less than 85 minutes apart.

### Proof of Concept (PoC)
To illustrate the issue, change the `_getFragmentsAPR` function to a public function and add the following test:
`solidity function test_apr2(uint256 duration, int256 min) public { `
`   vm.assume(duration > 1 && duration < 60 * 60 * 24 * 365);`
`   vm.assume(min > 5120);`
`   if ((uint256(min) + duration) < 60 * 60 * 24 * 365) { `
`       uint256 amount = 1e18;`
`       uint256 apr1 = coreContract._getFragmentsAPR(0, amount, duration, 0);`
`       duration += uint256(min); uint256 apr2 = coreContract._getFragmentsAPR(0, amount, duration, 0);`
`       assertNotEq(apr1, apr2); `
`   } `
`}`

### Mitigation
To mitigate this issue, increase the precision of the APR calculations by adjusting the constants used in the function. Specifically, add one more digit to the following variables:
- `uint256 public constant MAX_APR = 7200;` // Accrual rate of CF at maximum stake duration (10000 = 100%)
- `uint256 public constant MIN_APR = 1200;` // Accrual rate of CF at stake duration = 0 (10000 = 100%)
- `uint256 private constant APR_SCALING = 10000;`
+ `uint256 public constant MAX_APR = 72_000;` // Accrual rate of CF at maximum stake duration (100,000 = 100%)
+ `uint256 public constant MIN_APR = 12_000;` // Accrual rate of CF at stake duration = 0 (100,000 = 100%)
+ `uint256 private constant APR_SCALING = 100_000;`
By increasing the precision of these variables, the APR calculations will become more accurate, resulting in fairer reward distributions for all stakers.



## Inadequate Rewards Check in `unstakeAndClaim` Function

### Description
In the `unstakeAndClaim` function, if the stake duration has passed, rewards are transferred to the user. Otherwise, rewards are forfeited back to the contract. The issue arises when the contract does not have any available rewards, causing an unfair restriction on the user.

### Scenario
User A stakes an amount for 1 year. After 6 months, User A has earned some rewards, but the contract has no available rewards. Currently, User A is forced to keep staking for another 6 months unnecessarily.

### Impact
Unnecessary locking of user funds when the contract has no available rewards.

### Mitigation
Implement a check for available rewards, and if the available rewards are zero, bypass the stake duration check. However, this approach introduces two potential issues:

1. **Frontrunning Attack**: An attacker could send a small amount of rewards to the contract before the transaction, causing the user to lose their rewards.
   - **Mitigation**:
     a. Add a new input parameter `(minReceived)`
     b. Check `getAvailableTokens` against a higher threshold (e.g., 10,000 tokens) instead of zero (the attacker needs to send at least $10 in each front run).

2. **Abuse of Bypass Feature**: A user could stake for the maximum duration (highest APR) towards the end of the contract's rewards availability to exploit the system.
   - **Mitigation**: Ensure the user has staked for at least half of the period before allowing the bypass.
