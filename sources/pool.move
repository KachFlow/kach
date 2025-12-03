module kach::pool {
    use std::signer;
    use std::string::String;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::event;
    use aptos_framework::timestamp;

    use kach::governance;

    // Friend modules that can call internal functions
    friend kach::credit_engine;
    friend kach::attestator;

    /// Error when an action is blocked because the pool is paused.
    const E_POOL_PAUSED: u64 = 1;
    /// Error when there is not enough liquid capital to honor a withdrawal or draw.
    const E_INSUFFICIENT_LIQUIDITY: u64 = 2;
    /// Error when an action would push utilization above the configured maximum.
    const E_UTILIZATION_TOO_HIGH: u64 = 3;

    // ===== Tranche Identifiers =====

    /// Identifier for the junior tranche
    const TRANCHE_JUNIOR: u8 = 1;
    /// Identifier for the senior tranche
    const TRANCHE_SENIOR: u8 = 0;

    /// Pool configuration and state for a specific fungible asset
    /// FA is phantom type representing the asset (e.g., USDC, USDT)
    struct Pool<phantom FA> has key {
        // Asset metadata reference
        fa_metadata: Object<Metadata>,

        // Liquidity tracking
        total_deposits: u64,
        total_borrowed: u64,

        // Deposits per tranche
        senior_deposits: u64,
        junior_deposits: u64,

        // NAV multipliers per tranche (scaled by 1e18)
        // Starts at 1e18, increases as yield accrues
        senior_nav_multiplier: u128,
        junior_nav_multiplier: u128,

        // Utilization cap (e.g., 8000 = 80% max utilization)
        max_utilization_bps: u64,

        // Protocol reserve
        protocol_reserve_balance: u64,
        protocol_fee_bps: u64, // % of interest to reserve (e.g., 700 = 7%)

        // Counters
        total_position_nfts_minted: u64,
        total_prts_minted: u64,

        // State
        is_paused: bool
    }

    /// Events
    #[event]
    struct PoolInitialized has drop, store {
        pool_address: address,
        asset_metadata_address: address, // Address of the fungible asset metadata object
        asset_symbol: String, // e.g., "USDC", "USDT"
        asset_name: String, // e.g., "USD Coin", "Tether USD"
        timestamp: u64
    }

    #[event]
    struct Deposited has drop, store {
        depositor: address,
        amount: u64,
        tranche: u8,
        shares_issued: u64,
        timestamp: u64
    }

    #[event]
    struct Withdrawn has drop, store {
        withdrawer: address,
        amount: u64,
        tranche: u8,
        shares_burned: u64,
        timestamp: u64
    }

    #[event]
    struct CreditDrawn has drop, store {
        attestator: address,
        amount: u64,
        prt_address: address,
        timestamp: u64
    }

    #[event]
    struct CreditRepaid has drop, store {
        attestator: address,
        principal: u64,
        interest: u64,
        prt_address: address,
        timestamp: u64
    }

    #[event]
    struct YieldDistributed has drop, store {
        pool_address: address,
        total_interest: u64,
        protocol_reserve_share: u64,
        senior_share: u64,
        junior_share: u64,
        timestamp: u64
    }

    #[event]
    struct LossAllocated has drop, store {
        pool_address: address,
        total_loss: u64,
        protocol_reserve_absorbed: u64,
        junior_absorbed: u64,
        senior_absorbed: u64,
        timestamp: u64
    }

    #[event]
    struct NAVUpdated has drop, store {
        pool_address: address,
        tranche: u8,
        old_multiplier: u128,
        new_multiplier: u128,
        timestamp: u64
    }

    /// Initialize a new pool for a specific fungible asset type
    public entry fun initialize_pool<FA>(
        admin: &signer,
        fa_metadata: Object<Metadata>,
        max_utilization_bps: u64,
        governance_address: address
    ) {
        use aptos_framework::fungible_asset;
        use kach::governance;

        let admin_addr = signer::address_of(admin);

        // Check permission to create pool
        governance::assert_can_create_pool(governance_address, admin_addr);

        let pool = Pool<FA> {
            fa_metadata,
            total_deposits: 0,
            total_borrowed: 0,
            senior_deposits: 0,
            junior_deposits: 0,
            senior_nav_multiplier: 1_000_000_000_000_000_000, // 1e18
            junior_nav_multiplier: 1_000_000_000_000_000_000,
            max_utilization_bps,
            protocol_reserve_balance: 0,
            protocol_fee_bps: governance::get_protocol_fee_bps(governance_address),
            total_position_nfts_minted: 0,
            total_prts_minted: 0,
            is_paused: false
        };

        move_to(admin, pool);

        // Get asset information from metadata
        let asset_metadata_addr = object::object_address(&fa_metadata);
        let asset_symbol = fungible_asset::symbol(fa_metadata);
        let asset_name = fungible_asset::name(fa_metadata);

        event::emit(
            PoolInitialized {
                pool_address: admin_addr,
                asset_metadata_address: asset_metadata_addr,
                asset_symbol,
                asset_name,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Get the senior tranche identifier
    public fun tranche_senior(): u8 {
        TRANCHE_SENIOR
    }

    /// Get the junior tranche identifier
    public fun tranche_junior(): u8 {
        TRANCHE_JUNIOR
    }

    /// Get current pool utilization in basis points
    #[view]
    public fun get_utilization<FA>(pool_addr: address): u64 acquires Pool {
        let pool = borrow_global<Pool<FA>>(pool_addr);

        if (pool.total_deposits == 0) {
            return 0
        };

        // Calculate: (total_borrowed * 10000) / total_deposits
        ((pool.total_borrowed as u128) * 10000 / (pool.total_deposits as u128) as u64)
    }

    /// Get available liquidity for borrowing
    #[view]
    public fun available_liquidity<FA>(pool_addr: address): u64 acquires Pool {
        let pool = borrow_global<Pool<FA>>(pool_addr);

        // Max borrowable = total_deposits * max_utilization_bps / 10000
        let max_borrowable =
            ((pool.total_deposits as u128) * (pool.max_utilization_bps as u128) / 10000 as u64);

        // Available = max_borrowable - current_borrowed
        if (max_borrowable > pool.total_borrowed) {
            max_borrowable - pool.total_borrowed
        } else { 0 }
    }

    /// Pause pool (emergency only)
    /// Can be called by admins or emergency responders
    public entry fun pause_pool<FA>(
        caller: &signer, pool_addr: address, governance_address: address
    ) acquires Pool {
        use kach::governance;

        let caller_addr = signer::address_of(caller);

        // Check permission to pause pool
        governance::assert_can_pause_pool(governance_address, caller_addr);

        let pool = borrow_global_mut<Pool<FA>>(pool_addr);
        pool.is_paused = true;
    }

    /// Unpause pool
    /// Can only be called by admins (not emergency responders)
    public entry fun unpause_pool<FA>(
        caller: &signer, pool_addr: address, governance_address: address
    ) acquires Pool {
        use kach::governance;

        let caller_addr = signer::address_of(caller);

        // Check permission to unpause pool
        governance::assert_can_unpause_pool(governance_address, caller_addr);

        let pool = borrow_global_mut<Pool<FA>>(pool_addr);
        pool.is_paused = false;
    }

    /// Get current NAV multiplier for a tranche
    #[view]
    public fun get_nav_multiplier<FA>(pool_addr: address, tranche: u8): u128 acquires Pool {
        let pool = borrow_global<Pool<FA>>(pool_addr);

        if (tranche == TRANCHE_SENIOR) {
            pool.senior_nav_multiplier
        } else {
            pool.junior_nav_multiplier
        }
    }

    /// Get pool statistics
    #[view]
    public fun get_pool_stats<FA>(pool_addr: address): (u64, u64, u64, u64, u64, bool) acquires Pool {
        let pool = borrow_global<Pool<FA>>(pool_addr);
        (
            pool.total_deposits,
            pool.total_borrowed,
            pool.protocol_reserve_balance,
            pool.total_position_nfts_minted,
            pool.total_prts_minted,
            pool.is_paused
        )
    }

    /// Internal: Update NAV multiplier after yield distribution
    public(friend) fun update_nav_multiplier<FA>(
        pool_addr: address, tranche: u8, new_multiplier: u128
    ) acquires Pool {
        let pool = borrow_global_mut<Pool<FA>>(pool_addr);

        if (tranche == TRANCHE_SENIOR) {
            pool.senior_nav_multiplier = new_multiplier;
        } else if (tranche == TRANCHE_JUNIOR) {
            pool.junior_nav_multiplier = new_multiplier;
        }
    }

    /// Internal: Update total borrowed amount
    public(friend) fun update_borrowed<FA>(
        pool_addr: address,
        amount: u64,
        is_draw: bool // true for draw, false for repayment
    ) acquires Pool {
        let pool = borrow_global_mut<Pool<FA>>(pool_addr);

        if (is_draw) {
            pool.total_borrowed += amount;
        } else {
            pool.total_borrowed -= amount;
        }
    }

    /// Internal: Update deposits for a tranche
    public(friend) fun update_deposits<FA>(
        pool_addr: address,
        tranche: u8,
        amount: u64,
        is_deposit: bool // true for deposit, false for withdrawal
    ) acquires Pool {
        let pool = borrow_global_mut<Pool<FA>>(pool_addr);

        if (is_deposit) {
            pool.total_deposits += amount;

            if (tranche == TRANCHE_SENIOR) {
                pool.senior_deposits += amount;
            } else {
                pool.junior_deposits += amount;
            }
        } else {
            pool.total_deposits -= amount;

            if (tranche == TRANCHE_SENIOR) {
                pool.senior_deposits -= amount;
            } else {
                pool.junior_deposits -= amount;
            }
        }
    }

    /// Internal: Increment NFT counter
    public(friend) fun increment_nft_counter<FA>(pool_addr: address) acquires Pool {
        let pool = borrow_global_mut<Pool<FA>>(pool_addr);
        pool.total_position_nfts_minted += 1;
    }

    /// Internal: Increment PRT counter
    public(friend) fun increment_prt_counter<FA>(pool_addr: address) acquires Pool {
        let pool = borrow_global_mut<Pool<FA>>(pool_addr);
        pool.total_prts_minted += 1;
    }

    /// Internal: Add to protocol reserve
    public(friend) fun add_to_reserve<FA>(
        pool_addr: address, amount: u64
    ) acquires Pool {
        let pool = borrow_global_mut<Pool<FA>>(pool_addr);
        pool.protocol_reserve_balance += amount;
    }

    #[view]
    public fun is_paused<FA>(pool_addr: address): bool acquires Pool {
        let pool = borrow_global<Pool<FA>>(pool_addr);
        pool.is_paused
    }

    /// Transfer fungible assets from pool to recipient
    /// Called by credit_engine for loan disbursements
    public(friend) fun transfer_from_pool<FA>(
        pool_owner: &signer,
        recipient: address,
        amount: u64,
        fa_metadata: Object<Metadata>
    ) {
        // Transfer from pool owner's primary store to recipient's primary store
        primary_fungible_store::transfer(pool_owner, fa_metadata, recipient, amount);
    }

    /// Transfer fungible assets from sender to pool
    /// Called for deposits and repayments
    public(friend) fun transfer_to_pool<FA>(
        sender: &signer,
        pool_addr: address,
        amount: u64,
        fa_metadata: Object<Metadata>
    ) {
        // Transfer from sender to pool owner's primary store
        primary_fungible_store::transfer(sender, fa_metadata, pool_addr, amount);
    }

    /// Deduct from protocol reserve
    public(friend) fun deduct_from_reserve<FA>(
        pool_addr: address, amount: u64
    ) acquires Pool {
        let pool = borrow_global_mut<Pool<FA>>(pool_addr);
        assert!(pool.protocol_reserve_balance >= amount, E_INSUFFICIENT_LIQUIDITY);
        pool.protocol_reserve_balance -= amount;
    }

    /// Get tranche deposits
    #[view]
    public fun get_tranche_deposits<FA>(pool_addr: address, tranche: u8): u64 acquires Pool {
        let pool = borrow_global<Pool<FA>>(pool_addr);

        if (tranche == TRANCHE_SENIOR) {
            pool.senior_deposits
        } else {
            pool.junior_deposits
        }
    }

    /// Get protocol fee in basis points
    #[view]
    public fun get_protocol_fee_bps<FA>(pool_addr: address): u64 acquires Pool {
        let pool = borrow_global<Pool<FA>>(pool_addr);
        pool.protocol_fee_bps
    }

    /// Get fungible asset metadata for this pool
    #[view]
    public fun get_fa_metadata<FA>(pool_addr: address): Object<Metadata> acquires Pool {
        let pool = borrow_global<Pool<FA>>(pool_addr);
        pool.fa_metadata
    }

    /// Get fungible asset metadata address for this pool
    #[view]
    public fun get_fa_metadata_address<FA>(pool_addr: address): address acquires Pool {
        let pool = borrow_global<Pool<FA>>(pool_addr);
        object::object_address(&pool.fa_metadata)
    }

    /// Get asset info for this pool (symbol and name)
    #[view]
    public fun get_asset_info<FA>(pool_addr: address): (String, String) acquires Pool {
        use aptos_framework::fungible_asset;
        let pool = borrow_global<Pool<FA>>(pool_addr);
        let symbol = fungible_asset::symbol(pool.fa_metadata);
        let name = fungible_asset::name(pool.fa_metadata);
        (symbol, name)
    }

    // ===== Tranche Functions =====

    /// Distribute yield from interest to tranches
    /// Called after PRT repayment
    /// Uses dynamic capital-weighted distribution per documentation:
    /// - Multipliers calculated based on actual pool composition
    /// - Junior multiplier = 1.0 + (protection_ratio x base_risk_premium)
    /// - Senior multiplier = 1.0 - (junior_ratio x base_risk_premium)
    /// - Protocol fee: pulled from governance config
    public fun distribute_yield<FA>(
        pool_address: address, total_interest: u64, governance_address: address
    ) acquires Pool {
        // Sync protocol fee with governance before applying
        let protocol_fee_bps = governance::get_protocol_fee_bps(governance_address);
        {
            let pool = borrow_global_mut<Pool<FA>>(pool_address);
            pool.protocol_fee_bps = protocol_fee_bps;
        };

        // Calculate protocol reserve share from governance-configured fee
        let protocol_share = (total_interest as u128) * (protocol_fee_bps as u128)
            / 10000;
        let protocol_share_u64 = (protocol_share as u64);

        // Add to protocol reserve
        add_to_reserve<FA>(pool_address, protocol_share_u64);

        // Remaining yield for tranches after protocol fee
        let tranche_yield = total_interest - protocol_share_u64;

        // Get actual tranche deposits
        let senior_deposits = get_tranche_deposits<FA>(pool_address, TRANCHE_SENIOR);
        let junior_deposits = get_tranche_deposits<FA>(pool_address, TRANCHE_JUNIOR);

        // Get base risk premium from governance (e.g., 3000 bps = 30% = 0.3)
        let base_risk_premium_bps =
            governance::get_base_risk_premium_bps(governance_address);

        // Calculate dynamic multipliers based on pool composition
        // Protection ratio = how many dollars of senior each junior dollar protects
        // Junior multiplier = 1.0 + (protection_ratio x base_risk_premium)
        // Senior multiplier = 1.0 - (inverse_ratio x base_risk_premium)

        let senior_share: u64;
        let junior_share: u64;

        if (senior_deposits == 0 && junior_deposits == 0) {
            // No deposits, no distribution
            senior_share = 0;
            junior_share = 0;
        } else if (junior_deposits == 0) {
            // Only senior depositors, they get all yield
            senior_share = tranche_yield;
            junior_share = 0;
        } else if (senior_deposits == 0) {
            // Only junior depositors, they get all yield
            senior_share = 0;
            junior_share = tranche_yield;
        } else {
            // Both tranches have deposits, calculate dynamic weights
            // Using scaled math to avoid decimals: multiply by 10000 for precision

            // protection_ratio = senior / junior (scaled by 10000)
            let protection_ratio_scaled =
                (senior_deposits as u128) * 10000 / (junior_deposits as u128);

            // junior_multiplier = 1.0 + (protection_ratio x base_risk_premium)
            // = 10000 + (protection_ratio_scaled x base_risk_premium_bps / 10000)
            let junior_multiplier =
                10000
                    + (protection_ratio_scaled * (base_risk_premium_bps as u128) / 10000);

            // inverse_ratio = junior / senior (scaled by 10000)
            let inverse_ratio_scaled =
                (junior_deposits as u128) * 10000 / (senior_deposits as u128);

            // senior_multiplier = 1.0 - (inverse_ratio x base_risk_premium)
            // = 10000 - (inverse_ratio_scaled x base_risk_premium_bps / 10000)
            let senior_multiplier_calc =
                (inverse_ratio_scaled * (base_risk_premium_bps as u128) / 10000);
            let senior_multiplier =
                if (10000 > senior_multiplier_calc) {
                    10000 - senior_multiplier_calc
                } else {
                    1 // Minimum 0.0001x to avoid zero division
                };

            // Calculate weighted capital (scaled by 10000)
            let senior_weight = (senior_deposits as u128) * senior_multiplier;
            let junior_weight = (junior_deposits as u128) * junior_multiplier;
            let total_weight = senior_weight + junior_weight;

            // Distribute yield proportionally by weighted capital
            senior_share = ((tranche_yield as u128) * senior_weight / total_weight as u64);
            junior_share = ((tranche_yield as u128) * junior_weight / total_weight as u64);
        };

        // Update NAV multipliers for each tranche
        update_nav_for_yield<FA>(pool_address, TRANCHE_SENIOR, senior_share);
        update_nav_for_yield<FA>(pool_address, TRANCHE_JUNIOR, junior_share);

        event::emit(
            YieldDistributed {
                pool_address,
                total_interest,
                protocol_reserve_share: protocol_share_u64,
                senior_share,
                junior_share,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Allocate losses across tranches using waterfall
    /// 1. Protocol Reserve absorbs first
    /// 2. Junior tranche absorbs up to its full deposits
    /// 3. Senior tranche absorbs up to its full deposits
    public fun allocate_loss<FA>(pool_address: address, total_loss: u64) acquires Pool {
        let remaining_loss = total_loss;

        // Step 0: Protocol reserve absorbs first
        let (_, _, protocol_reserve_balance, _, _, _) = get_pool_stats<FA>(pool_address);

        let protocol_absorbed =
            if (protocol_reserve_balance >= remaining_loss) {
                remaining_loss
            } else {
                protocol_reserve_balance
            };

        remaining_loss -= protocol_absorbed;

        // Deduct from protocol reserve
        if (protocol_absorbed > 0) {
            deduct_from_reserve<FA>(pool_address, protocol_absorbed);
        };

        let junior_absorbed = 0u64;
        let senior_absorbed = 0u64;

        if (remaining_loss > 0) {
            // Step 1: Junior tranche absorbs (up to all junior deposits)
            (remaining_loss, junior_absorbed) = absorb_loss_in_tranche<FA>(
                pool_address, TRANCHE_JUNIOR, remaining_loss
            );
        };

        if (remaining_loss > 0) {
            // Step 2: Senior tranche absorbs remaining (up to all senior deposits)
            (_, senior_absorbed) = absorb_loss_in_tranche<FA>(
                pool_address, TRANCHE_SENIOR, remaining_loss
            );
            // If still remaining loss, protocol is insolvent
            // This should trigger emergency procedures
        };

        event::emit(
            LossAllocated {
                pool_address,
                total_loss,
                protocol_reserve_absorbed: protocol_absorbed,
                junior_absorbed,
                senior_absorbed,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Internal: Absorb loss in a specific tranche
    /// Returns (remaining_loss, absorbed_amount)
    fun absorb_loss_in_tranche<FA>(
        pool_address: address, tranche: u8, loss_amount: u64
    ): (u64, u64) acquires Pool {
        // Get tranche deposits from pool
        let tranche_deposits = get_tranche_deposits<FA>(pool_address, tranche);

        let absorbed =
            if (loss_amount <= tranche_deposits) {
                loss_amount
            } else {
                tranche_deposits
            };

        let remaining = loss_amount - absorbed;

        // Update NAV multiplier (decrease for loss)
        update_nav_for_loss<FA>(pool_address, tranche, absorbed);

        (remaining, absorbed)
    }

    /// Update NAV multiplier when yield is distributed
    fun update_nav_for_yield<FA>(
        pool_address: address, tranche: u8, yield_amount: u64
    ) acquires Pool {
        let old_multiplier = get_nav_multiplier<FA>(pool_address, tranche);

        // Get tranche deposits from pool module
        let tranche_deposits = get_tranche_deposits<FA>(pool_address, tranche);

        if (tranche_deposits == 0) { return };

        // New multiplier = old_multiplier * (1 + yield/deposits)
        // NAV multipliers are scaled by 1e18
        let yield_ratio =
            (yield_amount as u128) * 1_000_000_000_000_000_000
                / (tranche_deposits as u128);
        let new_multiplier = old_multiplier + yield_ratio;

        update_nav_multiplier<FA>(pool_address, tranche, new_multiplier);

        event::emit(
            NAVUpdated {
                pool_address,
                tranche,
                old_multiplier,
                new_multiplier,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Update NAV multiplier when loss is allocated
    fun update_nav_for_loss<FA>(
        pool_address: address, tranche: u8, loss_amount: u64
    ) acquires Pool {
        let old_multiplier = get_nav_multiplier<FA>(pool_address, tranche);

        // Get tranche deposits from pool module
        let tranche_deposits = get_tranche_deposits<FA>(pool_address, tranche);

        if (tranche_deposits == 0) { return };

        // New multiplier = old_multiplier * (1 - loss/deposits)
        let loss_ratio =
            (loss_amount as u128) * 1_000_000_000_000_000_000
                / (tranche_deposits as u128);

        // Ensure we don't go negative
        let new_multiplier =
            if (old_multiplier > loss_ratio) {
                old_multiplier - loss_ratio
            } else { 0 };

        update_nav_multiplier<FA>(pool_address, tranche, new_multiplier);

        event::emit(
            NAVUpdated {
                pool_address,
                tranche,
                old_multiplier,
                new_multiplier,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Calculate current dynamic multipliers for a pool based on composition
    /// Returns (senior_multiplier_bps, junior_multiplier_bps) scaled by 10000
    /// Example: If senior multiplier is 0.925, returns 9250
    #[view]
    public fun calculate_current_multipliers<FA>(
        pool_address: address, governance_address: address
    ): (u64, u64) acquires Pool {
        let senior_deposits = get_tranche_deposits<FA>(pool_address, TRANCHE_SENIOR);
        let junior_deposits = get_tranche_deposits<FA>(pool_address, TRANCHE_JUNIOR);
        let base_risk_premium_bps =
            governance::get_base_risk_premium_bps(governance_address);

        if (junior_deposits == 0) {
            return (10000, 0) // Senior gets 1.0x, junior N/A
        };

        if (senior_deposits == 0) {
            return (0, 10000) // Junior gets 1.0x, senior N/A
        };

        // protection_ratio = senior / junior (scaled by 10000)
        let protection_ratio_scaled =
            (senior_deposits as u128) * 10000 / (junior_deposits as u128);

        // junior_multiplier = 1.0 + (protection_ratio x base_risk_premium)
        let junior_multiplier =
            10000 + (protection_ratio_scaled * (base_risk_premium_bps as u128) / 10000);

        // inverse_ratio = junior / senior (scaled by 10000)
        let inverse_ratio_scaled = (junior_deposits as u128) * 10000
            / (senior_deposits as u128);

        // senior_multiplier = 1.0 - (inverse_ratio x base_risk_premium)
        let senior_multiplier_calc =
            (inverse_ratio_scaled * (base_risk_premium_bps as u128) / 10000);
        let senior_multiplier =
            if (10000 > senior_multiplier_calc) {
                10000 - senior_multiplier_calc
            } else { 1 };

        ((senior_multiplier as u64), (junior_multiplier as u64))
    }
}
