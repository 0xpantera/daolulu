use starknet::ContractAddress;

#[starknet::interface]
pub trait IGovernance<TContractState> {
    fn init(
        ref self: TContractState,
        eth_address: ContractAddress,
        voting_contract_address: ContractAddress,
    );
    fn execute(ref self: TContractState, data: Span<felt252>);
    fn transfer_funds(ref self: TContractState, data: Span<felt252>);
}

#[starknet::contract]
mod Governance {
    use core::num::traits::Zero;
    use daolulu::gov_attack::voting_contract::{IUpgradeDispatcher, IUpgradeDispatcherTrait};
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ClassHash, ContractAddress, get_caller_address};

    #[storage]
    struct Storage {
        voting_contract: ContractAddress,
        eth: IERC20Dispatcher,
    }

    #[abi(embed_v0)]
    impl GovernanceImpl of super::IGovernance<ContractState> {
        // Initializes the contract
        // @param eth_address - The address of the ETH contract
        // @param voting_contract_address - The address of the voting contract
        fn init(
            ref self: ContractState,
            eth_address: ContractAddress,
            voting_contract_address: ContractAddress,
        ) {
            assert(self.eth.read().contract_address.is_zero(), 'Already set');
            assert(self.voting_contract.read().is_zero(), 'Already set');
            self.eth.write(IERC20Dispatcher { contract_address: eth_address });
            self.voting_contract.write(voting_contract_address);
        }

        // Executes an upgrade proposal, can only be called by the voting contract
        // @param data - At least two elements: address, class hash and potentially params for init
        // function
        fn execute(ref self: ContractState, data: Span<felt252>) {
            self.assert_voting_contract();
            assert(data.len() >= 2, 'Wrong number of elements');
            let address: ContractAddress = (*data.at(0))
                .try_into()
                .unwrap(); // The first element is an address
            let class_hash: ClassHash = (*data.at(1))
                .try_into()
                .unwrap(); // The second element is a class hash
            IUpgradeDispatcher { contract_address: address }.upgrade(class_hash);
        }

        // Transfers ETH to an address, can only be called by the voting contract
        // @param data - Two elements: address and amount
        fn transfer_funds(ref self: ContractState, data: Span<felt252>) {
            self.assert_voting_contract();
            assert(data.len() == 2, 'Wrong number of elements');
            let address: ContractAddress = (*data.at(0))
                .try_into()
                .unwrap(); // The first element is an address
            let amount: u256 = (*data.at(1))
                .into(); // The second element is the amount of tokens to be transferred
            self.eth.read().transfer(address, amount);
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        // Asserts that the caller is the voting contract
        fn assert_voting_contract(self: @ContractState) {
            assert(get_caller_address() == self.voting_contract.read(), 'Not voting contract');
        }
    }
}
