use starknet::class_hash::ClassHash;
use starknet::ContractAddress;

#[starknet::interface]
trait IDomainGift<TContractState> {
    fn get_domain_gift(ref self: TContractState, id: u128, domain: felt252);

    // admin functions
    fn enable(ref self: TContractState);
    fn disable(ref self: TContractState);
    fn withdraw(
        ref self: TContractState, erc20_addr: ContractAddress, target_addr: ContractAddress
    );
}

#[starknet::contract]
mod DomainGift {
    use starknet::{
        ContractAddress, get_contract_address, get_caller_address, contract_address_const
    };
    use starknet::class_hash::ClassHash;
    use integer::{u256_safe_divmod, u256_as_non_zero};
    use storage_read::{main::storage_read_component, interface::IStorageRead};
    use naming::interface::{
        naming::{INaming, INamingDispatcher, INamingDispatcherTrait},
        pricing::{IPricingDispatcher, IPricingDispatcherTrait}
    };
    use openzeppelin::{
        account, access::ownable::OwnableComponent,
        upgrades::{UpgradeableComponent, interface::IUpgradeable},
        token::erc20::interface::{IERC20Camel, IERC20CamelDispatcher, IERC20CamelDispatcherTrait},
    };

    component!(path: storage_read_component, storage: storage_read, event: StorageReadEvent);
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);

    #[abi(embed_v0)]
    impl StorageReadImpl = storage_read_component::StorageRead<ContractState>;
    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;


    #[storage]
    struct Storage {
        naming_contract: ContractAddress,
        erc20_contract: ContractAddress,
        pricing_contract: ContractAddress,
        server_pub_key: felt252,
        is_enabled: bool,
        blacklisted_addr: LegacyMap<ContractAddress, bool>,
        #[substorage(v0)]
        storage_read: storage_read_component::Storage,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage
    }

    // 
    // Events
    // 

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        DomainGift: DomainGift,
        #[flat]
        StorageReadEvent: storage_read_component::Event,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event
    }

    #[derive(Drop, starknet::Event)]
    struct DomainGift {
        #[key]
        id: u128,
        #[key]
        domain: felt252,
        #[key]
        owner: ContractAddress,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin_addr: ContractAddress,
        naming_addr: ContractAddress,
        erc20_addr: ContractAddress,
        pricing_addr: ContractAddress,
    ) {
        self.ownable.initializer(admin_addr);
        self.naming_contract.write(naming_addr);
        self.erc20_contract.write(erc20_addr);
        self.pricing_contract.write(pricing_addr);
    }

    #[abi(embed_v0)]
    impl DomainGiftImpl of super::IDomainGift<ContractState> {
        fn get_domain_gift(ref self: ContractState, id: u128, domain: felt252) {
            assert(self.is_enabled.read(), 'Contract is disabled');

            let caller = get_caller_address();
            assert(!self.blacklisted_addr.read(caller), 'Gift already claimed');

            // mark the user as blacklisted
            self.blacklisted_addr.write(caller, true);

            // assert domain length
            let domain_len = self.get_chars_len(domain.into());
            assert(domain_len >= 5, 'Domain too short');

            // buy the domain for the user
            let naming = self.naming_contract.read();
            let (_, price) = IPricingDispatcher { contract_address: self.pricing_contract.read() }
                .compute_buy_price(domain_len, 90);

            IERC20CamelDispatcher { contract_address: self.erc20_contract.read() }
                .approve(naming, price);
            INamingDispatcher { contract_address: naming }
                .buy(
                    id,
                    domain,
                    90, // 3 months
                    contract_address_const::<0>(),
                    contract_address_const::<0>(),
                    0,
                    0 // no metadata
                );

            // emit event 
            self.emit(Event::DomainGift(DomainGift { id, domain, owner: caller }));
        }

        // Admin functions
        fn enable(ref self: ContractState) {
            self.ownable.assert_only_owner();
            self.is_enabled.write(true);
        }

        fn disable(ref self: ContractState) {
            self.ownable.assert_only_owner();
            self.is_enabled.write(false);
        }

        fn withdraw(
            ref self: ContractState, erc20_addr: ContractAddress, target_addr: ContractAddress
        ) {
            self.ownable.assert_only_owner();
            let balance = IERC20CamelDispatcher { contract_address: erc20_addr }
                .balanceOf(get_contract_address());
            IERC20CamelDispatcher { contract_address: erc20_addr }.transfer(target_addr, balance);
        }
    }


    #[abi(embed_v0)]
    impl UpgradeableImpl of IUpgradeable<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            self.ownable.assert_only_owner();
            self.upgradeable._upgrade(new_class_hash);
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn get_chars_len(self: @ContractState, domain: u256) -> usize {
            if domain == (u256 { low: 0, high: 0 }) {
                return 0;
            };
            // 38 = simple_alphabet_size
            let (p, q, _) = u256_safe_divmod(domain, u256_as_non_zero(u256 { low: 38, high: 0 }));
            if q == (u256 { low: 37, high: 0 }) {
                // 3 = complex_alphabet_size
                let (shifted_p, _, _) = u256_safe_divmod(
                    p, u256_as_non_zero(u256 { low: 2, high: 0 })
                );
                let next = self.get_chars_len(shifted_p);
                return 1 + next;
            };
            let next = self.get_chars_len(p);
            1 + next
        }
    }
}