use starknet::storage::Vec;
use starknet::{ClassHash, ContractAddress};

#[allow(starknet::store_no_default_variant)]
#[derive(Drop, Serde, starknet::Store)]
pub enum ProposalType {
    UPGRADE, // To upgrade the contract
    TREASURY // To transfer funds
}

#[starknet::storage_node]
struct VotingToken {
    id: u256, // Token ID
    owner: ContractAddress, // Token owner
    amount: u256, // Token amount
    created_in_epoch: u64 // Epoch of token creation (user deposited assets)
}

#[starknet::storage_node]
struct Proposal {
    id: u256, // Proposal ID
    created: u64, // Proposal creation time
    description: ByteArray, // Proposal description
    proposal_type: ProposalType, // Proposal type
    data: Vec<felt252>, // Contains params for proposal execution
    yes: u256, // Yes votes
    no: u256, // No votes
    executed: bool // Proposal execution status
}

#[starknet::interface]
pub trait IVoting<TState> {
    fn lock_tokens(ref self: TState, amount: u256) -> u256;
    fn unlock_tokens(ref self: TState, token_id: u256);
    fn vote(ref self: TState, proposal_id: u256, token_id: u256, voting_for: bool);
    fn create_proposal(
        ref self: TState,
        description: ByteArray,
        proposal_type: ProposalType,
        data: Span<felt252>,
        token_id: u256,
    ) -> u256;
    fn execute_proposal(ref self: TState, proposal_id: u256);
    fn merge(ref self: TState, token_from: u256, token_to: u256);
    fn split(ref self: TState, token_id: u256, amounts: Span<felt252>) -> Span<felt252>;
}

#[starknet::interface]
pub trait IUpgrade<TState> {
    fn upgrade(ref self: TState, class_hash: ClassHash);
}

#[starknet::contract]
mod VotingContract {
    use core::traits::Default;
    use daolulu::gov_attack::governance::{IGovernanceDispatcher, IGovernanceDispatcherTrait};
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{
        Map, MutableVecTrait, StorageMapReadAccess, StorageMapWriteAccess, StoragePathEntry,
        StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{
        ClassHash, ContractAddress, get_block_timestamp, get_caller_address, get_contract_address,
        syscalls,
    };
    use super::{Proposal, ProposalType, VotingToken};

    const ONE_WEEK: u64 = 604_800; // 1 Week
    const ONE_DAY: u64 = 86_400; // 1 Day

    #[storage]
    struct Storage {
        token_id_counter: u256, // Voting token ID counter
        proposal_id_counter: u256, // Proposal ID counter
        proposals: Map<u256, Proposal>, // Proposal ID -> Proposal
        voting_tokens: Map<u256, VotingToken>, // Voting token ID -> VotingToken Struct
        voted_in_epoch: Map<u256, u64>, // Voting token ID -> Voted epoch
        voted_for_proposal: Map<u256, Map<u256, bool>>, // Voting token ID -> Proposal ID -> Voted
        initial_timestamp: u64, // Timestamp for correct EPOCH_WORK
        gov_token: IERC20Dispatcher, // Governance token
        governance: ContractAddress // Governnce contract
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        gov_token_address: ContractAddress,
        governance_address: ContractAddress,
    ) {
        self.gov_token.write(IERC20Dispatcher { contract_address: gov_token_address });
        self.initial_timestamp.write(get_block_timestamp());
        self.governance.write(governance_address);
    }

    #[abi(embed_v0)]
    impl VotingImpl of super::IVoting<ContractState> {
        /// Locks governance tokens and mints a new voting token
        /// @param amount - amount of governance tokens to lock
        /// @return The ID of the newly minted voting token
        fn lock_tokens(ref self: ContractState, amount: u256) -> u256 {
            let caller = get_caller_address();
            self.gov_token.read().transfer_from(caller, get_contract_address(), amount);

            let token_id = self.token_id_counter.read() + 1;
            self.token_id_counter.write(token_id);

            let mut voting_token = self.voting_tokens.entry(token_id);
            voting_token.id.write(token_id);
            voting_token.owner.write(caller);
            voting_token.amount.write(amount);
            voting_token.created_in_epoch.write(self.current_epoch());

            token_id
        }

        /// Unlocks governance tokens and burns the voting token
        /// @param token_id - ID of the voting token to unlock
        fn unlock_tokens(ref self: ContractState, token_id: u256) {
            let mut voting_token = self.voting_tokens.entry(token_id);
            let caller = get_caller_address();
            assert(voting_token.owner.read() == caller, 'Not owner');
            assert(
                self.voted_in_epoch.read(token_id) < self.current_epoch(), 'Voted in this epoch',
            );

            self.gov_token.read().transfer(caller, voting_token.amount.read());

            // Burn the token
            voting_token.owner.write(0.try_into().unwrap());
            voting_token.amount.write(0);
        }

        /// Creates a new proposal
        /// @param description - Description of the proposal
        /// @param proposal_type - Type of the proposal (UPGRADE or TREASURY)
        /// @param data - Data for proposal execution
        /// @param token_id - ID of the voting token used to create the proposal
        /// @return The ID of the newly created proposal
        fn create_proposal(
            ref self: ContractState,
            description: ByteArray,
            proposal_type: ProposalType,
            data: Span<felt252>,
            token_id: u256,
        ) -> u256 {
            // Only allow proposal creation in the first day of the epoch
            assert(
                self.epoch_start_time() + ONE_DAY > get_block_timestamp(),
                'Allowed just in first day',
            );
            assert(data.len() >= 2, 'Data should have 2 elements');

            // Get an ID
            let proposal_id = self.proposal_id_counter.read() + 1;
            self.proposal_id_counter.write(proposal_id);

            let mut proposal = self.proposals.entry(proposal_id);
            let mut voting_token = self.voting_tokens.entry(token_id);
            assert(voting_token.owner.read() == get_caller_address(), 'Not owner');

            // The proposal data
            proposal.id.write(proposal_id);
            proposal.description.write(description);
            proposal.proposal_type.write(proposal_type);
            proposal.yes.write(voting_token.amount.read());
            proposal.no.write(0);
            proposal.created.write(self.current_epoch());
            for i in 0..data.len() {
                proposal.data.append().write(*data.at(i));
            }

            self.voted_for_proposal.entry(token_id).write(proposal_id, true);
            self.voted_in_epoch.write(token_id, self.current_epoch());

            proposal_id
        }

        /// Casts a vote for a proposal
        /// @param proposal_id - ID of the proposal to vote on
        /// @param token_id - ID of the voting token to use
        /// @param voting_for - True if voting in favor, false if voting against
        fn vote(ref self: ContractState, proposal_id: u256, token_id: u256, voting_for: bool) {
            let mut proposal = self.proposals.entry(proposal_id);
            let voting_token = self.voting_tokens.entry(token_id);

            // Voting requirements:
            // 1. The voting token must be owned by the caller
            // 2. The proposal must exist
            // 3. The voting period must have started
            // 4. The caller must not have voted for this proposal
            // 5. The voting token must have been created in a previous epoch
            assert(proposal.id.read() != 0, 'Not existing proposal');
            assert(proposal.created.read() == self.current_epoch(), 'Voting expired');
            assert(
                voting_token.owner.read() == get_caller_address(), 'Not owner of the voting token',
            );
            assert(
                !self.voted_for_proposal.entry(token_id).read(proposal_id),
                'Already voted with this token',
            );
            assert!(
                voting_token.created_in_epoch.read() < self.current_epoch(),
                "Can not vote with tokens created in the current epoch",
            );

            // Save the vote
            if voting_for {
                proposal.yes.write(proposal.yes.read() + voting_token.amount.read());
            } else {
                proposal.no.write(proposal.no.read() + voting_token.amount.read());
            }

            self.voted_for_proposal.entry(token_id).write(proposal_id, true);
            self.voted_in_epoch.write(token_id, self.current_epoch());
        }

        /// Executes a proposal if it has passed
        /// @param proposal_id - ID of the proposal to execute
        fn execute_proposal(ref self: ContractState, proposal_id: u256) {
            // Requirements:
            // 1. The proposal must exist
            // 2. The proposal must have been created in a previous epoch
            // 3. The proposal must not have been executed
            // 4. The proposal must have more yes votes than no votes
            let mut proposal = self.proposals.entry(proposal_id);
            assert(proposal.id.read() != 0, 'Not existing proposal');
            assert(proposal.created.read() < self.current_epoch(), 'Epoch is not over');
            assert(!proposal.executed.read(), 'Already executed');

            if (proposal.yes.read() > proposal.no.read()) {
                let proposal_type = proposal.proposal_type.read();

                let mut data = array![];
                for i in 0..proposal.data.len() {
                    data.append(proposal.data[i].read());
                }

                let gov_dispatcher = IGovernanceDispatcher {
                    contract_address: self.governance.read(),
                };
                match proposal_type {
                    ProposalType::UPGRADE => gov_dispatcher.execute(data.span()),
                    ProposalType::TREASURY => gov_dispatcher.transfer_funds(data.span()),
                }
            }

            proposal.executed.write(true);
        }

        fn merge(
            ref self: ContractState, token_from: u256, token_to: u256,
        ) { // TODO: Implemented in the next version
        }

        /// Splits a voting token into multiple new tokens
        /// @param token_id - ID of the token to split
        /// @param amounts - Amounts for the new tokens
        /// @return An array of new token IDs
        fn split(ref self: ContractState, token_id: u256, amounts: Span<felt252>) -> Span<felt252> {
            let voting_token = self.voting_tokens.entry(token_id);
            let caller = get_caller_address();

            // Requirements:
            // 1. The voting token must be owned by the caller
            // 2. The minimum number of amounts is 2
            assert(voting_token.owner.read() == caller, 'Not owner');
            assert(amounts.len() >= 2, 'Minimum 2 amounts');

            let mut new_tokens = array![];

            // Create new voting tokens
            let mut sum: u256 = 0;

            // Iterate over all amounts, create new voting tokens and sum the amounts
            for i in 0..amounts.len() {
                let amount: u256 = (*amounts.at(i)).into();
                let new_token_id = self.token_id_counter.read() + 1;
                self.token_id_counter.write(new_token_id);

                let mut new_voting_token = self.voting_tokens.entry(new_token_id);
                new_voting_token.id.write(new_token_id);
                new_voting_token.owner.write(caller);
                new_voting_token.amount.write(amount);
                new_voting_token.created_in_epoch.write(self.current_epoch());
                sum += amount;

                let id_felt: felt252 = new_token_id.try_into().unwrap();
                new_tokens.append(id_felt);
            }
            // Sum of all amounts needs to match the amount of the original token
            assert(sum == voting_token.amount.read(), 'Wrong sum');

            // Burn the original token
            voting_token.owner.write(0.try_into().unwrap());
            voting_token.amount.write(0);

            // Return new ids
            new_tokens.span()
        }
        // Transfering has not been implemented yet
    }

    #[abi(embed_v0)]
    impl Upgrade of super::IUpgrade<ContractState> {
        /// Upgrades the contract
        /// @param class_hash - The new class hash to upgrade to
        fn upgrade(ref self: ContractState, class_hash: ClassHash) {
            self.assert_governance();
            syscalls::replace_class_syscall(class_hash).unwrap();
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        // Calculates the current epoch
        fn current_epoch(self: @ContractState) -> u64 {
            let current_epoch: u64 = (get_block_timestamp() - self.initial_timestamp.read())
                / ONE_WEEK;
            current_epoch
        }

        // Calculates the starting timestamp of the current epoch
        fn epoch_start_time(self: @ContractState) -> u64 {
            let timestamp = self.current_epoch() * ONE_WEEK + self.initial_timestamp.read();
            timestamp
        }

        /// Checks if the caller is the governance contract
        fn assert_governance(self: @ContractState) {
            assert(self.governance.read() == get_caller_address(), 'Not governance');
        }
    }
}
