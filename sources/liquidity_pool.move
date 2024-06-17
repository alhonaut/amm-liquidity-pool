/* 
    This quest features a AMM (Automated Market Maker) liquidity pool. This module provides the 
    base functionality of an AMM that can be used to create a decentralized exchange on the Aptos 
    blockchain.
*/
module lp_account::liquidity_pool {
    //==============================================================================================
    // Dependencies
    //==============================================================================================

    use std::type_info;
    use aptos_framework::event;
    use aptos_framework::option;
    use aptos_framework::math64;
    use aptos_framework::account;
    use aptos_framework::math128;
    use aptos_framework::timestamp;
    use std::string::{Self, String};
    use aptos_framework::string_utils;
    use aptos_framework::resource_account;
    use aptos_framework::coin::{Self, Coin};
    use aptos_std::comparator::{Self, Result};
    use std::signer;
    
    #[test_only]
    use aptos_framework::aptos_coin::{Self, AptosCoin};

    //==============================================================================================
    // Constants
    //==============================================================================================

    // seed for module's resource account
    const SEED: vector<u8> = b"lp account";
    const LP_DECIMALS: u8 = 8;
    const SYMBOL_PREFIX_LENGTH: u64 = 4;
    const MINIMUM_LIQUIDITY_AMOUNT: u64 = 1000;
    
    const ECodeForAllErrors: u64 = 77482993;

    //==============================================================================================
    // Module Structs
    //==============================================================================================

    /* 
        LP coin struct
    */
    struct LPCoin<phantom CoinA, phantom CoinB> {}

    /* 
        Liquidity pool resource that holds the liquidity pool's state. To be stored in the module's
        resource account
    */
    struct LiquidityPool<phantom CoinA, phantom CoinB> has key {
        // coin reserve of the CoinA coin - holds the pool's CoinA coins
        coin_a_reserve: Coin<CoinA>,
        // coin reserve of the CoinB coin - holds the pool's CoinB coins
        coin_b_reserve: Coin<CoinB>,
        // mint cap of the specific pool's LP token
        lp_coin_mint_cap: coin::MintCapability<LPCoin<CoinA, CoinB>>,
        // burn cap of the specific pool's LP token
        lp_coin_burn_cap: coin::BurnCapability<LPCoin<CoinA, CoinB>>
    }

    /* 
        Module's state resource to hold module metadata and events. To be stored in the module's
        resource account.
    */
    struct State has key {
        // signer cap of the module's resource account
        signer_cap: account::SignerCapability,
        // events
        create_liquidity_pool_events: event::EventHandle<CreateLiquidityPoolEvent>,
        supply_liquidity_events: event::EventHandle<SupplyLiquidityEvent>,
        remove_liquidity_events: event::EventHandle<RemoveLiquidityEvent>,
        swap_events: event::EventHandle<SwapEvent>
    }

    //==============================================================================================
    // Event structs
    //==============================================================================================

    /* 
        Event to be emitted when a liquidity pool is created
    */
    #[event]
    struct CreateLiquidityPoolEvent has store, drop {
        // name of the first coin in the liquidity pool
        coin_a: String, 
        // name of the second coin in the liquidity pool
        coin_b: String,
        // name of the liquidity pool's LP coin
        lp_coin: String,
        // timestamp of when the event was emitted
        creation_timestamp_seconds: u64
    }

    /* 
        Event to be emitted when a liquidity pool is supplied with liquidity
    */
    #[event]
    struct SupplyLiquidityEvent has store, drop {
        // name of the first coin in the liquidity pool
        coin_a: String, 
        // name of the second coin in the liquidity pool
        coin_b: String,
        // amount of the first coin being supplied
        amount_a: u64,
        // amount of the second coin being supplied
        amount_b: u64,
        // amount of LP coins being minted
        lp_amount: u64,
        // timestamp of when the event was emitted
        creation_timestamp_seconds: u64
    }

    /* 
        Event to be emitted when a liquidity pool is removed of liquidity
    */
    #[event]
    struct RemoveLiquidityEvent has store, drop {
        // name of the first coin in the liquidity pool
        coin_a: String, 
        // name of the second coin in the liquidity pool
        coin_b: String,
        // amount of LP coins being burned
        lp_amount: u64,
        // amount of the first coin being removed
        amount_a: u64,
        // amount of the second coin being removed
        amount_b: u64,
        // timestamp of when the event was emitted
        creation_timestamp_seconds: u64
    }

    /* 
        Event to be emitted when a liquidity pool is swapped
    */
    #[event]
    struct SwapEvent has store, drop {
        // name of the first coin in the liquidity pool
        coin_a: String, 
        // name of the second coin in the liquidity pool
        coin_b: String,
        // amount of the first coin being swapped in
        amount_coin_a_in: u64,
        // amount of the first coin being swapped out
        amount_coin_a_out: u64,
        // amount of the second coin being swapped in
        amount_coin_b_in: u64,
        // amount of the second coin being swapped out
        amount_coin_b_out: u64,
        // timestamp of when the event was emitted
        creation_timestamp_seconds: u64
    }

    //==============================================================================================
    // Functions
    //==============================================================================================

    /* 
        Initializes the module by retrieving the module's resource account signer, and creating and
        moving the module's state resource
        @param admin - signer representing the admin of this module
    */
    fun init_module(admin: &signer) {
        let resource_signer_cap = resource_account::retrieve_resource_account_cap(admin, @overmind);
        let resource_signer = account::create_signer_with_capability(&resource_signer_cap);

        move_to(admin, State {
            signer_cap: resource_signer_cap,
            create_liquidity_pool_events: account::new_event_handle<CreateLiquidityPoolEvent>(&resource_signer), 
            supply_liquidity_events: account::new_event_handle<SupplyLiquidityEvent>(&resource_signer),
            remove_liquidity_events: account::new_event_handle<RemoveLiquidityEvent>(&resource_signer),
            swap_events: account::new_event_handle<SwapEvent>(&resource_signer)
        });
    }
    
    /* 
		Creates a liquidity pool for CoinA and CoinB. Aborts if the liquidity pool already exists, 
        if CoinA or CoinB does not exist, or if CoinA and CoinB are not sorted or are equal.
        @type_param CoinA - the type of the first coin for the liquidity pool
        @type_param CoinB - the type of the second coin for the liquidity pool
    */  
    public entry fun create_liquidity_pool<CoinA, CoinB>() acquires State {
        let config = borrow_global<State>(@lp_account);
        let pool_account = account::create_signer_with_capability(&config.signer_cap);

        let pool_address = signer::address_of(&pool_account);
        assert!(!exists<LiquidityPool<CoinA, CoinB>>(pool_address), ECodeForAllErrors);

        assert!(is_coins_valid<CoinA, CoinB>(), ECodeForAllErrors);
        
        let (lp_name, lp_symbol) = generate_lp_data<CoinA, CoinB>();
        let (lp_burn_cap, lp_freeze_cap, lp_mint_cap) = coin::initialize<LPCoin<CoinA, CoinB>>(
            &pool_account, 
            lp_name, 
            lp_symbol, 
            LP_DECIMALS, 
            true
        );
        coin::destroy_freeze_cap(lp_freeze_cap);

        coin::register<LPCoin<CoinA, CoinB>>(&pool_account);

        let liquidity_pool = LiquidityPool<CoinA, CoinB> {
            coin_a_reserve: coin::zero<CoinA>(),
            coin_b_reserve: coin::zero<CoinB>(),
            lp_coin_mint_cap: lp_mint_cap,
            lp_coin_burn_cap: lp_burn_cap
        };

        move_to(&pool_account, liquidity_pool);

        let state = borrow_global_mut<State>(pool_address);

        event::emit_event(&mut state.create_liquidity_pool_events, CreateLiquidityPoolEvent {
            coin_a: coin::name<CoinA>(),
            coin_b: coin::name<CoinB>(),
            lp_coin: coin::name<LPCoin<CoinA, CoinB>>(),
            creation_timestamp_seconds: timestamp::now_seconds()
        });
    }

    /* 
		Supplies a liquidity pool with coins in exchange for liquidity pool coins. Aborts if the 
        coin types are not sorted or are equal, if the liquidity pool does not exist, or if the 
        liquidity is not above 0 and the minimum liquidity (for the initial liquidity)
        @type_param CoinA - the type of the first coin for the liquidity pool
        @type_param CoinB - the type of the second coin for the liquidity pool
		@param coin_a - coins that match the first coin in the liquidity pool
		@param coin_b - coins that match the second coin in the liquidity pool
		@return - liquidity coins from the pool being supplied
    */
    public fun supply_liquidity<CoinA, CoinB>(
        coin_a: Coin<CoinA>, 
        coin_b: Coin<CoinB>
    ): Coin<LPCoin<CoinA, CoinB>> acquires State, LiquidityPool {
        let config = borrow_global<State>(@lp_account);
        let pool_account = account::create_signer_with_capability(&config.signer_cap);

        let pool_address = signer::address_of(&pool_account);
        assert!(exists<LiquidityPool<CoinA, CoinB>>(pool_address), ECodeForAllErrors);

        assert!(is_coins_valid<CoinA, CoinB>(), ECodeForAllErrors);

        let lp_coins_total_supply = get_total_supply<LPCoin<CoinA, CoinB>>();
        let pool = borrow_global_mut<LiquidityPool<CoinA, CoinB>>(pool_address);

        let amount_coin_a_reserve = coin::value<CoinA>(&pool.coin_a_reserve);
        let amount_coin_b_reserve = coin::value<CoinB>(&pool.coin_b_reserve);

        let amount_coin_a_provided = coin::value<CoinA>(&coin_a);
        let amount_coin_b_provided = coin::value<CoinB>(&coin_b);

        let pool_liquidity_amount = if (lp_coins_total_supply == 0) {
            let initial_supply = (math128::sqrt((amount_coin_a_provided as u128) * (amount_coin_b_provided as u128)) as u64);
            assert!(initial_supply > MINIMUM_LIQUIDITY_AMOUNT, ECodeForAllErrors);

            let lock = coin::mint<LPCoin<CoinA, CoinB>>(MINIMUM_LIQUIDITY_AMOUNT, &pool.lp_coin_mint_cap);
            coin::deposit<LPCoin<CoinA, CoinB>>(@lp_account, lock);

            initial_supply - MINIMUM_LIQUIDITY_AMOUNT
        } else {
            (math128::min(
                (amount_coin_a_provided as u128) * lp_coins_total_supply / (amount_coin_a_reserve as u128), 
                (amount_coin_b_provided as u128) * lp_coins_total_supply / (amount_coin_b_reserve as u128)) as u64)
        };
        assert!(pool_liquidity_amount > 0, ECodeForAllErrors);

        coin::merge<CoinA>(&mut pool.coin_a_reserve, coin_a);
        coin::merge<CoinB>(&mut pool.coin_b_reserve, coin_b);

        let lp_coins = coin::mint<LPCoin<CoinA, CoinB>>(pool_liquidity_amount, &pool.lp_coin_mint_cap);

        let state = borrow_global_mut<State>(pool_address);

        event::emit_event(&mut state.supply_liquidity_events ,SupplyLiquidityEvent {
            coin_a: coin::name<CoinA>(),
            coin_b: coin::name<CoinB>(),
            amount_a: amount_coin_a_provided,
            amount_b: amount_coin_b_provided,
            lp_amount: pool_liquidity_amount,
            creation_timestamp_seconds: timestamp::now_seconds()
        });

        lp_coins
    }

    /* 
		Removes liquidity from a pool for a cost of liquidity coins. Aborts if the amounts of coins
        to return are not above 0. 
        @type_param CoinA - the type of the first coin for the liquidity pool
        @type_param CoinB - the type of the second coin for the liquidity pool
		@param lp_coins - liquidity coins from the pool being supplied
		@return - the two coins being removed from the liquidity pool
    */
    public fun remove_liquidity<CoinA, CoinB>(
        lp_coins_to_redeem: Coin<LPCoin<CoinA, CoinB>>
    ): (Coin<CoinA>, Coin<CoinB>) acquires State, LiquidityPool {
        assert!(is_coins_valid<CoinA, CoinB>(), ECodeForAllErrors);

        let config = borrow_global<State>(@lp_account);
        let pool_account = account::create_signer_with_capability(&config.signer_cap);

        let pool_address = signer::address_of(&pool_account);
        assert!(exists<LiquidityPool<CoinA, CoinB>>(pool_address), ECodeForAllErrors);

        let lp_coins_total_supply = get_total_supply<LPCoin<CoinA, CoinB>>();
        assert!(lp_coins_total_supply > (MINIMUM_LIQUIDITY_AMOUNT as u128), ECodeForAllErrors);

        let pool = borrow_global_mut<LiquidityPool<CoinA, CoinB>>(pool_address);
        
        let amount_lp_coins = coin::value<LPCoin<CoinA, CoinB>>(&lp_coins_to_redeem);
        let amount_coin_a_reserve = coin::value<CoinA>(&pool.coin_a_reserve);
        let amount_coin_b_reserve = coin::value<CoinB>(&pool.coin_b_reserve);

        let amount_coin_a = (((amount_lp_coins as u128) * (amount_coin_a_reserve as u128) / lp_coins_total_supply) as u64);
        let amount_coin_b = (((amount_lp_coins as u128) * (amount_coin_b_reserve as u128) / lp_coins_total_supply) as u64);
        assert!(amount_coin_a > 0 && amount_coin_b > 0, ECodeForAllErrors);

        let coins_a_returned = coin::extract<CoinA>(&mut pool.coin_a_reserve, amount_coin_a);
        let coins_b_returned = coin::extract<CoinB>(&mut pool.coin_b_reserve, amount_coin_b);

        coin::burn<LPCoin<CoinA, CoinB>>(lp_coins_to_redeem, &pool.lp_coin_burn_cap);

        let state = borrow_global_mut<State>(pool_address);

        event::emit_event(&mut state.remove_liquidity_events, RemoveLiquidityEvent {
            coin_a: coin::name<CoinA>(),
            coin_b: coin::name<CoinB>(),
            lp_amount: amount_lp_coins,
            amount_a: amount_coin_a,
            amount_b: amount_coin_b,
            creation_timestamp_seconds: timestamp::now_seconds()
        });

        (coins_a_returned, coins_b_returned)
    }

    /* 
		Swaps coin in a liquidity pool. Can swap both ways at the same time. Aborts if the coin 
        types are not sorted or are equal, if the liquidity pool does not exist, if the new LP k 
        value is less than the old LP k value, or if the amount of coins being swapped in is not 
        above 0. 
        @type_param CoinA - the type of the first coin for the liquidity pool
        @type_param CoinB - the type of the second coin for the liquidity pool
		@param coin_a_in: the coins representing the CoinA being swapped into the pool
		@param amount_coin_a_out: the expected amount of CoinA being swapped out of the pool
		@param coin_b_in: the coins representing the CoinB being swapped into the pool
		@param amount_coin_b_out: the expected amount of CoinB being swapped out of the pool
		@return - the two coins being swapped out of the liquidity pool
    */
    public fun swap<CoinA, CoinB>(
        coin_a_in: Coin<CoinA>, 
        amount_coin_a_out: u64,
        coin_b_in: Coin<CoinB>,
        amount_coin_b_out: u64
    ): (Coin<CoinA>, Coin<CoinB>) acquires State, LiquidityPool {
        assert!(is_coins_valid<CoinA, CoinB>(), ECodeForAllErrors);

        let config = borrow_global<State>(@lp_account);
        let pool_account = account::create_signer_with_capability(&config.signer_cap);

        let pool_address = signer::address_of(&pool_account);
        assert!(exists<LiquidityPool<CoinA, CoinB>>(pool_address), ECodeForAllErrors);

        let pool = borrow_global_mut<LiquidityPool<CoinA, CoinB>>(pool_address);

        let amount_coin_a_reserve = coin::value<CoinA>(&pool.coin_a_reserve);
        let amount_coin_b_reserve = coin::value<CoinB>(&pool.coin_b_reserve);

        let amount_coin_a_in = coin::value<CoinA>(&coin_a_in);
        let amount_coin_b_in = coin::value<CoinB>(&coin_b_in);

        assert!(amount_coin_a_in > 0 || amount_coin_b_in > 0, ECodeForAllErrors);

        let k_before = calculate_constant_k<CoinA, CoinB>(
            pool, 
            amount_coin_a_in, 
            amount_coin_b_in, 
            amount_coin_a_out, 
            amount_coin_b_out
        );
        
        coin::merge<CoinA>(&mut pool.coin_a_reserve, coin_a_in);
        coin::merge<CoinB>(&mut pool.coin_b_reserve, coin_b_in);

        let coin_a_swapped = coin::extract<CoinA>(&mut pool.coin_a_reserve, amount_coin_a_out);
        let coin_b_swapped = coin::extract<CoinB>(&mut pool.coin_b_reserve, amount_coin_b_out);

        let k_after = calculate_constant_k<CoinA, CoinB>(
            pool, 
            amount_coin_a_in, 
            amount_coin_b_in, 
            amount_coin_a_out, 
            amount_coin_b_out
        );

        assert!(k_before <= k_after, ECodeForAllErrors);

        let state = borrow_global_mut<State>(pool_address);

        event::emit_event(&mut state.swap_events, SwapEvent {
            coin_a: coin::name<CoinA>(),
            coin_b: coin::name<CoinB>(),
            amount_coin_a_in, 
            amount_coin_a_out, 
            amount_coin_b_in, 
            amount_coin_b_out, 
            creation_timestamp_seconds: timestamp::now_seconds()
        });

        (coin_a_swapped, coin_b_swapped)
    }

    //==============================================================================================
    // Helper functions
    //==============================================================================================

    public fun calculate_constant_k<CoinA, CoinB>(
        pool: &LiquidityPool<CoinA, CoinB>, 
        amount_coin_a_in: u64, 
        amount_coin_b_in: u64, 
        amount_coin_a_out: u64, 
        amount_coin_b_out: u64
    ): u64 {
        let amount_coin_a_reserve = coin::value<CoinA>(&pool.coin_a_reserve);
        let amount_coin_b_reserve = coin::value<CoinB>(&pool.coin_b_reserve);

        let constant_k = 
            ((amount_coin_a_reserve as u128) + (amount_coin_a_in as u128) - (amount_coin_a_out as u128)) * 
            ((amount_coin_b_reserve as u128) + (amount_coin_b_in as u128) - (amount_coin_b_out as u128));
        
        (constant_k as u64)  
    }

   public fun generate_lp_data<CoinA, CoinB>(): (String, String) {
        let lp_name = string::utf8(b"");
        string::append_utf8(&mut lp_name, b"\"");
        string::append(&mut lp_name, coin::symbol<CoinA>());
        string::append_utf8(&mut lp_name, b"\"");
        string::append_utf8(&mut lp_name, b"-");
        string::append_utf8(&mut lp_name, b"\"");
        string::append(&mut lp_name, coin::symbol<CoinB>());
        string::append_utf8(&mut lp_name, b"\"");
        string::append_utf8(&mut lp_name, b" LP token");

        let lp_symbol = string::utf8(b"");
        string::append(&mut lp_symbol, coin_symbol_prefix<CoinA>());
        string::append_utf8(&mut lp_symbol, b"-");
        string::append(&mut lp_symbol, coin_symbol_prefix<CoinB>());

        (lp_name, lp_symbol)
    }

    public fun coin_symbol_prefix<CoinType>(): String {
        let symbol = coin::symbol<CoinType>();
        let prefix_length = math64::min(string::length(&symbol), SYMBOL_PREFIX_LENGTH);

        string::sub_string(&symbol, 0, prefix_length)
    }

    public fun is_coins_valid<CoinA, CoinB>(): bool {
        assert!(coin::is_coin_initialized<CoinA>() && coin::is_coin_initialized<CoinB>(), ECodeForAllErrors);

        let compare_result = compare<CoinA, CoinB>();
        assert!(!comparator::is_equal(&compare_result), ECodeForAllErrors);
        
        comparator::is_smaller_than(&compare_result)
    }

    public fun compare<CoinA, CoinB>(): Result {
        let coin_a_info = type_info::type_of<CoinA>();
        let coin_b_info = type_info::type_of<CoinB>();

        let struct_info_a = type_info::struct_name(&coin_a_info);
        let struct_info_b = type_info::struct_name(&coin_b_info);
        let struct_info_cmpr = comparator::compare(&struct_info_a, &struct_info_b);
        if (!comparator::is_equal(&struct_info_cmpr)) return struct_info_cmpr;

        let module_info_a = type_info::module_name(&coin_a_info);
        let module_info_b = type_info::module_name(&coin_b_info);
        let module_info_cmpr = comparator::compare(&module_info_a, &module_info_b);
        if (!comparator::is_equal(&module_info_cmpr)) return module_info_cmpr;

        let coin_a_address = type_info::account_address(&coin_a_info);
        let coin_b_address = type_info::account_address(&coin_b_info);
        let addresses_cmpr = comparator::compare(&coin_a_address, &coin_b_address);
        if (!comparator::is_equal(&addresses_cmpr)) return addresses_cmpr;

        addresses_cmpr
    }

    public fun get_total_supply<CoinType>(): u128 {
        option::extract(&mut coin::supply<CoinType>())
    }

    //==============================================================================================
    // Tests - DO NOT MODIFY
    //==============================================================================================

    #[test_only]
    struct TestCoin1 {}
    #[test_only]
    struct TestCoin2 {}
    #[test_only]
    struct TestCoin3 {}
    #[test_only]
    struct TestCoin4 {}

    #[test_only]
    const TEST_COIN1_NAME: vector<u8> = b"TestCoin1";
    #[test_only]
    const TEST_COIN1_SYMBOL: vector<u8> = b"TC1";
    #[test_only]
    const TEST_COIN1_DECIMALS: u8 = 8;

    #[test_only]
    const TEST_COIN2_NAME: vector<u8> = b"TestCoin2";
    #[test_only]
    const TEST_COIN2_SYMBOL: vector<u8> = b"TC2";
    #[test_only]
    const TEST_COIN2_DECIMALS: u8 = 0;

    #[test_only]
    const TEST_COIN3_NAME: vector<u8> = b"TestCoin3";
    #[test_only]
    const TEST_COIN3_SYMBOL: vector<u8> = b"TC3";
    #[test_only]
    const TEST_COIN3_DECIMALS: u8 = 18;

    #[test_only]
    const TEST_COIN4_NAME: vector<u8> = b"TestCoin4";
    #[test_only]
    const TEST_COIN4_SYMBOL: vector<u8> = b"TC4------";
    #[test_only]
    const TEST_COIN4_DECIMALS: u8 = 10;    


    #[test(admin = @overmind, resource_account = @lp_account, user = @0xA)]
    fun test_init_module_success(
        admin: &signer, 
        resource_account: &signer, 
    ) acquires State {
        let admin_address = signer::address_of(admin);
        account::create_account_for_test(admin_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");
        init_module(resource_account);

        let resource_account_address = @lp_account;

        let state = borrow_global<State>(resource_account_address);
        assert!(
            account::get_signer_capability_address(&state.signer_cap) == 
                resource_account_address, 
            0
        );

        assert!(event::counter<CreateLiquidityPoolEvent>(&state.create_liquidity_pool_events) == 0, 0);
        assert!(event::counter<SupplyLiquidityEvent>(&state.supply_liquidity_events) == 0, 0);
        assert!(event::counter<RemoveLiquidityEvent>(&state.remove_liquidity_events) == 0, 0);
        assert!(event::counter<SwapEvent>(&state.swap_events) == 0, 0);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    fun test_create_liquidity_pool_success_create_one_pool_coin_1_and_2(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");
        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<TestCoin1, TestCoin2>();

        let resource_account_address = @lp_account;

        assert!(
            coin::is_coin_initialized<LPCoin<TestCoin1, TestCoin2>>() == true,
            0
        );
        assert!(
            coin::name<LPCoin<TestCoin1, TestCoin2>>() == string::utf8(b"\"TC1\"-\"TC2\" LP token"),
            0
        );
        assert!(
            coin::symbol<LPCoin<TestCoin1, TestCoin2>>() == string::utf8(b"TC1-TC2"),
            0
        );
        assert!(
            coin::decimals<LPCoin<TestCoin1, TestCoin2>>() == 8,
            0
        );
        assert!(
            option::is_some(&coin::supply<LPCoin<TestCoin1, TestCoin2>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<TestCoin1, TestCoin2>>(), &0),
            0
        );

        assert!(
            coin::is_account_registered<LPCoin<TestCoin1, TestCoin2>>(resource_account_address),
            0
        );

        assert!(
            exists<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address),
            0
        );
        let liquidity_pool = 
            borrow_global<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address);
        assert!(
            coin::value<TestCoin1>(&liquidity_pool.coin_a_reserve) == 0,
            0
        );
        assert!(
            coin::value<TestCoin2>(&liquidity_pool.coin_b_reserve) == 0,
            0
        );

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter<CreateLiquidityPoolEvent>(&state.create_liquidity_pool_events) == 1, 0);
        assert!(event::counter<SupplyLiquidityEvent>(&state.supply_liquidity_events) == 0, 0);
        assert!(event::counter<RemoveLiquidityEvent>(&state.remove_liquidity_events) == 0, 0);
        assert!(event::counter<SwapEvent>(&state.swap_events) == 0, 0);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    fun test_create_liquidity_pool_success_create_one_pool_coin_3_and_4(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");
        init_module(resource_account);

        let (coin_3_burn_cap, coin_3_freeze_cap, coin_3_mint_cap) = coin::initialize<TestCoin3>(
            resource_account, 
            string::utf8(TEST_COIN3_NAME),
            string::utf8(TEST_COIN3_SYMBOL),
            TEST_COIN3_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_3_freeze_cap);
        coin::destroy_burn_cap(coin_3_burn_cap);

        let (coin_4_burn_cap, coin_4_freeze_cap, coin_4_mint_cap) = coin::initialize<TestCoin4>(
            resource_account, 
            string::utf8(TEST_COIN4_NAME),
            string::utf8(TEST_COIN4_SYMBOL),
            TEST_COIN4_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_4_freeze_cap);
        coin::destroy_burn_cap(coin_4_burn_cap);

        create_liquidity_pool<TestCoin3, TestCoin4>();

        let resource_account_address = @lp_account;

       assert!(
            coin::is_coin_initialized<LPCoin<TestCoin3, TestCoin4>>() == true,
            0
        );
        assert!(
            coin::name<LPCoin<TestCoin3, TestCoin4>>() == string::utf8(b"\"TC3\"-\"TC4------\" LP token"),
            0
        );
        assert!(
            coin::symbol<LPCoin<TestCoin3, TestCoin4>>() == string::utf8(b"TC3-TC4-"),
            0
        );
        assert!(
            coin::decimals<LPCoin<TestCoin3, TestCoin4>>() == 8,
            0
        );
        assert!(
            option::is_some(&coin::supply<LPCoin<TestCoin3, TestCoin4>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<TestCoin3, TestCoin4>>(), &0),
            0
        );

        assert!(
            coin::is_account_registered<LPCoin<TestCoin3, TestCoin4>>(resource_account_address),
            0
        );

        assert!(
            exists<LiquidityPool<TestCoin3, TestCoin4>>(resource_account_address),
            0
        );
        let liquidity_pool = 
            borrow_global<LiquidityPool<TestCoin3, TestCoin4>>(resource_account_address);
        assert!(
            coin::value<TestCoin3>(&liquidity_pool.coin_a_reserve) == 0,
            0
        );
        assert!(
            coin::value<TestCoin4>(&liquidity_pool.coin_b_reserve) == 0,
            0
        );

        coin::destroy_mint_cap(coin_3_mint_cap);
        coin::destroy_mint_cap(coin_4_mint_cap);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter<CreateLiquidityPoolEvent>(&state.create_liquidity_pool_events) == 1, 0);
        assert!(event::counter<SupplyLiquidityEvent>(&state.supply_liquidity_events) == 0, 0);
        assert!(event::counter<RemoveLiquidityEvent>(&state.remove_liquidity_events) == 0, 0);
        assert!(event::counter<SwapEvent>(&state.swap_events) == 0, 0);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    fun test_create_liquidity_pool_success_create_one_pool_coin_2_and_aptos_coin(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");
        init_module(resource_account);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<AptosCoin, TestCoin2>();

        let resource_account_address = @lp_account;

        assert!(
            coin::is_coin_initialized<LPCoin<AptosCoin, TestCoin2>>() == true,
            0
        );
        assert!(
            coin::name<LPCoin<AptosCoin, TestCoin2>>() == string::utf8(b"\"APT\"-\"TC2\" LP token"),
            0
        );
        assert!(
            coin::symbol<LPCoin<AptosCoin, TestCoin2>>() == string::utf8(b"APT-TC2"),
            0
        );
        assert!(
            coin::decimals<LPCoin<AptosCoin, TestCoin2>>() == 8,
            0
        );
        assert!(
            option::is_some(&coin::supply<LPCoin<AptosCoin, TestCoin2>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<AptosCoin, TestCoin2>>(), &0),
            0
        );

        assert!(
            coin::is_account_registered<LPCoin<AptosCoin, TestCoin2>>(resource_account_address),
            0
        );

        assert!(
            exists<LiquidityPool<AptosCoin, TestCoin2>>(resource_account_address),
            0
        );
        let liquidity_pool = 
            borrow_global<LiquidityPool<AptosCoin, TestCoin2>>(resource_account_address);
        assert!(
            coin::value<AptosCoin>(&liquidity_pool.coin_a_reserve) == 0,
            0
        );
        assert!(
            coin::value<TestCoin2>(&liquidity_pool.coin_b_reserve) == 0,
            0
        );

        coin::destroy_mint_cap(coin_2_mint_cap);
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter<CreateLiquidityPoolEvent>(&state.create_liquidity_pool_events) == 1, 0);
        assert!(event::counter<SupplyLiquidityEvent>(&state.supply_liquidity_events) == 0, 0);
        assert!(event::counter<RemoveLiquidityEvent>(&state.remove_liquidity_events) == 0, 0);
        assert!(event::counter<SwapEvent>(&state.swap_events) == 0, 0);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    fun test_create_liquidity_pool_success_create_two_pools_coin_1_and_2_and_coin_3_and_2(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");
        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        let (coin_3_burn_cap, coin_3_freeze_cap, coin_3_mint_cap) = coin::initialize<TestCoin3>(
            resource_account, 
            string::utf8(TEST_COIN3_NAME),
            string::utf8(TEST_COIN3_SYMBOL),
            TEST_COIN3_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_3_freeze_cap);
        coin::destroy_burn_cap(coin_3_burn_cap);

        create_liquidity_pool<TestCoin1, TestCoin2>();
        create_liquidity_pool<TestCoin2, TestCoin3>();

        let resource_account_address = @lp_account;

        assert!(
            coin::is_coin_initialized<LPCoin<TestCoin1, TestCoin2>>() == true,
            0
        );
        assert!(
            coin::name<LPCoin<TestCoin1, TestCoin2>>() == string::utf8(b"\"TC1\"-\"TC2\" LP token"),
            0
        );
        assert!(
            coin::symbol<LPCoin<TestCoin1, TestCoin2>>() == string::utf8(b"TC1-TC2"),
            0
        );
        assert!(
            coin::decimals<LPCoin<TestCoin1, TestCoin2>>() == 8,
            0
        );
        assert!(
            option::is_some(&coin::supply<LPCoin<TestCoin1, TestCoin2>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<TestCoin1, TestCoin2>>(), &0),
            0
        );

        assert!(
            coin::is_coin_initialized<LPCoin<TestCoin2, TestCoin3>>() == true,
            0
        );
        assert!(
            coin::name<LPCoin<TestCoin2, TestCoin3>>() == string::utf8(b"\"TC2\"-\"TC3\" LP token"),
            0
        );
        assert!(
            coin::symbol<LPCoin<TestCoin2, TestCoin3>>() == string::utf8(b"TC2-TC3"),
            0
        );
        assert!(
            coin::decimals<LPCoin<TestCoin2, TestCoin3>>() == 8,
            0
        );
        assert!(
            option::is_some(&coin::supply<LPCoin<TestCoin2, TestCoin3>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<TestCoin2, TestCoin3>>(), &0),
            0
        );

        assert!(
            exists<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address),
            0
        );
        let liquidity_pool = 
            borrow_global<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address);
        assert!(
            coin::value<TestCoin1>(&liquidity_pool.coin_a_reserve) == 0,
            0
        );
        assert!(
            coin::value<TestCoin2>(&liquidity_pool.coin_b_reserve) == 0,
            0
        );

        assert!(
            exists<LiquidityPool<TestCoin2, TestCoin3>>(resource_account_address),
            0
        );
        let liquidity_pool_2 = 
            borrow_global<LiquidityPool<TestCoin2, TestCoin3>>(resource_account_address);
        assert!(
            coin::value<TestCoin2>(&liquidity_pool_2.coin_a_reserve) == 0,
            0
        );
        assert!(
            coin::value<TestCoin3>(&liquidity_pool_2.coin_b_reserve) == 0,
            0
        );

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);
        coin::destroy_mint_cap(coin_3_mint_cap);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter<CreateLiquidityPoolEvent>(&state.create_liquidity_pool_events) == 2, 0);
        assert!(event::counter<SupplyLiquidityEvent>(&state.supply_liquidity_events) == 0, 0);
        assert!(event::counter<RemoveLiquidityEvent>(&state.remove_liquidity_events) == 0, 0);
        assert!(event::counter<SwapEvent>(&state.swap_events) == 0, 0);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    #[expected_failure(abort_code = ECodeForAllErrors, location = Self)]
    fun test_create_liquidity_pool_failure_coin_a_is_not_a_coin(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");
        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<TestCoin3, TestCoin2>();

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    #[expected_failure(abort_code = ECodeForAllErrors, location = Self)]
    fun test_create_liquidity_pool_failure_coin_b_is_not_a_coin(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");
        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<TestCoin1, TestCoin3>();

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    #[expected_failure(abort_code = ECodeForAllErrors, location = Self)]
    fun test_create_liquidity_pool_failure_coins_wrong_order(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");
        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<TestCoin2, TestCoin1>();

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    #[expected_failure(abort_code = ECodeForAllErrors, location = Self)]
    fun test_create_liquidity_pool_failure_same_coin(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");
        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<TestCoin1, TestCoin1>();

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    #[expected_failure(abort_code = ECodeForAllErrors, location = Self)]
    fun test_create_liquidity_pool_failure_pool_already_exists(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");
        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<TestCoin1, TestCoin2>();
        create_liquidity_pool<TestCoin1, TestCoin2>();

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    #[expected_failure(abort_code = ECodeForAllErrors, location = Self)]
    fun test_supply_liquidity_failure_not_enough_provided_liquidity(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<AptosCoin, TestCoin2>>(admin);
        coin::register<AptosCoin>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<AptosCoin>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<AptosCoin, TestCoin2>();

        let coin_1_supply_amount = 1000;
        let coin_2_supply_amount = 1000;
        let lp_coins = supply_liquidity<AptosCoin, TestCoin2>(
            coin::mint<AptosCoin>(coin_1_supply_amount, &mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap)
        );

        coin::destroy_mint_cap(coin_2_mint_cap);
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);

        coin::deposit<LPCoin<AptosCoin, TestCoin2>>(admin_address, lp_coins);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    #[expected_failure(abort_code = ECodeForAllErrors, location = Self)]
    fun test_supply_liquidity_failure_liquidity_not_above_minimum(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<AptosCoin, TestCoin2>>(admin);
        coin::register<AptosCoin>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<AptosCoin>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<AptosCoin, TestCoin2>();

        let coin_1_supply_amount = 10;
        let coin_2_supply_amount = 10;
        let lp_coins = supply_liquidity<AptosCoin, TestCoin2>(
            coin::mint<AptosCoin>(coin_1_supply_amount, &mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap)
        );

        coin::destroy_mint_cap(coin_2_mint_cap);
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);

        coin::deposit<LPCoin<AptosCoin, TestCoin2>>(admin_address, lp_coins);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    fun test_supply_liquidity_success_supply_initial_liquidity_coin_with_extra_2_and_aptos_coin(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<AptosCoin, TestCoin2>>(admin);
        coin::register<AptosCoin>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<AptosCoin>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<AptosCoin, TestCoin2>();

        let coin_1_supply_amount = 100 * math64::pow(10, (coin::decimals<AptosCoin>() as u64));
        let coin_2_supply_amount = 100 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let lp_coins = supply_liquidity<AptosCoin, TestCoin2>(
            coin::mint<AptosCoin>(coin_1_supply_amount, &mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap)
        );

        let resource_account_address = @lp_account;

        assert!(
            option::is_some(&coin::supply<LPCoin<AptosCoin, TestCoin2>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<AptosCoin, TestCoin2>>(), &1000000),
            0
        );

        assert!(
            coin::value<LPCoin<AptosCoin, TestCoin2>>(&lp_coins) == 1000000 - 1000,
            0
        );

        assert!(
            coin::balance<LPCoin<AptosCoin, TestCoin2>>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<LPCoin<AptosCoin, TestCoin2>>(resource_account_address) == 1000, 
            0
        );

        assert!(
            coin::balance<AptosCoin>(resource_account_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(resource_account_address) == 0,
            0
        );

        assert!(
            coin::balance<AptosCoin>(admin_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(admin_address) == 0,
            0
        );

        assert!(
            coin::balance<AptosCoin>(resource_account_address) == 0, 
            0
        );
        assert!(
            coin::balance<TestCoin2>(resource_account_address) == 0, 
            0
        );
        assert!(
            coin::balance<AptosCoin>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<TestCoin2>(admin_address) == 0, 
            0
        );

        assert!(
            exists<LiquidityPool<AptosCoin, TestCoin2>>(resource_account_address),
            0
        );
        let liquidity_pool = 
            borrow_global<LiquidityPool<AptosCoin, TestCoin2>>(resource_account_address);
        assert!(
            coin::value<AptosCoin>(&liquidity_pool.coin_a_reserve) == coin_1_supply_amount,
            0
        );
        assert!(
            coin::value<TestCoin2>(&liquidity_pool.coin_b_reserve) == coin_2_supply_amount,
            0
        );

        coin::destroy_mint_cap(coin_2_mint_cap);
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);

        coin::deposit<LPCoin<AptosCoin, TestCoin2>>(admin_address, lp_coins);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter<CreateLiquidityPoolEvent>(&state.create_liquidity_pool_events) == 1, 0);
        assert!(event::counter<SupplyLiquidityEvent>(&state.supply_liquidity_events) == 1, 0);
        assert!(event::counter<RemoveLiquidityEvent>(&state.remove_liquidity_events) == 0, 0);
        assert!(event::counter<SwapEvent>(&state.swap_events) == 0, 0);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    fun test_supply_liquidity_success_supply_initial_liquidity_coin_with_extra_2_and_aptos_coin_non_optimal(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<AptosCoin, TestCoin2>>(admin);
        coin::register<AptosCoin>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<AptosCoin>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<AptosCoin, TestCoin2>();

        let coin_1_supply_amount = 10000 * math64::pow(10, (coin::decimals<AptosCoin>() as u64));
        let coin_2_supply_amount = 100 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let lp_coins = supply_liquidity<AptosCoin, TestCoin2>(
            coin::mint<AptosCoin>(coin_1_supply_amount, &mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap)
        );

        let resource_account_address = @lp_account;

        assert!(
            option::is_some(&coin::supply<LPCoin<AptosCoin, TestCoin2>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<AptosCoin, TestCoin2>>(), &10000000),
            0
        );

        assert!(
            coin::value<LPCoin<AptosCoin, TestCoin2>>(&lp_coins) == 10000000 - 1000,
            0
        );

        assert!(
            coin::balance<LPCoin<AptosCoin, TestCoin2>>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<LPCoin<AptosCoin, TestCoin2>>(resource_account_address) == 1000, 
            0
        );

        assert!(
            coin::balance<AptosCoin>(resource_account_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(resource_account_address) == 0,
            0
        );

        assert!(
            coin::balance<AptosCoin>(admin_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(admin_address) == 0,
            0
        );

        assert!(
            coin::balance<AptosCoin>(resource_account_address) == 0, 
            0
        );
        assert!(
            coin::balance<TestCoin2>(resource_account_address) == 0, 
            0
        );
        assert!(
            coin::balance<AptosCoin>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<TestCoin2>(admin_address) == 0, 
            0
        );

        assert!(
            exists<LiquidityPool<AptosCoin, TestCoin2>>(resource_account_address),
            0
        );
        let liquidity_pool = 
            borrow_global<LiquidityPool<AptosCoin, TestCoin2>>(resource_account_address);
        assert!(
            coin::value<AptosCoin>(&liquidity_pool.coin_a_reserve) == coin_1_supply_amount,
            0
        );
        assert!(
            coin::value<TestCoin2>(&liquidity_pool.coin_b_reserve) == coin_2_supply_amount,
            0
        );

        coin::destroy_mint_cap(coin_2_mint_cap);
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);

        coin::deposit<LPCoin<AptosCoin, TestCoin2>>(admin_address, lp_coins);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter<CreateLiquidityPoolEvent>(&state.create_liquidity_pool_events) == 1, 0);
        assert!(event::counter<SupplyLiquidityEvent>(&state.supply_liquidity_events) == 1, 0);
        assert!(event::counter<RemoveLiquidityEvent>(&state.remove_liquidity_events) == 0, 0);
        assert!(event::counter<SwapEvent>(&state.swap_events) == 0, 0);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    fun test_supply_liquidity_success_supply_initial_liquidity_coin_with_extra_for_two_pools(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<TestCoin1, TestCoin2>>(admin);
        coin::register<LPCoin<AptosCoin, TestCoin2>>(admin);
        coin::register<AptosCoin>(admin);
        coin::register<TestCoin1>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<AptosCoin>(resource_account);
        coin::register<TestCoin1>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<AptosCoin, TestCoin2>();
        create_liquidity_pool<TestCoin1, TestCoin2>();

        let coin_1_supply_amount = 100 * math64::pow(10, (coin::decimals<AptosCoin>() as u64));
        let coin_2_supply_amount = 100 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let lp_coins = supply_liquidity<AptosCoin, TestCoin2>(
            coin::mint<AptosCoin>(coin_1_supply_amount, &mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap)
        );

        let coin_1_supply_amount_2 = 100 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let coin_2_supply_amount_2 = 100 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let lp_coins_2 = supply_liquidity<TestCoin1, TestCoin2>(
            coin::mint<TestCoin1>(coin_1_supply_amount_2, &coin_1_mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount_2, &coin_2_mint_cap)
        );

        let resource_account_address = @lp_account;

        assert!(
            option::is_some(&coin::supply<LPCoin<AptosCoin, TestCoin2>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<AptosCoin, TestCoin2>>(), &1000000),
            0
        );

        assert!(
            option::is_some(&coin::supply<LPCoin<TestCoin1, TestCoin2>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<TestCoin1, TestCoin2>>(), &1000000),
            0
        );

        assert!(
            coin::value<LPCoin<AptosCoin, TestCoin2>>(&lp_coins) == 1000000 - 1000,
            0
        );

        assert!(
            coin::value<LPCoin<TestCoin1, TestCoin2>>(&lp_coins_2) == 1000000 - 1000,
            0
        );

        assert!(
            coin::balance<LPCoin<AptosCoin, TestCoin2>>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<LPCoin<AptosCoin, TestCoin2>>(resource_account_address) == 1000, 
            0
        );

        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(resource_account_address) == 1000, 
            0
        );

        assert!(
            coin::balance<AptosCoin>(resource_account_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(resource_account_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin1>(resource_account_address) == 0,
            0
        );

        assert!(
            coin::balance<AptosCoin>(admin_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(admin_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin1>(admin_address) == 0,
            0
        );

        assert!(
            exists<LiquidityPool<AptosCoin, TestCoin2>>(resource_account_address),
            0
        );
        let liquidity_pool = 
            borrow_global<LiquidityPool<AptosCoin, TestCoin2>>(resource_account_address);
        assert!(
            coin::value<AptosCoin>(&liquidity_pool.coin_a_reserve) == coin_1_supply_amount,
            0
        );
        assert!(
            coin::value<TestCoin2>(&liquidity_pool.coin_b_reserve) == coin_2_supply_amount,
            0
        );

        assert!(
            exists<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address),
            0
        );
        let liquidity_pool_2 = 
            borrow_global<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address);
        assert!(
            coin::value<TestCoin1>(&liquidity_pool_2.coin_a_reserve) == coin_1_supply_amount_2,
            0
        );
        assert!(
            coin::value<TestCoin2>(&liquidity_pool_2.coin_b_reserve) == coin_2_supply_amount_2,
            0
        );

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);

        coin::deposit<LPCoin<AptosCoin, TestCoin2>>(admin_address, lp_coins);
        coin::deposit<LPCoin<TestCoin1, TestCoin2>>(admin_address, lp_coins_2);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter<CreateLiquidityPoolEvent>(&state.create_liquidity_pool_events) == 2, 0);
        assert!(event::counter<SupplyLiquidityEvent>(&state.supply_liquidity_events) == 2, 0);
        assert!(event::counter<RemoveLiquidityEvent>(&state.remove_liquidity_events) == 0, 0);
        assert!(event::counter<SwapEvent>(&state.swap_events) == 0, 0);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    fun test_supply_liquidity_success_supply_initial_liquidity_coin_with_extra_for_two_pools_common_coin(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<AptosCoin, TestCoin1>>(admin);
        coin::register<LPCoin<AptosCoin, TestCoin2>>(admin);
        coin::register<AptosCoin>(admin);
        coin::register<TestCoin1>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<AptosCoin>(resource_account);
        coin::register<TestCoin1>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<AptosCoin, TestCoin2>();
        create_liquidity_pool<AptosCoin, TestCoin1>();

        let coin_1_supply_amount = 100 * math64::pow(10, (coin::decimals<AptosCoin>() as u64));
        let coin_2_supply_amount = 100 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let lp_coins = supply_liquidity<AptosCoin, TestCoin2>(
            coin::mint<AptosCoin>(coin_1_supply_amount, &mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap)
        );

        let coin_1_supply_amount_2 = 100 * math64::pow(10, (coin::decimals<AptosCoin>() as u64));
        let coin_2_supply_amount_2 = 100 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let lp_coins_2 = supply_liquidity<AptosCoin, TestCoin1>(
            coin::mint<AptosCoin>(coin_1_supply_amount_2, &mint_cap),
            coin::mint<TestCoin1>(coin_2_supply_amount_2, &coin_1_mint_cap)
        );

        let resource_account_address = @lp_account;

        assert!(
            option::is_some(&coin::supply<LPCoin<AptosCoin, TestCoin2>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<AptosCoin, TestCoin2>>(), &1000000),
            0
        );

        assert!(
            option::is_some(&coin::supply<LPCoin<AptosCoin, TestCoin1>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<AptosCoin, TestCoin1>>(), &10000000000),
            0
        );

        assert!(
            coin::value<LPCoin<AptosCoin, TestCoin2>>(&lp_coins) == 1000000 - 1000,
            0
        );

        assert!(
            coin::value<LPCoin<AptosCoin, TestCoin1>>(&lp_coins_2) == 10000000000 - 1000,
            0
        );

        assert!(
            coin::balance<LPCoin<AptosCoin, TestCoin2>>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<LPCoin<AptosCoin, TestCoin2>>(resource_account_address) == 1000, 
            0
        );

        assert!(
            coin::balance<LPCoin<AptosCoin, TestCoin1>>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<LPCoin<AptosCoin, TestCoin1>>(resource_account_address) == 1000, 
            0
        );

        assert!(
            coin::balance<AptosCoin>(resource_account_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(resource_account_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin1>(resource_account_address) == 0,
            0
        );

        assert!(
            coin::balance<AptosCoin>(admin_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(admin_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin1>(admin_address) == 0,
            0
        );

        assert!(
            exists<LiquidityPool<AptosCoin, TestCoin2>>(resource_account_address),
            0
        );
        let liquidity_pool = 
            borrow_global<LiquidityPool<AptosCoin, TestCoin2>>(resource_account_address);
        assert!(
            coin::value<AptosCoin>(&liquidity_pool.coin_a_reserve) == coin_1_supply_amount,
            0
        );
        assert!(
            coin::value<TestCoin2>(&liquidity_pool.coin_b_reserve) == coin_2_supply_amount,
            0
        );

        assert!(
            exists<LiquidityPool<AptosCoin, TestCoin1>>(resource_account_address),
            0
        );
        let liquidity_pool_2 = 
            borrow_global<LiquidityPool<AptosCoin, TestCoin1>>(resource_account_address);
        assert!(
            coin::value<AptosCoin>(&liquidity_pool_2.coin_a_reserve) == coin_1_supply_amount_2,
            0
        );
        assert!(
            coin::value<TestCoin1>(&liquidity_pool_2.coin_b_reserve) == coin_2_supply_amount_2,
            0
        );

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);

        coin::deposit<LPCoin<AptosCoin, TestCoin2>>(admin_address, lp_coins);
        coin::deposit<LPCoin<AptosCoin, TestCoin1>>(admin_address, lp_coins_2);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter<CreateLiquidityPoolEvent>(&state.create_liquidity_pool_events) == 2, 0);
        assert!(event::counter<SupplyLiquidityEvent>(&state.supply_liquidity_events) == 2, 0);
        assert!(event::counter<RemoveLiquidityEvent>(&state.remove_liquidity_events) == 0, 0);
        assert!(event::counter<SwapEvent>(&state.swap_events) == 0, 0);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    fun test_supply_liquidity_success_supplied_additional_liquidity_coin_2_and_aptos_coin(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<AptosCoin, TestCoin2>>(admin);
        coin::register<AptosCoin>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<AptosCoin>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<AptosCoin, TestCoin2>();

        let coin_1_supply_amount = 100 * math64::pow(10, (coin::decimals<AptosCoin>() as u64));
        let coin_2_supply_amount = 100 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let lp_coins = supply_liquidity<AptosCoin, TestCoin2>(
            coin::mint<AptosCoin>(coin_1_supply_amount, &mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap)
        );

        let coin_1_supply_amount_2 = 100 * math64::pow(10, (coin::decimals<AptosCoin>() as u64));
        let coin_2_supply_amount_2 = 100 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let lp_coins_2 = supply_liquidity<AptosCoin, TestCoin2>(
            coin::mint<AptosCoin>(coin_1_supply_amount_2, &mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount_2, &coin_2_mint_cap)
        );

        let resource_account_address = @lp_account;

        assert!(
            option::is_some(&coin::supply<LPCoin<AptosCoin, TestCoin2>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<AptosCoin, TestCoin2>>(), &2000000),
            0
        );

        assert!(
            coin::value<LPCoin<AptosCoin, TestCoin2>>(&lp_coins) == 1000000 - 1000,
            0
        );
        assert!(
            coin::value<LPCoin<AptosCoin, TestCoin2>>(&lp_coins_2) == 1000000,
            0
        );

        assert!(
            coin::balance<LPCoin<AptosCoin, TestCoin2>>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<LPCoin<AptosCoin, TestCoin2>>(resource_account_address) == 1000, 
            0
        );

        assert!(
            coin::balance<AptosCoin>(resource_account_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(resource_account_address) == 0,
            0
        );

        assert!(
            coin::balance<AptosCoin>(admin_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(admin_address) == 0,
            0
        );

        assert!(
            coin::balance<AptosCoin>(resource_account_address) == 0, 
            0
        );
        assert!(
            coin::balance<TestCoin2>(resource_account_address) == 0, 
            0
        );
        assert!(
            coin::balance<AptosCoin>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<TestCoin2>(admin_address) == 0, 
            0
        );

        assert!(
            exists<LiquidityPool<AptosCoin, TestCoin2>>(resource_account_address),
            0
        );
        let liquidity_pool = 
            borrow_global<LiquidityPool<AptosCoin, TestCoin2>>(resource_account_address);
        assert!(
            coin::value<AptosCoin>(&liquidity_pool.coin_a_reserve) == coin_1_supply_amount + coin_1_supply_amount_2,
            0
        );
        assert!(
            coin::value<TestCoin2>(&liquidity_pool.coin_b_reserve) == coin_2_supply_amount + coin_2_supply_amount_2,
            0
        );

        coin::destroy_mint_cap(coin_2_mint_cap);
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);

        coin::deposit<LPCoin<AptosCoin, TestCoin2>>(admin_address, lp_coins);
        coin::deposit<LPCoin<AptosCoin, TestCoin2>>(admin_address, lp_coins_2);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter<CreateLiquidityPoolEvent>(&state.create_liquidity_pool_events) == 1, 0);
        assert!(event::counter<SupplyLiquidityEvent>(&state.supply_liquidity_events) == 2, 0);
        assert!(event::counter<RemoveLiquidityEvent>(&state.remove_liquidity_events) == 0, 0);
        assert!(event::counter<SwapEvent>(&state.swap_events) == 0, 0);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    fun test_supply_liquidity_success_supplied_additional_liquidity_coin_2_and_aptos_coin_non_optimal(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<AptosCoin, TestCoin2>>(admin);
        coin::register<AptosCoin>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<AptosCoin>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<AptosCoin, TestCoin2>();

        let coin_1_supply_amount = 100 * math64::pow(10, (coin::decimals<AptosCoin>() as u64));
        let coin_2_supply_amount = 100 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let lp_coins = supply_liquidity<AptosCoin, TestCoin2>(
            coin::mint<AptosCoin>(coin_1_supply_amount, &mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap)
        );

        let coin_1_supply_amount_2 = 100 * math64::pow(10, (coin::decimals<AptosCoin>() as u64));
        let coin_2_supply_amount_2 = 50 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let lp_coins_2 = supply_liquidity<AptosCoin, TestCoin2>(
            coin::mint<AptosCoin>(coin_1_supply_amount_2, &mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount_2, &coin_2_mint_cap)
        );

        let resource_account_address = @lp_account;

        assert!(
            option::is_some(&coin::supply<LPCoin<AptosCoin, TestCoin2>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<AptosCoin, TestCoin2>>(), &1500000),
            0
        );

        assert!(
            coin::value<LPCoin<AptosCoin, TestCoin2>>(&lp_coins) == 1000000 - 1000,
            0
        );
        assert!(
            coin::value<LPCoin<AptosCoin, TestCoin2>>(&lp_coins_2) == 500000,
            0
        );

        assert!(
            coin::balance<LPCoin<AptosCoin, TestCoin2>>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<LPCoin<AptosCoin, TestCoin2>>(resource_account_address) == 1000, 
            0
        );

        assert!(
            coin::balance<AptosCoin>(resource_account_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(resource_account_address) == 0,
            0
        );

        assert!(
            coin::balance<AptosCoin>(admin_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(admin_address) == 0,
            0
        );

        assert!(
            coin::balance<AptosCoin>(resource_account_address) == 0, 
            0
        );
        assert!(
            coin::balance<TestCoin2>(resource_account_address) == 0, 
            0
        );
        assert!(
            coin::balance<AptosCoin>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<TestCoin2>(admin_address) == 0, 
            0
        );

        assert!(
            exists<LiquidityPool<AptosCoin, TestCoin2>>(resource_account_address),
            0
        );
        let liquidity_pool = 
            borrow_global<LiquidityPool<AptosCoin, TestCoin2>>(resource_account_address);
        assert!(
            coin::value<AptosCoin>(&liquidity_pool.coin_a_reserve) == coin_1_supply_amount + coin_1_supply_amount_2,
            0
        );
        assert!(
            coin::value<TestCoin2>(&liquidity_pool.coin_b_reserve) == coin_2_supply_amount + coin_2_supply_amount_2,
            0
        );

        coin::destroy_mint_cap(coin_2_mint_cap);
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);

        coin::deposit<LPCoin<AptosCoin, TestCoin2>>(admin_address, lp_coins);
        coin::deposit<LPCoin<AptosCoin, TestCoin2>>(admin_address, lp_coins_2);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter<CreateLiquidityPoolEvent>(&state.create_liquidity_pool_events) == 1, 0);
        assert!(event::counter<SupplyLiquidityEvent>(&state.supply_liquidity_events) == 2, 0);
        assert!(event::counter<RemoveLiquidityEvent>(&state.remove_liquidity_events) == 0, 0);
        assert!(event::counter<SwapEvent>(&state.swap_events) == 0, 0);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    fun test_supply_liquidity_success_supplied_additional_liquidity_coin_2_and_aptos_coin_non_optimal_2(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<AptosCoin, TestCoin2>>(admin);
        coin::register<AptosCoin>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<AptosCoin>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<AptosCoin, TestCoin2>();

        let coin_1_supply_amount = 10 * math64::pow(10, (coin::decimals<AptosCoin>() as u64));
        let coin_2_supply_amount = 1000 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let lp_coins = supply_liquidity<AptosCoin, TestCoin2>(
            coin::mint<AptosCoin>(coin_1_supply_amount, &mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap)
        );

        let coin_1_supply_amount_2 = 10 * math64::pow(10, (coin::decimals<AptosCoin>() as u64));
        let coin_2_supply_amount_2 = 50 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let lp_coins_2 = supply_liquidity<AptosCoin, TestCoin2>(
            coin::mint<AptosCoin>(coin_1_supply_amount_2, &mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount_2, &coin_2_mint_cap)
        );

        let resource_account_address = @lp_account;

        assert!(
            option::is_some(&coin::supply<LPCoin<AptosCoin, TestCoin2>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<AptosCoin, TestCoin2>>(), &1050000),
            0
        );

        assert!(
            coin::value<LPCoin<AptosCoin, TestCoin2>>(&lp_coins) == 1000000 - 1000,
            0
        );
        assert!(
            coin::value<LPCoin<AptosCoin, TestCoin2>>(&lp_coins_2) == 50000,
            0
        );

        assert!(
            coin::balance<LPCoin<AptosCoin, TestCoin2>>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<LPCoin<AptosCoin, TestCoin2>>(resource_account_address) == 1000, 
            0
        );

        assert!(
            coin::balance<AptosCoin>(resource_account_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(resource_account_address) == 0,
            0
        );

        assert!(
            coin::balance<AptosCoin>(admin_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(admin_address) == 0,
            0
        );

        assert!(
            coin::balance<AptosCoin>(resource_account_address) == 0, 
            0
        );
        assert!(
            coin::balance<TestCoin2>(resource_account_address) == 0, 
            0
        );
        assert!(
            coin::balance<AptosCoin>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<TestCoin2>(admin_address) == 0, 
            0
        );

        assert!(
            exists<LiquidityPool<AptosCoin, TestCoin2>>(resource_account_address),
            0
        );
        let liquidity_pool = 
            borrow_global<LiquidityPool<AptosCoin, TestCoin2>>(resource_account_address);
        assert!(
            coin::value<AptosCoin>(&liquidity_pool.coin_a_reserve) == coin_1_supply_amount + coin_1_supply_amount_2,
            0
        );
        assert!(
            coin::value<TestCoin2>(&liquidity_pool.coin_b_reserve) == coin_2_supply_amount + coin_2_supply_amount_2,
            0
        );

        coin::destroy_mint_cap(coin_2_mint_cap);
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);

        coin::deposit<LPCoin<AptosCoin, TestCoin2>>(admin_address, lp_coins);
        coin::deposit<LPCoin<AptosCoin, TestCoin2>>(admin_address, lp_coins_2);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter<CreateLiquidityPoolEvent>(&state.create_liquidity_pool_events) == 1, 0);
        assert!(event::counter<SupplyLiquidityEvent>(&state.supply_liquidity_events) == 2, 0);
        assert!(event::counter<RemoveLiquidityEvent>(&state.remove_liquidity_events) == 0, 0);
        assert!(event::counter<SwapEvent>(&state.swap_events) == 0, 0);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    #[expected_failure(abort_code = ECodeForAllErrors, location = Self)]
    fun test_supply_liquidity_failure_coins_wrong_order(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<TestCoin1, TestCoin2>>(admin);
        coin::register<TestCoin1>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<TestCoin1>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<TestCoin1, TestCoin2>();

        let coin_1_supply_amount = 1000;
        let coin_2_supply_amount = 1000;
        let lp_coins = supply_liquidity<TestCoin2, TestCoin1>(
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap),
            coin::mint<TestCoin1>(coin_1_supply_amount, &coin_1_mint_cap)
        );

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);

        coin::deposit<LPCoin<TestCoin2, TestCoin1>>(admin_address, lp_coins);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    #[expected_failure(abort_code = ECodeForAllErrors, location = Self)]
    fun test_supply_liquidity_failure_coins_are_the_same(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<TestCoin1, TestCoin2>>(admin);
        coin::register<TestCoin1>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<TestCoin1>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<TestCoin1, TestCoin2>();

        let coin_1_supply_amount = 1000;
        let coin_2_supply_amount = 1000;
        let lp_coins = supply_liquidity<TestCoin2, TestCoin2>(
            coin::mint<TestCoin2>(coin_1_supply_amount, &coin_2_mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap)
        );

        let resource_account_address = @lp_account;

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);

        coin::deposit<LPCoin<TestCoin2, TestCoin2>>(admin_address, lp_coins);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter<CreateLiquidityPoolEvent>(&state.create_liquidity_pool_events) == 0, 0);
        assert!(event::counter<SupplyLiquidityEvent>(&state.supply_liquidity_events) == 0, 0);
        assert!(event::counter<RemoveLiquidityEvent>(&state.remove_liquidity_events) == 0, 0);
        assert!(event::counter<SwapEvent>(&state.swap_events) == 0, 0);
    }
    
    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    #[expected_failure(abort_code = ECodeForAllErrors, location = Self)]
    fun test_supply_liquidity_failure_pool_does_not_exist(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<TestCoin1, TestCoin2>>(admin);
        coin::register<TestCoin1>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<TestCoin1>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        let coin_1_supply_amount = 1000;
        let coin_2_supply_amount = 1000;
        let lp_coins = supply_liquidity<TestCoin1, TestCoin2>(
            coin::mint<TestCoin1>(coin_1_supply_amount, &coin_1_mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap)
        );

        let resource_account_address = @lp_account;

        assert!(
            option::is_some(&coin::supply<LPCoin<TestCoin1, TestCoin2>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<TestCoin1, TestCoin2>>(), &1000),
            0
        );

        assert!(
            coin::value<LPCoin<TestCoin1, TestCoin2>>(&lp_coins) == 0,
            0
        );

        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(resource_account_address) == 1000, 
            0
        );

        assert!(
            coin::balance<TestCoin1>(resource_account_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(resource_account_address) == 0,
            0
        );

        assert!(
            coin::balance<TestCoin1>(admin_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(admin_address) == 0,
            0
        );

        assert!(
            exists<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address),
            0
        );
        let liquidity_pool = 
            borrow_global<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address);
        assert!(
            coin::value<TestCoin1>(&liquidity_pool.coin_a_reserve) == coin_1_supply_amount,
            0
        );
        assert!(
            coin::value<TestCoin2>(&liquidity_pool.coin_b_reserve) == coin_2_supply_amount,
            0
        );

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);

        coin::deposit<LPCoin<TestCoin1, TestCoin2>>(admin_address, lp_coins);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter<CreateLiquidityPoolEvent>(&state.create_liquidity_pool_events) == 0, 0);
        assert!(event::counter<SupplyLiquidityEvent>(&state.supply_liquidity_events) == 0, 0);
        assert!(event::counter<RemoveLiquidityEvent>(&state.remove_liquidity_events) == 0, 0);
        assert!(event::counter<SwapEvent>(&state.swap_events) == 0, 0);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    fun test_swap_success_1_optimal_amount_coin_1_and_2(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<TestCoin1, TestCoin2>>(admin);
        coin::register<TestCoin1>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<TestCoin1>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<TestCoin1, TestCoin2>();

        let coin_1_supply_amount = 10000 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let coin_2_supply_amount = 10000 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let lp_coins = supply_liquidity<TestCoin1, TestCoin2>(
            coin::mint<TestCoin1>(coin_1_supply_amount, &coin_1_mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap)
        );

        let amount_coin_a_in = 10 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let coin_a_in = coin::mint<TestCoin1>(amount_coin_a_in, &coin_1_mint_cap);
        let coin_b_in = coin::zero<TestCoin2>();
        let amount_coin_b_out = 9 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let amount_coin_a_out = 0;

        let (coin_a_out, coin_b_out) = swap(
            coin_a_in,
            amount_coin_a_out, 
            coin_b_in,
            amount_coin_b_out
        );

        let resource_account_address = @lp_account;

        assert!(
            option::is_some(&coin::supply<LPCoin<TestCoin1, TestCoin2>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<TestCoin1, TestCoin2>>(), &100000000),
            0
        );

        assert!(
            coin::value<LPCoin<TestCoin1, TestCoin2>>(&lp_coins) ==  100000000 - 1000,
            0
        );

        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(resource_account_address) == 1000, 
            0
        );

        assert!(
            coin::balance<TestCoin1>(resource_account_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(resource_account_address) == 0,
            0
        );

        assert!(
            coin::balance<TestCoin1>(admin_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(admin_address) == 0,
            0
        );

        assert!(
            exists<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address),
            0
        );
        let liquidity_pool = 
            borrow_global<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address);
        assert!(
            coin::value<TestCoin1>(&liquidity_pool.coin_a_reserve) == coin_1_supply_amount + amount_coin_a_in,
            0
        );
        assert!(
            coin::value<TestCoin2>(&liquidity_pool.coin_b_reserve) == coin_2_supply_amount - amount_coin_b_out,
            0
        );

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);

        coin::deposit<LPCoin<TestCoin1, TestCoin2>>(admin_address, lp_coins);   
        coin::deposit<TestCoin1>(admin_address, coin_a_out);
        coin::deposit<TestCoin2>(admin_address, coin_b_out);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter<CreateLiquidityPoolEvent>(&state.create_liquidity_pool_events) == 1, 0);
        assert!(event::counter<SupplyLiquidityEvent>(&state.supply_liquidity_events) == 1, 0);
        assert!(event::counter<RemoveLiquidityEvent>(&state.remove_liquidity_events) == 0, 0);
        assert!(event::counter<SwapEvent>(&state.swap_events) == 1, 0);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    fun test_swap_success_2_optimal_amount_coin_1_and_2(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<TestCoin1, TestCoin2>>(admin);
        coin::register<TestCoin1>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<TestCoin1>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<TestCoin1, TestCoin2>();

        let coin_1_supply_amount = 10000 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let coin_2_supply_amount = 10000 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let lp_coins = supply_liquidity<TestCoin1, TestCoin2>(
            coin::mint<TestCoin1>(coin_1_supply_amount, &coin_1_mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap)
        );

        let amount_coin_a_in = 500 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let coin_a_in = coin::mint<TestCoin1>(amount_coin_a_in, &coin_1_mint_cap);
        let coin_b_in = coin::zero<TestCoin2>();
        let amount_coin_b_out = 434 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let amount_coin_a_out = 0;

        let (coin_a_out, coin_b_out) = swap(
            coin_a_in,
            amount_coin_a_out, 
            coin_b_in,
            amount_coin_b_out
        );

        let resource_account_address = @lp_account;

        assert!(
            option::is_some(&coin::supply<LPCoin<TestCoin1, TestCoin2>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<TestCoin1, TestCoin2>>(), &100000000),
            0
        );

        assert!(
            coin::value<LPCoin<TestCoin1, TestCoin2>>(&lp_coins) ==  100000000 - 1000,
            0
        );

        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(resource_account_address) == 1000, 
            0
        );

        assert!(
            coin::balance<TestCoin1>(resource_account_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(resource_account_address) == 0,
            0
        );

        assert!(
            coin::balance<TestCoin1>(admin_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(admin_address) == 0,
            0
        );

        assert!(
            exists<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address),
            0
        );
        let liquidity_pool = 
            borrow_global<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address);
        assert!(
            coin::value<TestCoin1>(&liquidity_pool.coin_a_reserve) == coin_1_supply_amount + amount_coin_a_in,
            0
        );
        assert!(
            coin::value<TestCoin2>(&liquidity_pool.coin_b_reserve) == coin_2_supply_amount - amount_coin_b_out,
            0
        );

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);

        coin::deposit<LPCoin<TestCoin1, TestCoin2>>(admin_address, lp_coins);   
        coin::deposit<TestCoin1>(admin_address, coin_a_out);
        coin::deposit<TestCoin2>(admin_address, coin_b_out);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter<CreateLiquidityPoolEvent>(&state.create_liquidity_pool_events) == 1, 0);
        assert!(event::counter<SupplyLiquidityEvent>(&state.supply_liquidity_events) == 1, 0);
        assert!(event::counter<RemoveLiquidityEvent>(&state.remove_liquidity_events) == 0, 0);
        assert!(event::counter<SwapEvent>(&state.swap_events) == 1, 0);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    fun test_swap_success_not_optimal_amount_coin_1_and_2(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<TestCoin1, TestCoin2>>(admin);
        coin::register<TestCoin1>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<TestCoin1>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<TestCoin1, TestCoin2>();

        let coin_1_supply_amount = 10000 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let coin_2_supply_amount = 10000 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let lp_coins = supply_liquidity<TestCoin1, TestCoin2>(
            coin::mint<TestCoin1>(coin_1_supply_amount, &coin_1_mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap)
        );

        let amount_coin_a_in = 10 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let coin_a_in = coin::mint<TestCoin1>(amount_coin_a_in, &coin_1_mint_cap);
        let coin_b_in = coin::zero<TestCoin2>();
        let amount_coin_b_out = 4 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let amount_coin_a_out = 0;

        let (coin_a_out, coin_b_out) = swap(
            coin_a_in,
            amount_coin_a_out, 
            coin_b_in,
            amount_coin_b_out
        );

        let resource_account_address = @lp_account;

        assert!(
            option::is_some(&coin::supply<LPCoin<TestCoin1, TestCoin2>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<TestCoin1, TestCoin2>>(), &100000000),
            0
        );

        assert!(
            coin::value<LPCoin<TestCoin1, TestCoin2>>(&lp_coins) ==  100000000 - 1000,
            0
        );

        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(resource_account_address) == 1000, 
            0
        );

        assert!(
            coin::balance<TestCoin1>(resource_account_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(resource_account_address) == 0,
            0
        );

        assert!(
            coin::balance<TestCoin1>(admin_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(admin_address) == 0,
            0
        );

        assert!(
            exists<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address),
            0
        );
        let liquidity_pool = 
            borrow_global<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address);
        assert!(
            coin::value<TestCoin1>(&liquidity_pool.coin_a_reserve) == coin_1_supply_amount + amount_coin_a_in,
            0
        );
        assert!(
            coin::value<TestCoin2>(&liquidity_pool.coin_b_reserve) == coin_2_supply_amount - amount_coin_b_out,
            0
        );

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);

        coin::deposit<LPCoin<TestCoin1, TestCoin2>>(admin_address, lp_coins);   
        coin::deposit<TestCoin1>(admin_address, coin_a_out);
        coin::deposit<TestCoin2>(admin_address, coin_b_out);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter<CreateLiquidityPoolEvent>(&state.create_liquidity_pool_events) == 1, 0);
        assert!(event::counter<SupplyLiquidityEvent>(&state.supply_liquidity_events) == 1, 0);
        assert!(event::counter<RemoveLiquidityEvent>(&state.remove_liquidity_events) == 0, 0);
        assert!(event::counter<SwapEvent>(&state.swap_events) == 1, 0);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    fun test_swap_success_worst_amount_coin_1_and_2(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<TestCoin1, TestCoin2>>(admin);
        coin::register<TestCoin1>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<TestCoin1>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<TestCoin1, TestCoin2>();

        let coin_1_supply_amount = 10000 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let coin_2_supply_amount = 10000 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let lp_coins = supply_liquidity<TestCoin1, TestCoin2>(
            coin::mint<TestCoin1>(coin_1_supply_amount, &coin_1_mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap)
        );

        let amount_coin_a_in = 10 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let coin_a_in = coin::mint<TestCoin1>(amount_coin_a_in, &coin_1_mint_cap);
        let coin_b_in = coin::zero<TestCoin2>();
        let amount_coin_b_out = 0 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let amount_coin_a_out = 0;

        let (coin_a_out, coin_b_out) = swap(
            coin_a_in,
            amount_coin_a_out, 
            coin_b_in,
            amount_coin_b_out
        );

        let resource_account_address = @lp_account;

        assert!(
            option::is_some(&coin::supply<LPCoin<TestCoin1, TestCoin2>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<TestCoin1, TestCoin2>>(), &100000000),
            0
        );

        assert!(
            coin::value<LPCoin<TestCoin1, TestCoin2>>(&lp_coins) ==  100000000 - 1000,
            0
        );

        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(resource_account_address) == 1000, 
            0
        );

        assert!(
            coin::balance<TestCoin1>(resource_account_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(resource_account_address) == 0,
            0
        );

        assert!(
            coin::balance<TestCoin1>(admin_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(admin_address) == 0,
            0
        );

        assert!(
            exists<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address),
            0
        );
        let liquidity_pool = 
            borrow_global<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address);
        assert!(
            coin::value<TestCoin1>(&liquidity_pool.coin_a_reserve) == coin_1_supply_amount + amount_coin_a_in,
            0
        );
        assert!(
            coin::value<TestCoin2>(&liquidity_pool.coin_b_reserve) == coin_2_supply_amount - amount_coin_b_out,
            0
        );

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);

        coin::deposit<LPCoin<TestCoin1, TestCoin2>>(admin_address, lp_coins);   
        coin::deposit<TestCoin1>(admin_address, coin_a_out);
        coin::deposit<TestCoin2>(admin_address, coin_b_out);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter<CreateLiquidityPoolEvent>(&state.create_liquidity_pool_events) == 1, 0);
        assert!(event::counter<SupplyLiquidityEvent>(&state.supply_liquidity_events) == 1, 0);
        assert!(event::counter<RemoveLiquidityEvent>(&state.remove_liquidity_events) == 0, 0);
        assert!(event::counter<SwapEvent>(&state.swap_events) == 1, 0);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    fun test_swap_success_b_for_a_non_optimal_amount_coin_1_and_2(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<TestCoin1, TestCoin2>>(admin);
        coin::register<TestCoin1>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<TestCoin1>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<TestCoin1, TestCoin2>();

        let coin_1_supply_amount = 10000 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let coin_2_supply_amount = 10000 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let lp_coins = supply_liquidity<TestCoin1, TestCoin2>(
            coin::mint<TestCoin1>(coin_1_supply_amount, &coin_1_mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap)
        );

        let amount_coin_b_in = 10 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let coin_b_in = coin::mint<TestCoin2>(amount_coin_b_in, &coin_2_mint_cap);
        let coin_a_in = coin::zero<TestCoin1>();
        let amount_coin_a_out = 6 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let amount_coin_b_out = 0;

        let (coin_a_out, coin_b_out) = swap(
            coin_a_in,
            amount_coin_a_out, 
            coin_b_in,
            amount_coin_b_out
        );

        let resource_account_address = @lp_account;

        assert!(
            option::is_some(&coin::supply<LPCoin<TestCoin1, TestCoin2>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<TestCoin1, TestCoin2>>(), &100000000),
            0
        );

        assert!(
            coin::value<LPCoin<TestCoin1, TestCoin2>>(&lp_coins) ==  100000000 - 1000,
            0
        );

        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(resource_account_address) == 1000, 
            0
        );

        assert!(
            coin::balance<TestCoin1>(resource_account_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(resource_account_address) == 0,
            0
        );

        assert!(
            coin::balance<TestCoin1>(admin_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(admin_address) == 0,
            0
        );

        assert!(
            exists<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address),
            0
        );
        let liquidity_pool = 
            borrow_global<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address);
        assert!(
            coin::value<TestCoin1>(&liquidity_pool.coin_a_reserve) == coin_1_supply_amount - amount_coin_a_out,
            0
        );
        assert!(
            coin::value<TestCoin2>(&liquidity_pool.coin_b_reserve) == coin_2_supply_amount + amount_coin_b_in,
            0
        );

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);

        coin::deposit<LPCoin<TestCoin1, TestCoin2>>(admin_address, lp_coins);   
        coin::deposit<TestCoin1>(admin_address, coin_a_out);
        coin::deposit<TestCoin2>(admin_address, coin_b_out);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter<CreateLiquidityPoolEvent>(&state.create_liquidity_pool_events) == 1, 0);
        assert!(event::counter<SupplyLiquidityEvent>(&state.supply_liquidity_events) == 1, 0);
        assert!(event::counter<RemoveLiquidityEvent>(&state.remove_liquidity_events) == 0, 0);
        assert!(event::counter<SwapEvent>(&state.swap_events) == 1, 0);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    fun test_swap_success_two_way_trade_even_coin_1_and_2(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<TestCoin1, TestCoin2>>(admin);
        coin::register<TestCoin1>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<TestCoin1>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<TestCoin1, TestCoin2>();

        let coin_1_supply_amount = 10000 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let coin_2_supply_amount = 10000 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let lp_coins = supply_liquidity<TestCoin1, TestCoin2>(
            coin::mint<TestCoin1>(coin_1_supply_amount, &coin_1_mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap)
        );

        let amount_coin_a_in = 10 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let amount_coin_b_out = 9 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let amount_coin_a_out = amount_coin_a_in;
        let coin_a_in = coin::mint<TestCoin1>(amount_coin_a_in, &coin_1_mint_cap);
        let coin_b_in = coin::mint<TestCoin2>(amount_coin_b_out, &coin_2_mint_cap);

        let (coin_a_out, coin_b_out) = swap(
            coin_a_in,
            amount_coin_a_out, 
            coin_b_in,
            amount_coin_b_out
        );

        let resource_account_address = @lp_account;

        assert!(
            option::is_some(&coin::supply<LPCoin<TestCoin1, TestCoin2>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<TestCoin1, TestCoin2>>(), &100000000),
            0
        );

        assert!(
            coin::value<LPCoin<TestCoin1, TestCoin2>>(&lp_coins) ==  100000000 - 1000,
            0
        );

        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(resource_account_address) == 1000, 
            0
        );

        assert!(
            coin::balance<TestCoin1>(resource_account_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(resource_account_address) == 0,
            0
        );

        assert!(
            coin::balance<TestCoin1>(admin_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(admin_address) == 0,
            0
        );

        assert!(
            exists<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address),
            0
        );
        let liquidity_pool = 
            borrow_global<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address);
        assert!(
            coin::value<TestCoin1>(&liquidity_pool.coin_a_reserve) == coin_1_supply_amount ,
            0
        );
        assert!(
            coin::value<TestCoin2>(&liquidity_pool.coin_b_reserve) == coin_2_supply_amount ,
            0
        );

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);

        coin::deposit<LPCoin<TestCoin1, TestCoin2>>(admin_address, lp_coins);   
        coin::deposit<TestCoin1>(admin_address, coin_a_out);
        coin::deposit<TestCoin2>(admin_address, coin_b_out);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter<CreateLiquidityPoolEvent>(&state.create_liquidity_pool_events) == 1, 0);
        assert!(event::counter<SupplyLiquidityEvent>(&state.supply_liquidity_events) == 1, 0);
        assert!(event::counter<RemoveLiquidityEvent>(&state.remove_liquidity_events) == 0, 0);
        assert!(event::counter<SwapEvent>(&state.swap_events) == 1, 0);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    fun test_swap_success_two_way_trade_non_even_coin_1_and_2(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<TestCoin1, TestCoin2>>(admin);
        coin::register<TestCoin1>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<TestCoin1>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<TestCoin1, TestCoin2>();

        let coin_1_supply_amount = 10000 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let coin_2_supply_amount = 10000 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let lp_coins = supply_liquidity<TestCoin1, TestCoin2>(
            coin::mint<TestCoin1>(coin_1_supply_amount, &coin_1_mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap)
        );

        let amount_coin_a_in = 10 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let amount_coin_b_out = 9 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let amount_coin_b_in = 4 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let amount_coin_a_out = 19 * math64::pow(10, (TEST_COIN1_DECIMALS as u64) - 1);
        let coin_a_in = coin::mint<TestCoin1>(amount_coin_a_in, &coin_1_mint_cap);
        let coin_b_in = coin::mint<TestCoin2>(amount_coin_b_in, &coin_2_mint_cap);

        let (coin_a_out, coin_b_out) = swap(
            coin_a_in,
            amount_coin_a_out, 
            coin_b_in,
            amount_coin_b_out
        );

        let resource_account_address = @lp_account;

        assert!(
            option::is_some(&coin::supply<LPCoin<TestCoin1, TestCoin2>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<TestCoin1, TestCoin2>>(), &100000000),
            0
        );

        assert!(
            coin::value<LPCoin<TestCoin1, TestCoin2>>(&lp_coins) ==  100000000 - 1000,
            0
        );

        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(resource_account_address) == 1000, 
            0
        );

        assert!(
            coin::balance<TestCoin1>(resource_account_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(resource_account_address) == 0,
            0
        );

        assert!(
            coin::balance<TestCoin1>(admin_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(admin_address) == 0,
            0
        );

        assert!(
            exists<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address),
            0
        );
        let liquidity_pool = 
            borrow_global<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address);
        assert!(
            coin::value<TestCoin1>(&liquidity_pool.coin_a_reserve) == coin_1_supply_amount + amount_coin_a_in - amount_coin_a_out,
            0
        );
        assert!(
            coin::value<TestCoin2>(&liquidity_pool.coin_b_reserve) == coin_2_supply_amount + amount_coin_b_in - amount_coin_b_out,
            0
        );

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);

        coin::deposit<LPCoin<TestCoin1, TestCoin2>>(admin_address, lp_coins);   
        coin::deposit<TestCoin1>(admin_address, coin_a_out);
        coin::deposit<TestCoin2>(admin_address, coin_b_out);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter<CreateLiquidityPoolEvent>(&state.create_liquidity_pool_events) == 1, 0);
        assert!(event::counter<SupplyLiquidityEvent>(&state.supply_liquidity_events) == 1, 0);
        assert!(event::counter<RemoveLiquidityEvent>(&state.remove_liquidity_events) == 0, 0);
        assert!(event::counter<SwapEvent>(&state.swap_events) == 1, 0);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    #[expected_failure(abort_code = ECodeForAllErrors, location = Self)]
    fun test_swap_failure_coins_not_sorted(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<TestCoin1, TestCoin2>>(admin);
        coin::register<TestCoin1>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<TestCoin1>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<TestCoin1, TestCoin2>();

        let coin_1_supply_amount = 10000 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let coin_2_supply_amount = 10000 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let lp_coins = supply_liquidity<TestCoin1, TestCoin2>(
            coin::mint<TestCoin1>(coin_1_supply_amount, &coin_1_mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap)
        );

        let amount_coin_a_in = 10 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let coin_a_in = coin::mint<TestCoin1>(amount_coin_a_in, &coin_1_mint_cap);
        let coin_b_in = coin::zero<TestCoin2>();
        let amount_coin_b_out = 9 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let amount_coin_a_out = 0;

        let (coin_b_out, coin_a_out) = swap(
            coin_b_in,
            amount_coin_b_out,
            coin_a_in,
            amount_coin_a_out,
        );

        let resource_account_address = @lp_account;

        assert!(
            option::is_some(&coin::supply<LPCoin<TestCoin1, TestCoin2>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<TestCoin1, TestCoin2>>(), &100000000),
            0
        );

        assert!(
            coin::value<LPCoin<TestCoin1, TestCoin2>>(&lp_coins) ==  100000000 - 1000,
            0
        );

        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(resource_account_address) == 1000, 
            0
        );

        assert!(
            coin::balance<TestCoin1>(resource_account_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(resource_account_address) == 0,
            0
        );

        assert!(
            coin::balance<TestCoin1>(admin_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(admin_address) == 0,
            0
        );

        assert!(
            exists<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address),
            0
        );
        let liquidity_pool = 
            borrow_global<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address);
        assert!(
            coin::value<TestCoin1>(&liquidity_pool.coin_a_reserve) == coin_1_supply_amount + amount_coin_a_in,
            0
        );
        assert!(
            coin::value<TestCoin2>(&liquidity_pool.coin_b_reserve) == coin_2_supply_amount - amount_coin_b_out,
            0
        );

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);

        coin::deposit<LPCoin<TestCoin1, TestCoin2>>(admin_address, lp_coins);   
        coin::deposit<TestCoin1>(admin_address, coin_a_out);
        coin::deposit<TestCoin2>(admin_address, coin_b_out);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter<CreateLiquidityPoolEvent>(&state.create_liquidity_pool_events) == 0, 0);
        assert!(event::counter<SupplyLiquidityEvent>(&state.supply_liquidity_events) == 0, 0);
        assert!(event::counter<RemoveLiquidityEvent>(&state.remove_liquidity_events) == 0, 0);
        assert!(event::counter<SwapEvent>(&state.swap_events) == 0, 0);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    #[expected_failure(abort_code = ECodeForAllErrors, location = Self)]
    fun test_swap_failure_coins_are_the_same(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<TestCoin1, TestCoin2>>(admin);
        coin::register<TestCoin1>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<TestCoin1>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<TestCoin1, TestCoin2>();

        let coin_1_supply_amount = 10000 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let coin_2_supply_amount = 10000 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let lp_coins = supply_liquidity<TestCoin1, TestCoin2>(
            coin::mint<TestCoin1>(coin_1_supply_amount, &coin_1_mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap)
        );

        let amount_coin_a_in = 10 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let coin_a_in = coin::mint<TestCoin1>(amount_coin_a_in, &coin_1_mint_cap);
        let coin_a_in_2 = coin::mint<TestCoin1>(amount_coin_a_in, &coin_1_mint_cap);
        let amount_coin_b_out = 9 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let amount_coin_a_out = 0;

        let (coin_a_out, coin_b_out) = swap(
            coin_a_in,
            amount_coin_a_out, 
            coin_a_in_2,
            amount_coin_b_out
        );

        let resource_account_address = @lp_account;

        assert!(
            option::is_some(&coin::supply<LPCoin<TestCoin1, TestCoin2>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<TestCoin1, TestCoin2>>(), &100000000),
            0
        );

        assert!(
            coin::value<LPCoin<TestCoin1, TestCoin2>>(&lp_coins) ==  100000000 - 1000,
            0
        );

        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(resource_account_address) == 1000, 
            0
        );

        assert!(
            coin::balance<TestCoin1>(resource_account_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(resource_account_address) == 0,
            0
        );

        assert!(
            coin::balance<TestCoin1>(admin_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(admin_address) == 0,
            0
        );

        assert!(
            exists<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address),
            0
        );
        let liquidity_pool = 
            borrow_global<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address);
        assert!(
            coin::value<TestCoin1>(&liquidity_pool.coin_a_reserve) == coin_1_supply_amount + amount_coin_a_in,
            0
        );
        assert!(
            coin::value<TestCoin2>(&liquidity_pool.coin_b_reserve) == coin_2_supply_amount - amount_coin_b_out,
            0
        );

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);

        coin::deposit<LPCoin<TestCoin1, TestCoin2>>(admin_address, lp_coins);   
        coin::deposit<TestCoin1>(admin_address, coin_a_out);
        coin::deposit<TestCoin1>(admin_address, coin_b_out);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter<CreateLiquidityPoolEvent>(&state.create_liquidity_pool_events) == 0, 0);
        assert!(event::counter<SupplyLiquidityEvent>(&state.supply_liquidity_events) == 0, 0);
        assert!(event::counter<RemoveLiquidityEvent>(&state.remove_liquidity_events) == 0, 0);
        assert!(event::counter<SwapEvent>(&state.swap_events) == 0, 0);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    #[expected_failure(abort_code = ECodeForAllErrors, location = Self)]
    fun test_swap_failure_zero_coins_swapped(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<TestCoin1, TestCoin2>>(admin);
        coin::register<TestCoin1>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<TestCoin1>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<TestCoin1, TestCoin2>();

        let coin_1_supply_amount = 10000 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let coin_2_supply_amount = 10000 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let lp_coins = supply_liquidity<TestCoin1, TestCoin2>(
            coin::mint<TestCoin1>(coin_1_supply_amount, &coin_1_mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap)
        );

        let coin_a_in = coin::zero<TestCoin1>();
        let coin_b_in = coin::zero<TestCoin2>();
        let amount_coin_b_out = 0;
        let amount_coin_a_out = 0;

        let (coin_a_out, coin_b_out) = swap(
            coin_a_in,
            amount_coin_a_out, 
            coin_b_in,
            amount_coin_b_out
        );

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);

        coin::deposit<LPCoin<TestCoin1, TestCoin2>>(admin_address, lp_coins);   
        coin::deposit<TestCoin1>(admin_address, coin_a_out);
        coin::deposit<TestCoin2>(admin_address, coin_b_out);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    #[expected_failure(abort_code = ECodeForAllErrors, location = Self)]
    fun test_swap_failure_liquidity_pool_does_not_exist(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<TestCoin1, TestCoin2>>(admin);
        coin::register<TestCoin1>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<TestCoin1>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        let amount_coin_a_in = 10 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let coin_a_in = coin::mint<TestCoin1>(amount_coin_a_in, &coin_1_mint_cap);
        let coin_b_in = coin::zero<TestCoin2>();
        let amount_coin_b_out = 9 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let amount_coin_a_out = 0;

        let (coin_a_out, coin_b_out) = swap(
            coin_a_in,
            amount_coin_a_out, 
            coin_b_in,
            amount_coin_b_out
        );

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);
  
        coin::deposit<TestCoin1>(admin_address, coin_a_out);
        coin::deposit<TestCoin2>(admin_address, coin_b_out);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    #[expected_failure(abort_code = ECodeForAllErrors, location = Self)]
    fun test_swap_failure_bad_lp_value(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<TestCoin1, TestCoin2>>(admin);
        coin::register<TestCoin1>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<TestCoin1>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<TestCoin1, TestCoin2>();

        let coin_1_supply_amount = 10000 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let coin_2_supply_amount = 10000 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let lp_coins = supply_liquidity<TestCoin1, TestCoin2>(
            coin::mint<TestCoin1>(coin_1_supply_amount, &coin_1_mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap)
        );

        let amount_coin_a_in = 10 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let coin_a_in = coin::mint<TestCoin1>(amount_coin_a_in, &coin_1_mint_cap);
        let coin_b_in = coin::zero<TestCoin2>();
        let amount_coin_b_out = 10 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let amount_coin_a_out = 0;

        let (coin_a_out, coin_b_out) = swap(
            coin_a_in,
            amount_coin_a_out, 
            coin_b_in,
            amount_coin_b_out
        );

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);

        coin::deposit<LPCoin<TestCoin1, TestCoin2>>(admin_address, lp_coins);   
        coin::deposit<TestCoin1>(admin_address, coin_a_out);
        coin::deposit<TestCoin2>(admin_address, coin_b_out);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    fun test_remove_liquidity_success_redeem_half_of_the_liquidity(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<TestCoin1, TestCoin2>>(admin);
        coin::register<TestCoin1>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<TestCoin1>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<TestCoin1, TestCoin2>();

        let coin_1_supply_amount = 10 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let coin_2_supply_amount = 10 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let lp_coins = supply_liquidity<TestCoin1, TestCoin2>(
            coin::mint<TestCoin1>(coin_1_supply_amount, &coin_1_mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap)
        );

        let amount_lp_to_redeem = 100000 / 2;
        let (coin_a_out, coin_b_out) = remove_liquidity<TestCoin1, TestCoin2>(
            coin::extract(&mut lp_coins, amount_lp_to_redeem)
        );

        let resource_account_address = @lp_account;

        assert!(
            option::is_some(&coin::supply<LPCoin<TestCoin1, TestCoin2>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<TestCoin1, TestCoin2>>(), &(100000 / 2)),
            0
        );

        assert!(
            coin::value(&coin_a_out) == 5 * math64::pow(10, (TEST_COIN1_DECIMALS as u64)),
            0
        );
        assert!(
            coin::value(&coin_b_out) == 5 * math64::pow(10, (TEST_COIN2_DECIMALS as u64)),
            0
        );

        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(resource_account_address) == 1000, 
            0
        );

        assert!(
            coin::balance<TestCoin1>(resource_account_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(resource_account_address) == 0,
            0
        );

        assert!(
            coin::balance<TestCoin1>(admin_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(admin_address) == 0,
            0
        );

        assert!(
            exists<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address),
            0
        );
        let liquidity_pool = 
            borrow_global<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address);
        assert!(
            coin::value<TestCoin1>(&liquidity_pool.coin_a_reserve) == coin_1_supply_amount / 2,
            0
        );
        assert!(
            coin::value<TestCoin2>(&liquidity_pool.coin_b_reserve) == coin_2_supply_amount / 2,
            0
        );

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);

        coin::deposit<LPCoin<TestCoin1, TestCoin2>>(admin_address, lp_coins);
        coin::deposit<TestCoin1>(admin_address, coin_a_out);
        coin::deposit<TestCoin2>(admin_address, coin_b_out);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter<CreateLiquidityPoolEvent>(&state.create_liquidity_pool_events) == 1, 0);
        assert!(event::counter<SupplyLiquidityEvent>(&state.supply_liquidity_events) == 1, 0);
        assert!(event::counter<RemoveLiquidityEvent>(&state.remove_liquidity_events) == 1, 0);
        assert!(event::counter<SwapEvent>(&state.swap_events) == 0, 0);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    fun test_remove_liquidity_success_redeem_5th_of_the_liquidity(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<TestCoin1, TestCoin2>>(admin);
        coin::register<TestCoin1>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<TestCoin1>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<TestCoin1, TestCoin2>();

        let coin_1_supply_amount = 10 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let coin_2_supply_amount = 10 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let lp_coins = supply_liquidity<TestCoin1, TestCoin2>(
            coin::mint<TestCoin1>(coin_1_supply_amount, &coin_1_mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap)
        );

        let amount_lp_to_redeem = 100000 / 5;
        let (coin_a_out, coin_b_out) = remove_liquidity<TestCoin1, TestCoin2>(
            coin::extract(&mut lp_coins, amount_lp_to_redeem)
        );

        let resource_account_address = @lp_account;

        assert!(
            option::is_some(&coin::supply<LPCoin<TestCoin1, TestCoin2>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<TestCoin1, TestCoin2>>(), &(100000 * 4 / 5)),
            0
        );

        assert!(
            coin::value(&coin_a_out) == 2 * math64::pow(10, (TEST_COIN1_DECIMALS as u64)),
            0
        );
        assert!(
            coin::value(&coin_b_out) == 2 * math64::pow(10, (TEST_COIN2_DECIMALS as u64)),
            0
        );

        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(resource_account_address) == 1000, 
            0
        );

        assert!(
            coin::balance<TestCoin1>(resource_account_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(resource_account_address) == 0,
            0
        );

        assert!(
            coin::balance<TestCoin1>(admin_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(admin_address) == 0,
            0
        );

        assert!(
            exists<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address),
            0
        );
        let liquidity_pool = 
            borrow_global<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address);
        assert!(
            coin::value<TestCoin1>(&liquidity_pool.coin_a_reserve) == coin_1_supply_amount * 4 / 5,
            0
        );
        assert!(
            coin::value<TestCoin2>(&liquidity_pool.coin_b_reserve) == coin_2_supply_amount * 4 / 5,
            0
        );

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);

        coin::deposit<LPCoin<TestCoin1, TestCoin2>>(admin_address, lp_coins);
        coin::deposit<TestCoin1>(admin_address, coin_a_out);
        coin::deposit<TestCoin2>(admin_address, coin_b_out);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter<CreateLiquidityPoolEvent>(&state.create_liquidity_pool_events) == 1, 0);
        assert!(event::counter<SupplyLiquidityEvent>(&state.supply_liquidity_events) == 1, 0);
        assert!(event::counter<RemoveLiquidityEvent>(&state.remove_liquidity_events) == 1, 0);
        assert!(event::counter<SwapEvent>(&state.swap_events) == 0, 0);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    fun test_remove_liquidity_success_redeem_4_5ths_of_the_liquidity(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<TestCoin1, TestCoin2>>(admin);
        coin::register<TestCoin1>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<TestCoin1>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<TestCoin1, TestCoin2>();

        let coin_1_supply_amount = 10 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let coin_2_supply_amount = 10 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let lp_coins = supply_liquidity<TestCoin1, TestCoin2>(
            coin::mint<TestCoin1>(coin_1_supply_amount, &coin_1_mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap)
        );

        let amount_lp_to_redeem = 100000 * 4 / 5;
        let (coin_a_out, coin_b_out) = remove_liquidity<TestCoin1, TestCoin2>(
            coin::extract(&mut lp_coins, amount_lp_to_redeem)
        );

        let resource_account_address = @lp_account;

        assert!(
            option::is_some(&coin::supply<LPCoin<TestCoin1, TestCoin2>>()),
            0
        );
        assert!(
            option::contains(&coin::supply<LPCoin<TestCoin1, TestCoin2>>(), &(100000 / 5)),
            0
        );

        assert!(
            coin::value(&coin_a_out) == 8 * math64::pow(10, (TEST_COIN1_DECIMALS as u64)),
            0
        );
        assert!(
            coin::value(&coin_b_out) == 8 * math64::pow(10, (TEST_COIN2_DECIMALS as u64)),
            0
        );

        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(admin_address) == 0, 
            0
        );
        assert!(
            coin::balance<LPCoin<TestCoin1, TestCoin2>>(resource_account_address) == 1000, 
            0
        );

        assert!(
            coin::balance<TestCoin1>(resource_account_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(resource_account_address) == 0,
            0
        );

        assert!(
            coin::balance<TestCoin1>(admin_address) == 0,
            0
        );
        assert!(
            coin::balance<TestCoin2>(admin_address) == 0,
            0
        );

        assert!(
            exists<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address),
            0
        );
        let liquidity_pool = 
            borrow_global<LiquidityPool<TestCoin1, TestCoin2>>(resource_account_address);
        assert!(
            coin::value<TestCoin1>(&liquidity_pool.coin_a_reserve) == coin_1_supply_amount / 5,
            0
        );
        assert!(
            coin::value<TestCoin2>(&liquidity_pool.coin_b_reserve) == coin_2_supply_amount / 5,
            0
        );

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);

        coin::deposit<LPCoin<TestCoin1, TestCoin2>>(admin_address, lp_coins);
        coin::deposit<TestCoin1>(admin_address, coin_a_out);
        coin::deposit<TestCoin2>(admin_address, coin_b_out);

        let state = borrow_global<State>(resource_account_address);
        assert!(event::counter<CreateLiquidityPoolEvent>(&state.create_liquidity_pool_events) == 1, 0);
        assert!(event::counter<SupplyLiquidityEvent>(&state.supply_liquidity_events) == 1, 0);
        assert!(event::counter<RemoveLiquidityEvent>(&state.remove_liquidity_events) == 1, 0);
        assert!(event::counter<SwapEvent>(&state.swap_events) == 0, 0);
    }

    #[test(admin = @overmind, resource_account = @lp_account, user_1 = @0xA)]
    #[expected_failure(abort_code = ECodeForAllErrors, location = Self)]
    fun test_remove_liquidity_failure_coins_wrong_order(
        admin: &signer, 
        resource_account: &signer, 
        user_1: &signer
    ) acquires State, LiquidityPool {
       let admin_address = signer::address_of(admin);
        let user_1_address = signer::address_of(user_1);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_1_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        resource_account::create_resource_account(admin, b"lp account", x"");

        coin::register<LPCoin<TestCoin1, TestCoin2>>(admin);
        coin::register<TestCoin1>(admin);
        coin::register<TestCoin2>(admin);

        coin::register<TestCoin1>(resource_account);
        coin::register<TestCoin2>(resource_account);

        init_module(resource_account);

        let (coin_1_burn_cap, coin_1_freeze_cap, coin_1_mint_cap) = coin::initialize<TestCoin1>(
            resource_account, 
            string::utf8(TEST_COIN1_NAME),
            string::utf8(TEST_COIN1_SYMBOL),
            TEST_COIN1_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_1_freeze_cap);
        coin::destroy_burn_cap(coin_1_burn_cap);

        let (coin_2_burn_cap, coin_2_freeze_cap, coin_2_mint_cap) = coin::initialize<TestCoin2>(
            resource_account, 
            string::utf8(TEST_COIN2_NAME),
            string::utf8(TEST_COIN2_SYMBOL),
            TEST_COIN2_DECIMALS,
            true
        );
        coin::destroy_freeze_cap(coin_2_freeze_cap);
        coin::destroy_burn_cap(coin_2_burn_cap);

        create_liquidity_pool<TestCoin1, TestCoin2>();

        let coin_1_supply_amount = 10 * math64::pow(10, (TEST_COIN1_DECIMALS as u64));
        let coin_2_supply_amount = 10 * math64::pow(10, (TEST_COIN2_DECIMALS as u64));
        let lp_coins = supply_liquidity<TestCoin1, TestCoin2>(
            coin::mint<TestCoin1>(coin_1_supply_amount, &coin_1_mint_cap),
            coin::mint<TestCoin2>(coin_2_supply_amount, &coin_2_mint_cap)
        );

        let amount_lp_to_redeem = 0;
        let (coin_a_out, coin_b_out) = remove_liquidity<TestCoin1, TestCoin2>(
            coin::extract(&mut lp_coins, amount_lp_to_redeem)
        );

        coin::destroy_mint_cap(coin_1_mint_cap);
        coin::destroy_mint_cap(coin_2_mint_cap);

        coin::deposit<LPCoin<TestCoin1, TestCoin2>>(admin_address, lp_coins);
        coin::deposit<TestCoin1>(admin_address, coin_a_out);
        coin::deposit<TestCoin2>(admin_address, coin_b_out);
    }
}
