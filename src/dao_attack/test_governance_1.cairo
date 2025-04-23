use daolulu::dao_attack::governance_contract::{IGovTokenDispatcher, IGovTokenDispatcherTrait};
use daolulu::dao_attack::treasury::{ITreasuryDispatcher, ITreasuryDispatcherTrait};
use daolulu::utils::helpers;
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp_global,
    start_cheat_caller_address, stop_cheat_caller_address,
};
use starknet::ContractAddress;

fn deploy_strk() -> (ContractAddress, IGovTokenDispatcher) {
    let contract_class = declare("GovernanceContract").unwrap().contract_class();
    let mut data_to_constructor = Default::default();
    let deployer: ContractAddress = 123.try_into().unwrap();
    Serde::serialize(@deployer, ref data_to_constructor);
    let (address, _) = contract_class.deploy(@data_to_constructor).unwrap();
    (address, IGovTokenDispatcher { contract_address: address })
}

fn deploy_treasury(
    strk: ContractAddress, eth: ContractAddress,
) -> (ContractAddress, ITreasuryDispatcher) {
    let contract_class = declare("Treasury").unwrap().contract_class();
    let mut data_to_constructor = Default::default();
    Serde::serialize(@strk, ref data_to_constructor);
    Serde::serialize(@eth, ref data_to_constructor);
    let (address, _) = contract_class.deploy(@data_to_constructor).unwrap();
    (address, ITreasuryDispatcher { contract_address: address })
}

#[test]
fn test_governance_1() {
    // Users
    let alice: ContractAddress = 1.try_into().unwrap();
    let bob: ContractAddress = 2.try_into().unwrap();
    let attacker: ContractAddress = 3.try_into().unwrap();
    let deployer: ContractAddress = 123.try_into().unwrap();

    // Deploying the contracts
    let (strk_address, strk_dispatcher) = deploy_strk();
    let (eth_address, eth_dispatcher) = helpers::deploy_eth();
    let (treasury_address, _) = deploy_treasury(strk_address, eth_address);

    // Set treasury and mint STRK to users
    start_cheat_caller_address(strk_address, deployer);
    strk_dispatcher.set_treasury(treasury_address);
    strk_dispatcher.mint(alice, helpers::one_ether() * 100);
    strk_dispatcher.mint(bob, helpers::one_ether() * 100);
    strk_dispatcher.mint(attacker, helpers::one_ether() * 100);
    stop_cheat_caller_address(strk_address);

    // Minting ETH to treasury
    helpers::mint_erc20(eth_address, treasury_address, helpers::one_ether() * 100);

    // Set the timestamp
    start_cheat_block_timestamp_global(1);

    // Attacker creates a proposal to transfer all ETH from treasury
    start_cheat_caller_address(strk_address, attacker);
    strk_dispatcher
        .create_proposal(
            "Very legit proposal", attacker, eth_dispatcher.balance_of(treasury_address),
        );
    stop_cheat_caller_address(strk_address);

    // Voting "No" on the proposal from Alice and Bob
    let voters = array![alice, bob];
    let mut i = 0;
    loop {
        if i >= voters.len() {
            break;
        }
        let voter = *voters.at(i);
        start_cheat_caller_address(strk_address, voter);
        strk_dispatcher.vote(1, false);
        stop_cheat_caller_address(strk_address);
        i += 1;
    }

    // ATTACK START //
    // TODO: Steal all ETH from treasury to the Attacker

    // ATTACK END //

    // Check if the exploit was successful
    let treasury_balance = eth_dispatcher.balance_of(treasury_address);
    assert_eq!(treasury_balance, 0, "Treasury should be empty");

    // Check attackers balance
    let attacker_balance = eth_dispatcher.balance_of(attacker);
    assert_eq!(attacker_balance, helpers::one_ether() * 100, "Attacker should have all the ETH");
}
