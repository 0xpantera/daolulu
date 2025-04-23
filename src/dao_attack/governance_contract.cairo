use starknet::ContractAddress;

#[starknet::interface]
pub trait IGovToken<TContractState> {
    fn set_treasury(ref self: TContractState, treasury: ContractAddress);
    fn transfer(ref self: TContractState, to: ContractAddress, amount: u256);
    fn mint(ref self: TContractState, to: ContractAddress, amount: u256);
    fn burn(ref self: TContractState, from: ContractAddress, amount: u256);
    fn create_proposal(
        ref self: TContractState, description: ByteArray, to: ContractAddress, amount: u256,
    );
    fn vote(ref self: TContractState, id: u256, support: bool);
    fn execute(ref self: TContractState, id: u256);
}

#[derive(Drop, Serde, starknet::Store)]
struct Proposal {
    id: u256, // The id of the proposal
    description: ByteArray, // The description of the proposal
    to: ContractAddress, // The address where send funds from treasury
    amount: u256, // The amount to send
    timestamp: u64, // The timestamp of the proposal creation
    yes: u256, // The amount of votes in favor
    no: u256, // The amount of votes against
    executed: bool // Whether the proposal has been executed
}

#[starknet::contract]
mod GovernanceContract {
    use daolulu::dao_attack::treasury::{ITreasuryDispatcher, ITreasuryDispatcherTrait};
    use openzeppelin_token::erc20::{ERC20Component, ERC20HooksEmptyImpl};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePathEntry,
        StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address};
    use super::Proposal;

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        treasury: ContractAddress,
        last_proposal_id: u256,
        voting_power: Map<ContractAddress, u256>,
        proposals: Map<u256, Proposal>,
        voted: Map<ContractAddress, Map<u256, bool>>,
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC20Event: ERC20Component::Event,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        let name = "StarkNet Governance Token";
        let symbol = "STRKToken";
        self.erc20.initializer(name, symbol);
        self.owner.write(owner);
    }

    #[abi(embed_v0)]
    impl STRKTokenImpl of super::IGovToken<ContractState> {
        /// Transfers tokens and updates voting power
        /// @param to - The recipient of the tokens
        /// @param amount - The amount of tokens to transfer
        fn transfer(ref self: ContractState, to: ContractAddress, amount: u256) {
            let caller = get_caller_address();
            self.voting_power.write(caller, self.voting_power.read(caller) - amount);
            self.voting_power.write(to, self.voting_power.read(to) + amount);
            self.erc20._transfer(caller, to, amount);
        }

        /// Mints new tokens and updates voting power
        /// @param to - The recipient of the new tokens
        /// @param amount - The amount of tokens to mint
        fn mint(ref self: ContractState, to: ContractAddress, amount: u256) {
            self.assert_only_owner();
            self.erc20.mint(to, amount);
            let new_amount = self.voting_power.read(to) + amount;
            self.voting_power.write(to, new_amount);
        }

        /// Burns tokens and updates voting power
        /// @param from - The address from which to burn tokens
        /// @param amount - The amount of tokens to burn
        fn burn(ref self: ContractState, from: ContractAddress, amount: u256) {
            self.assert_only_owner();
            self.erc20.burn(from, amount);
            let new_amount = self.voting_power.read(from) - amount;
            self.voting_power.write(from, new_amount);
        }

        /// Creates a new proposal
        /// @param description - The proposal description
        /// @param to - The recipient of the funds if the proposal passes
        /// @param amount - The amount of funds to transfer if the proposal passes
        fn create_proposal(
            ref self: ContractState, description: ByteArray, to: ContractAddress, amount: u256,
        ) {
            assert(description.len() > 0, 'Description cannot be empty');
            self.assert_voting_power();
            self.last_proposal_id.write(self.last_proposal_id.read() + 1);
            let proposal = Proposal {
                id: self.last_proposal_id.read(),
                description: description,
                timestamp: get_block_timestamp(),
                to: to,
                amount: amount,
                yes: self.voting_power.read(get_caller_address()),
                no: 0,
                executed: false,
            };
            self.proposals.write(proposal.id, proposal);
            self.voted.entry(get_caller_address()).write(self.last_proposal_id.read(), true);
        }

        /// Casts a vote on an existing proposal
        /// @param id - The ID of the proposal to vote on
        /// @param support - True for a 'yes' vote, false for a 'no' vote
        fn vote(ref self: ContractState, id: u256, support: bool) {
            // Vote Checks: voting power, not voted, proposal exists, voting period is active
            self.assert_voting_power();
            assert(!self.voted.entry(get_caller_address()).read(id), 'Already voted');
            let mut proposal: Proposal = self.proposals.read(id);
            assert(proposal.id > 0, 'Proposal not found');
            assert(proposal.timestamp + 604800_u64 > get_block_timestamp(), 'Voting period ended');

            // Casting the vote
            let voter_power = self.voting_power.read(get_caller_address());
            if (support) {
                proposal.yes += voter_power;
            } else {
                proposal.no += voter_power;
            }

            // Save the vote of the caller
            self.proposals.write(proposal.id, proposal);
            self.voted.entry(get_caller_address()).write(id, true);
        }

        /// Executes a proposal if it has passed and the voting period has ended
        /// @param id - The ID of the proposal to execute
        fn execute(ref self: ContractState, id: u256) {
            // Porposal Checks: exists, not executed, voting period ended (604800 seconds)
            let mut proposal: Proposal = self.proposals.read(id);
            assert(proposal.id > 0, 'Proposal not found');
            assert(proposal.timestamp + 604800_u64 < get_block_timestamp(), 'Voting period active');
            assert(!proposal.executed, 'Already executed');

            // Proposal Execution
            if (proposal.yes > proposal.no) {
                ITreasuryDispatcher { contract_address: self.treasury.read() }
                    .proposal_execution(proposal.to, proposal.amount);
            }
            proposal.executed = true;
            self.proposals.write(proposal.id, proposal);
        }

        /// Sets the treasury address (can only be called once)
        /// @param treasury - The address of the treasury contract
        fn set_treasury(ref self: ContractState, treasury: ContractAddress) {
            self.assert_only_owner();
            assert(self.treasury.read() == 0.try_into().unwrap(), 'Treasury already set');
            self.treasury.write(treasury);
        }
    }

    // Private trait
    #[generate_trait]
    impl PrivateImpl of PrivateTrait {
        /// Ensures the caller is the contract owner
        fn assert_only_owner(self: @ContractState) {
            let owner = self.owner.read();
            let caller = get_caller_address();
            assert(owner == caller, 'Only owner can do this');
        }

        /// Ensures the caller has voting power
        fn assert_voting_power(self: @ContractState) {
            let caller = get_caller_address();
            assert(self.voting_power.read(caller) > 0, 'No voting power');
        }
    }
}
