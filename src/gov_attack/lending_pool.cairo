#[starknet::interface]
trait IFlashLoanReceiver<TContractState> {
    fn callback(ref self: TContractState, borrow_amount: u256);
}

#[starknet::interface]
pub trait ILendingPool<TContractState> {
    fn flash_loan(ref self: TContractState, borrow_amount: u256);
}

#[starknet::contract]
mod LendingPool {
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use super::{IFlashLoanReceiverDispatcher, IFlashLoanReceiverDispatcherTrait};

    #[storage]
    struct Storage {
        gov_token: IERC20Dispatcher,
    }

    #[constructor]
    fn constructor(ref self: ContractState, gov_token_address: ContractAddress) {
        self.gov_token.write(IERC20Dispatcher { contract_address: gov_token_address });
    }

    #[abi(embed_v0)]
    impl LendingPoolImpl of super::ILendingPool<ContractState> {
        // Executes a flash loan without fees
        // @param borrow_amount - The amount of tokens to borrow
        // Note: will panic if not returned, or if not enough balance
        fn flash_loan(ref self: ContractState, borrow_amount: u256) {
            let balance_before = self.gov_token.read().balance_of(get_contract_address());
            assert(balance_before >= borrow_amount, 'Too much');

            // Transfering the assets and making the callback
            let caller = get_caller_address();
            self.gov_token.read().transfer(caller, borrow_amount);
            IFlashLoanReceiverDispatcher { contract_address: caller }.callback(borrow_amount);

            // Make sure the assets are returned
            let balance_after = self.gov_token.read().balance_of(get_contract_address());
            assert(balance_after >= balance_before, 'Not returned assets');
        }
    }
}
