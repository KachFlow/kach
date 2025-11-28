module kach::position_nft {
    use std::signer;
    use aptos_framework::object::{Self, Object, ExtendRef, DeleteRef};
    use aptos_framework::event;
    use aptos_framework::timestamp;

    use kach::pool;

    /// Error when an operation is attempted by a signer that does not own the NFT.
    const E_NOT_OWNER: u64 = 1;
    /// Error when trying to merge NFTs from different tranches or pools.
    const E_INCOMPATIBLE_POSITIONS: u64 = 3;
    /// Error when attempting to withdraw or merge more shares than available.
    const E_INSUFFICIENT_SHARES: u64 = 4;

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
    struct PositionSplit has drop, store {
        original_nft: address,
        new_nft_1: address,
        new_nft_2: address,
        shares_1: u64,
        shares_2: u64,
        timestamp: u64
    }

    #[event]
    struct PositionMerged has drop, store {
        nft_1: address,
        nft_2: address,
        new_nft: address,
        total_shares: u64,
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
    public fun mint_position<FA>(
        depositor: &signer,
        pool_address: address,
        tranche: u8,
        shares: u64,
        lock_duration_seconds: u64
    ): Object<PositionNFT<FA>> {
        let depositor_addr = signer::address_of(depositor);

        // Get current NAV for this tranche from Pool<FA>
        // Type system ensures we're querying the right pool
        let nav_index = pool::get_nav_multiplier<FA>(pool_address, tranche);

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

        // Increment pool counter
        pool::increment_nft_counter<FA>(pool_address);

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

    /// Split a position NFT into two new NFTs
    /// Both resulting NFTs maintain the same FA type
    public entry fun split_position<FA>(
        owner: &signer, position: Object<PositionNFT<FA>>, shares_for_new_nft: u64
    ) acquires PositionNFT {
        let owner_addr = signer::address_of(owner);
        let position_addr = object::object_address(&position);

        // Verify ownership
        assert!(object::is_owner(position, owner_addr), E_NOT_OWNER);

        let position_data = borrow_global_mut<PositionNFT<FA>>(position_addr);

        // Verify sufficient shares
        assert!(position_data.shares > shares_for_new_nft, E_INSUFFICIENT_SHARES);

        let remaining_shares = position_data.shares - shares_for_new_nft;

        // Save data before deletion
        let pool_addr = position_data.pool_address;
        let tranche = position_data.tranche;
        let nav_index = position_data.nav_index_at_deposit;
        let lock_duration = position_data.lock_duration_seconds;
        let unlock_time = position_data.unlock_timestamp;
        let creation_time = position_data.creation_timestamp;

        // Delete original NFT
        let PositionNFT<FA> {
            pool_address: _,
            tranche: _,
            shares: _,
            lock_duration_seconds: _,
            unlock_timestamp: _,
            creation_timestamp: _,
            nav_index_at_deposit: _,
            extend_ref: _,
            delete_ref
        } = move_from<PositionNFT<FA>>(position_addr);

        object::delete(delete_ref);

        // Create two new NFTs with proportional shares
        let constructor_ref_1 = object::create_object(owner_addr);
        let object_signer_1 = object::generate_signer(&constructor_ref_1);
        let extend_ref_1 = object::generate_extend_ref(&constructor_ref_1);
        let delete_ref_1 = object::generate_delete_ref(&constructor_ref_1);
        let transfer_ref_1 = object::generate_transfer_ref(&constructor_ref_1);
        object::enable_ungated_transfer(&transfer_ref_1);

        let nft_addr_1 = object::address_from_constructor_ref(&constructor_ref_1);

        move_to(
            &object_signer_1,
            PositionNFT<FA> {
                pool_address: pool_addr,
                tranche,
                shares: remaining_shares,
                lock_duration_seconds: lock_duration,
                unlock_timestamp: unlock_time,
                creation_timestamp: creation_time,
                nav_index_at_deposit: nav_index,
                extend_ref: extend_ref_1,
                delete_ref: delete_ref_1
            }
        );

        let constructor_ref_2 = object::create_object(owner_addr);
        let object_signer_2 = object::generate_signer(&constructor_ref_2);
        let extend_ref_2 = object::generate_extend_ref(&constructor_ref_2);
        let delete_ref_2 = object::generate_delete_ref(&constructor_ref_2);
        let transfer_ref_2 = object::generate_transfer_ref(&constructor_ref_2);
        object::enable_ungated_transfer(&transfer_ref_2);

        let nft_addr_2 = object::address_from_constructor_ref(&constructor_ref_2);

        move_to(
            &object_signer_2,
            PositionNFT<FA> {
                pool_address: pool_addr,
                tranche,
                shares: shares_for_new_nft,
                lock_duration_seconds: lock_duration,
                unlock_timestamp: unlock_time,
                creation_timestamp: creation_time,
                nav_index_at_deposit: nav_index,
                extend_ref: extend_ref_2,
                delete_ref: delete_ref_2
            }
        );

        // Emit event
        event::emit(
            PositionSplit {
                original_nft: position_addr,
                new_nft_1: nft_addr_1,
                new_nft_2: nft_addr_2,
                shares_1: remaining_shares,
                shares_2: shares_for_new_nft,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Merge two compatible position NFTs into one
    /// Both must be PositionNFT<FA> with same pool, tranche, and unlock timestamp
    public entry fun merge_positions<FA>(
        owner: &signer,
        position1: Object<PositionNFT<FA>>,
        position2: Object<PositionNFT<FA>>
    ) acquires PositionNFT {
        let owner_addr = signer::address_of(owner);
        let pos1_addr = object::object_address(&position1);
        let pos2_addr = object::object_address(&position2);

        // Verify ownership
        assert!(object::is_owner(position1, owner_addr), E_NOT_OWNER);
        assert!(object::is_owner(position2, owner_addr), E_NOT_OWNER);

        let pos1_data = borrow_global<PositionNFT<FA>>(pos1_addr);
        let pos2_data = borrow_global<PositionNFT<FA>>(pos2_addr);

        // Verify compatibility
        // Type system already ensures both are PositionNFT<FA>
        assert!(
            pos1_data.pool_address == pos2_data.pool_address
                && pos1_data.tranche == pos2_data.tranche
                && pos1_data.unlock_timestamp == pos2_data.unlock_timestamp,
            E_INCOMPATIBLE_POSITIONS
        );

        let total_shares = pos1_data.shares + pos2_data.shares;

        // Save data
        let pool_addr = pos1_data.pool_address;
        let tranche = pos1_data.tranche;
        let lock_duration = pos1_data.lock_duration_seconds;
        let unlock_time = pos1_data.unlock_timestamp;
        let creation_time = pos1_data.creation_timestamp;

        // Calculate weighted average NAV index
        let weighted_nav =
            (
                (
                    pos1_data.nav_index_at_deposit * (pos1_data.shares as u128)
                        + pos2_data.nav_index_at_deposit * (pos2_data.shares as u128)
                ) / (total_shares as u128)
            );

        // Delete both NFTs
        let PositionNFT<FA> {
            pool_address: _,
            tranche: _,
            shares: _,
            lock_duration_seconds: _,
            unlock_timestamp: _,
            creation_timestamp: _,
            nav_index_at_deposit: _,
            extend_ref: _,
            delete_ref: delete_ref_1
        } = move_from<PositionNFT<FA>>(pos1_addr);

        let PositionNFT<FA> {
            pool_address: _,
            tranche: _,
            shares: _,
            lock_duration_seconds: _,
            unlock_timestamp: _,
            creation_timestamp: _,
            nav_index_at_deposit: _,
            extend_ref: _,
            delete_ref: delete_ref_2
        } = move_from<PositionNFT<FA>>(pos2_addr);

        object::delete(delete_ref_1);
        object::delete(delete_ref_2);

        // Create new merged NFT
        let constructor_ref = object::create_object(owner_addr);
        let object_signer = object::generate_signer(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let delete_ref = object::generate_delete_ref(&constructor_ref);
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        object::enable_ungated_transfer(&transfer_ref);

        let new_nft_addr = object::address_from_constructor_ref(&constructor_ref);

        move_to(
            &object_signer,
            PositionNFT<FA> {
                pool_address: pool_addr,
                tranche,
                shares: total_shares,
                lock_duration_seconds: lock_duration,
                unlock_timestamp: unlock_time,
                creation_timestamp: creation_time,
                nav_index_at_deposit: weighted_nav,
                extend_ref,
                delete_ref
            }
        );

        // Emit event
        event::emit(
            PositionMerged {
                nft_1: pos1_addr,
                nft_2: pos2_addr,
                new_nft: new_nft_addr,
                total_shares,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Check if position is unlocked and ready for redemption
    #[view]
    public fun is_unlocked<FA>(position: Object<PositionNFT<FA>>): bool acquires PositionNFT {
        let position_data =
            borrow_global<PositionNFT<FA>>(object::object_address(&position));
        timestamp::now_seconds() >= position_data.unlock_timestamp
    }

    /// Calculate current redemption value based on NAV change
    /// Type parameter FA ensures we query the correct Pool<FA>
    #[view]
    public fun calculate_redemption_value<FA>(
        position: Object<PositionNFT<FA>>
    ): u64 acquires PositionNFT {
        let position_data =
            borrow_global<PositionNFT<FA>>(object::object_address(&position));

        // Get current NAV for the tranche from Pool<FA>
        // Type safety: can only query Pool<FA> with PositionNFT<FA>
        let current_nav =
            pool::get_nav_multiplier<FA>(
                position_data.pool_address,
                position_data.tranche
            );

        // Redemption value = shares * (current_nav / nav_at_deposit)
        // Scale: (shares * current_nav) / nav_at_deposit
        let value =
            ((position_data.shares as u128) * current_nav
                / position_data.nav_index_at_deposit);

        (value as u64)
    }

    /// Get position details
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

    /// Internal: Burn position NFT on redemption
    /// Returns (pool_address, tranche, shares)
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
