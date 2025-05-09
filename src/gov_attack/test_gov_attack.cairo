use daolulu::gov_attack::governance::{IGovernanceDispatcher, IGovernanceDispatcherTrait};
use daolulu::gov_attack::lending_pool::{ILendingPoolDispatcher, ILendingPoolDispatcherTrait};
use daolulu::gov_attack::voting_contract::{IVotingDispatcher, IVotingDispatcherTrait};
use daolulu::utils::helpers;
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp_global,
    start_cheat_caller_address, stop_cheat_caller_address,
};
use starknet::ContractAddress;
use daolulu::gov_attack::shaftoe::{IShaftoeDispatcher, IShaftoeDispatcherTrait};


fn deploy_governance() -> (ContractAddress, IGovernanceDispatcher) {
    let contract_class = declare("Governance").unwrap().contract_class();
    let (address, _) = contract_class.deploy(@array![]).unwrap();
    (address, IGovernanceDispatcher { contract_address: address })
}

fn deploy_lending_pool(gov_token: ContractAddress) -> (ContractAddress, ILendingPoolDispatcher) {
    let contract_class = declare("LendingPool").unwrap().contract_class();
    let (address, _) = contract_class.deploy(@array![gov_token.into()]).unwrap();
    (address, ILendingPoolDispatcher { contract_address: address })
}

fn deploy_voting_contract(
    gov_token: ContractAddress, governance_address: ContractAddress,
) -> (ContractAddress, IVotingDispatcher) {
    let contract_class = declare("VotingContract").unwrap().contract_class();
    let (address, _) = contract_class
        .deploy(@array![gov_token.into(), governance_address.into()])
        .unwrap();
    (address, IVotingDispatcher { contract_address: address })
}

fn deploy_shaftoe(
    jack: ContractAddress, 
    lender: ContractAddress, 
    voting: IVotingDispatcher,
    gov_token: ContractAddress,
) -> (ContractAddress, IShaftoeDispatcher) {
    let contract_class = declare("Shaftoe").unwrap().contract_class();
    let mut calldata: Array<felt252> = array![];
    Serde::serialize(@jack, ref calldata);
    Serde::serialize(@lender, ref calldata);
    Serde::serialize(@voting, ref calldata);
    Serde::serialize(@gov_token, ref calldata);
    let (address, _) = contract_class
        .deploy(@calldata)
        .unwrap();
    (address, IShaftoeDispatcher { contract_address: address })
}

#[test]
fn test_gov_attack() {
    let decimals: u256 = 1_000_000_000_000_000_000;
    let one_week: u64 = 604_800;

    // Users
    let alice: ContractAddress = 1.try_into().unwrap();
    let bob: ContractAddress = 2.try_into().unwrap();
    let attacker: ContractAddress = 3.try_into().unwrap();
    let deployer: ContractAddress = 123.try_into().unwrap();

    // Contracts Deployments
    let (gov_token_address, gov_token_dispatcher) = helpers::deploy_erc20(
        "Governance token", "GOVToken",
    );
    let (eth_address, eth_dispatcher) = helpers::deploy_eth();
    let (lending_pool_address, _) = deploy_lending_pool(gov_token_address);
    let (governance_address, governance_dispatcher) = deploy_governance();
    let (voting_contract_address, voting_contract_dispatcher) = deploy_voting_contract(
        gov_token_address, governance_address,
    );

    // Init the governance contract
    start_cheat_caller_address(governance_address, deployer);
    governance_dispatcher.init(eth_address, voting_contract_address);
    stop_cheat_caller_address(governance_address);

    // Set timestamp to some value
    start_cheat_block_timestamp_global(1000);

    // Minting ETH to treasury
    helpers::mint_erc20(eth_address, governance_address, helpers::one_ether() * 1000);

    // Minting Gov token to users and lending pool
    helpers::mint_erc20(gov_token_address, lending_pool_address, 100_000_000 * decimals);
    helpers::mint_erc20(gov_token_address, alice, 10000 * decimals);
    helpers::mint_erc20(gov_token_address, bob, 20000 * decimals);

    // Alice & Bob approve the voting contract to spend their tokens
    start_cheat_caller_address(gov_token_address, alice);
    gov_token_dispatcher.approve(voting_contract_address, 10000 * decimals);
    stop_cheat_caller_address(gov_token_address);
    start_cheat_caller_address(gov_token_address, bob);
    gov_token_dispatcher.approve(voting_contract_address, 20000 * decimals);
    stop_cheat_caller_address(gov_token_address);

    // Alice & Bob lock their tokens to get voting rights
    start_cheat_caller_address(voting_contract_address, alice);
    let alice_token = voting_contract_dispatcher.lock_tokens(10000 * decimals);
    stop_cheat_caller_address(voting_contract_address);
    start_cheat_caller_address(voting_contract_address, bob);
    let bob_token = voting_contract_dispatcher.lock_tokens(20000 * decimals);
    stop_cheat_caller_address(voting_contract_address);

    // Skip to the next epoch
    start_cheat_block_timestamp_global(2000 + one_week);

    // Attack Start //
    // TODO: Steal all ETH from governance contract
    let (_shaftoe_address, shaftoe_dispatcher) = deploy_shaftoe(
        attacker,
        lending_pool_address,
        voting_contract_dispatcher,
        gov_token_address
    );
    println!("deployed shaftoe");

    shaftoe_dispatcher.attack();

    // Attack End //

    // Users vote against
    start_cheat_caller_address(voting_contract_address, alice);
    voting_contract_dispatcher.vote(1, alice_token, false);
    stop_cheat_caller_address(voting_contract_address);

    start_cheat_caller_address(voting_contract_address, bob);
    voting_contract_dispatcher.vote(1, bob_token, false);
    stop_cheat_caller_address(voting_contract_address);

    // Move to the next epoch
    start_cheat_block_timestamp_global(2000 + (one_week * 2));

    // Trying to execute proposal 1 (Assuming it was created)
    voting_contract_dispatcher.execute_proposal(1);

    // The governance contract should have 0 ETH
    let governance_eth_balance = eth_dispatcher.balance_of(governance_address);
    assert(governance_eth_balance == 0, 'Governance should have 0 ETH');

    // The attacker should have stolen all the ETH
    println!("Attacker Balance: {}", eth_dispatcher.balance_of(attacker));
    let attacker_eth_balance = eth_dispatcher.balance_of(attacker);
    assert(attacker_eth_balance == helpers::one_ether() * 1000, 'Attacker should have stolen ETH');
}
