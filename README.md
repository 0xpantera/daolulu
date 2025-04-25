# DAO Governance Attacks

This project demonstrates common vulnerabilities in DAO governance systems. It contains two practical examples of governance attacks that could be executed against DAOs with vulnerable designs.

## Overview

The repository includes two main attack demonstrations:

1. **Token Transfer Attack** (`dao_attack/`) - Exploits a vulnerability in the DAO's voting mechanism
2. **Flash Loan Attack** (`gov_attack/`) - Demonstrates how flash loans can be used to temporarily gain voting power

Both attacks highlight the importance of careful design in governance systems to prevent malicious actors from manipulating voting outcomes.

## Attack #1: Token Transfer and Sybil Attack

Located in the `dao_attack/` directory, this attack exploits a vulnerability in the DAO's voting mechanism that allows an attacker to vote multiple times using the same governance tokens.

### Vulnerability

The key issue lies in the governance contract's implementation of the transfer function:

```cairo
fn transfer(ref self: ContractState, to: ContractAddress, amount: u256) {
    let caller = get_caller_address();
    self.voting_power.write(caller, self.voting_power.read(caller) - amount);
    self.voting_power.write(to, self.voting_power.read(to) + amount);
    self.erc20._transfer(caller, to, amount);
}
```

The contract properly updates voting power when tokens are transferred, but it does not track that the same tokens are being used for multiple votes.

### Attack Method

1. Attacker creates a proposal to drain funds from the treasury
2. Attacker transfers all their tokens to a first sybil wallet
3. First sybil wallet votes "yes" on the proposal
4. First sybil wallet transfers all tokens to a second sybil wallet
5. Second sybil wallet votes "yes" on the proposal
6. Repeat as necessary to accumulate enough "yes" votes
7. Execute the proposal after the voting period

This attack succeeds because the contract doesn't track that tokens have already been used for voting when they're transferred to a new address.

## Attack #2: Flash Loan Governance Attack

Located in the `gov_attack/` directory, this attack demonstrates how flash loans can be used to temporarily gain voting power and execute malicious governance actions.

### Vulnerability

The voting system doesn't properly verify the long-term commitment of token holders. It allows tokens to be used to create and vote on proposals without sufficient lockup periods.

### Attack Method

The attack is implemented in the `Shaftoe` contract's `callback` method:

1. Attacker borrows a large amount of governance tokens through a flash loan
2. Within the same transaction:
   - Approves the voting contract to spend the tokens
   - Locks the tokens to get voting rights
   - Creates a malicious proposal that will transfer funds to the attacker
   - Uses a token splitting technique to bypass the voting restriction
   - Returns the borrowed tokens to complete the flash loan
3. The proposal passes despite legitimate token holders voting against it
4. Attacker executes the proposal and drains funds

The key insight in this attack is using the `split` function to create new token IDs that don't have the voting restriction, allowing the attacker to unlock and return the borrowed tokens.

## Security Recommendations

To prevent these attacks, DAO developers should:

1. **Implement token locking during voting periods** - Tokens used for voting should be locked until voting ends
2. **Add timelock requirements** - Require tokens to be held for a minimum period before voting rights are granted
3. **Use snapshots for voting power** - Take voting power snapshots at proposal creation time
4. **Implement voting delegation** - Allow token holders to delegate voting power without transferring tokens
5. **Add proposal thresholds** - Require minimum ownership periods and token amounts for proposal creation

## Running the Tests

The project uses Starknet Foundry for testing. You can run the tests with:

```bash
scarb test
```

This will execute both attack demonstrations and verify that they successfully exploit the vulnerabilities.

## Disclaimer

This code is provided for educational purposes only. It demonstrates vulnerabilities that have been found in real-world DAO systems. Do not use this code in production systems.
