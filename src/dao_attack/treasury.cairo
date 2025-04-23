// Library imports
use starknet::ContractAddress;

#[starknet::interface]
pub trait ITreasury<TContractState> {
    fn proposal_execution(ref self: TContractState, to: ContractAddress, amount: u256);
}

#[starknet::contract]
mod Treasury {
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ContractAddress, get_caller_address};

    #[storage]
    struct Storage {
        strk_token: ContractAddress,
        eth_token: ContractAddress,
    }

    /// Initializes the Treasury contract with STRK and ETH token addresses
    /// @param strk_token_address: The address of the STRK token contract
    /// @param eth_token_address: The address of the ETH token contract
    #[constructor]
    fn constructor(
        ref self: ContractState,
        strk_token_address: ContractAddress,
        eth_token_address: ContractAddress,
    ) {
        self.strk_token.write(strk_token_address);
        self.eth_token.write(eth_token_address);
    }

    #[abi(embed_v0)]
    impl ITreasuryImpl of super::ITreasury<ContractState> {
        /// Executes a proposal by transferring ETH tokens to the specified address
        /// @param to: The recipient address for the token transfer
        /// @param amount: The amount of ETH tokens to transfer
        /// @dev This function can only be called by the STRK token contract
        fn proposal_execution(ref self: ContractState, to: ContractAddress, amount: u256) {
            let strk_token = self.strk_token.read();
            assert(get_caller_address() == strk_token, 'only STRK can execute');
            let eth_token = self.eth_token.read();
            let dispatcher = IERC20Dispatcher { contract_address: eth_token };
            dispatcher.transfer(to, amount);
        }
    }
}
