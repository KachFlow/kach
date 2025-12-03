module kach::position_nft {
    use std::signer;
    use aptos_framework::object::{Self, Object, ExtendRef, DeleteRef};
    use aptos_framework::event;
    use aptos_framework::timestamp;

    // Friend modules that can call restricted functions
    friend kach::pool;

    /// Error when an operation is attempted by a signer that does not own the NFT.
    const E_NOT_OWNER: u64 = 1;
    /// Error when position is still locked.
    const E_POSITION_LOCKED: u64 = 2;

    /// Position NFT - represents LP stake in Pool<FA>
    /// Generic over fungible asset type for type safety
    /// Fully permissionless, transferable
    struct PositionNFT<phantom FA> has key {
        // Pool reference - type-safe association with Pool<FA>
        pool_address: address,

        // Investment details
        tranche: u8,
        shares: u64, // Pool shares owned

        // Lock-up information
        lock_duration_seconds: u64,
        unlock_timestamp: u64,
        creation_timestamp: u64,

        // Yield tracking - NAV multiplier at deposit time
        nav_index_at_deposit: u128,

        // Object management
        extend_ref: ExtendRef,
        delete_ref: DeleteRef
    }

    /// Events
    #[event]
    struct PositionMinted has drop, store {
        nft_address: address,
        owner: address,
        pool_address: address,
        tranche: u8,
        shares: u64,
        lock_duration_seconds: u64,
        timestamp: u64
    }

    #[event]
    struct PositionRedeemed has drop, store {
        nft_address: address,
        owner: address,
        shares_burned: u64,
        redemption_value: u64,
        timestamp: u64
    }

    /// Mint a new position NFT for a depositor
    /// FA type parameter ensures type safety with Pool<FA>
    /// Only callable by pool (friend module)
    /// Pool must pass in the current NAV index for the tranche
    public(friend) fun mint_position<FA>(
        depositor: &signer,
        pool_address: address,
        tranche: u8,
        shares: u64,
        lock_duration_seconds: u64,
        nav_index: u128
    ): Object<PositionNFT<FA>> {
        let depositor_addr = signer::address_of(depositor);

        // Create transferable object owned by depositor
        let constructor_ref = object::create_object(depositor_addr);
        let object_signer = object::generate_signer(&constructor_ref);

        // Generate refs for management
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let delete_ref = object::generate_delete_ref(&constructor_ref);

        // Make object transferable (ungated)
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        object::enable_ungated_transfer(&transfer_ref);

        let position = PositionNFT<FA> {
            pool_address,
            tranche,
            shares,
            lock_duration_seconds,
            unlock_timestamp: timestamp::now_seconds() + lock_duration_seconds,
            creation_timestamp: timestamp::now_seconds(),
            nav_index_at_deposit: nav_index,
            extend_ref,
            delete_ref
        };

        let nft_address = object::address_from_constructor_ref(&constructor_ref);

        move_to(&object_signer, position);

        // Emit event
        event::emit(
            PositionMinted {
                nft_address,
                owner: depositor_addr,
                pool_address,
                tranche,
                shares,
                lock_duration_seconds,
                timestamp: timestamp::now_seconds()
            }
        );

        object::object_from_constructor_ref<PositionNFT<FA>>(&constructor_ref)
    }

    /// Redeem a position NFT for underlying assets
    /// Burns the NFT and returns position details to pool for withdrawal processing
    /// Returns (pool_address, tranche, shares, nav_at_deposit)
    /// Pool must calculate redemption value using current NAV
    public fun redeem_position<FA>(
        owner: &signer,
        position: Object<PositionNFT<FA>>
    ): (address, u8, u64, u128) acquires PositionNFT {
        let owner_addr = signer::address_of(owner);
        let position_addr = object::object_address(&position);

        // Verify ownership
        assert!(object::is_owner(position, owner_addr), E_NOT_OWNER);

        let position_data = borrow_global<PositionNFT<FA>>(position_addr);

        // Verify position is unlocked
        assert!(
            timestamp::now_seconds() >= position_data.unlock_timestamp,
            E_POSITION_LOCKED
        );

        // Save data before deletion
        let pool_addr = position_data.pool_address;
        let tranche = position_data.tranche;
        let shares = position_data.shares;
        let nav_at_deposit = position_data.nav_index_at_deposit;

        // Delete NFT
        let PositionNFT<FA> {
            pool_address: _,
            tranche: _,
            shares: shares_burned,
            lock_duration_seconds: _,
            unlock_timestamp: _,
            creation_timestamp: _,
            nav_index_at_deposit: _,
            extend_ref: _,
            delete_ref
        } = move_from<PositionNFT<FA>>(position_addr);

        object::delete(delete_ref);

        // Emit redemption event (pool will add redemption_value to event later)
        event::emit(
            PositionRedeemed {
                nft_address: position_addr,
                owner: owner_addr,
                shares_burned,
                redemption_value: 0, // Pool calculates this
                timestamp: timestamp::now_seconds()
            }
        );

        // Return position details for pool to process withdrawal
        (pool_addr, tranche, shares, nav_at_deposit)
    }

    /// Check if position is unlocked and ready for redemption
    #[view]
    public fun is_unlocked<FA>(position: Object<PositionNFT<FA>>): bool acquires PositionNFT {
        let position_data =
            borrow_global<PositionNFT<FA>>(object::object_address(&position));
        timestamp::now_seconds() >= position_data.unlock_timestamp
    }

    /// Get position details
    /// Returns (pool_address, tranche, shares, unlock_timestamp, creation_timestamp, nav_index_at_deposit)
    #[view]
    public fun get_position_info<FA>(
        position: Object<PositionNFT<FA>>
    ): (address, u8, u64, u64, u64, u128) acquires PositionNFT {
        let position_data =
            borrow_global<PositionNFT<FA>>(object::object_address(&position));
        (
            position_data.pool_address,
            position_data.tranche,
            position_data.shares,
            position_data.unlock_timestamp,
            position_data.creation_timestamp,
            position_data.nav_index_at_deposit
        )
    }

    /// Internal: Burn position NFT (for pool-initiated burns)
    /// Returns (pool_address, tranche, shares)
    /// Only callable by pool (friend module)
    public(friend) fun burn_position<FA>(
        position: Object<PositionNFT<FA>>
    ): (address, u8, u64) acquires PositionNFT {
        let position_addr = object::object_address(&position);
        let PositionNFT {
            pool_address: pool_addr,
            tranche,
            shares,
            lock_duration_seconds: _,
            unlock_timestamp: _,
            creation_timestamp: _,
            nav_index_at_deposit: _,
            extend_ref: _,
            delete_ref
        } = move_from<PositionNFT<FA>>(position_addr);

        // Delete object
        object::delete(delete_ref);

        // Return position details for pool update
        (pool_addr, tranche, shares)
    }
}
