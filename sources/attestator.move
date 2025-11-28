module kach::attestator {
    use std::signer;
    use std::string::String;
    use std::vector;
    use aptos_framework::object::{Self, Object, ExtendRef, DeleteRef};
    use aptos_framework::event;
    use aptos_framework::timestamp;
    use aptos_framework::fungible_asset::Metadata;

    use kach::prt::{Self, PRT};
    use kach::pool;
    use kach::trust_score;
    use kach::tranche;

    /// Error when a caller without the admin/operator capability invokes an action.
    const E_NOT_AUTHORIZED: u64 = 1;
    /// Error when registering an attestator address that already exists.
    const E_ATTESTATOR_EXISTS: u64 = 2;
    /// Error when referencing an attestator that has not been registered.
    const E_ATTESTATOR_NOT_FOUND: u64 = 3;
    /// Error when an inactive attestator attempts to act or is queried.
    const E_ATTESTATOR_INACTIVE: u64 = 4;
    /// Error when an attestator has not been approved for the requested action.
    const E_ATTESTATOR_NOT_APPROVED: u64 = 5;
    /// Error when trying to attest a PRT that already has a linked attestation.
    const E_PRT_ALREADY_ATTESTED: u64 = 6;
    /// Error when operating on a PRT that does not have any attestation record.
    const E_PRT_NOT_ATTESTED: u64 = 7;
    /// Error when an attestator's stake is below the minimum requirement.
    const E_INSUFFICIENT_STAKE: u64 = 8;
    /// Error when a settlement attempt is made by a different attestator.
    const E_WRONG_ATTESTATOR: u64 = 9;
    /// Error when settlement is attempted outside the allowed scenarios.
    const E_SETTLEMENT_NOT_ALLOWED: u64 = 10;
    /// Error when settlement happens beyond the permitted grace period.
    const E_GRACE_PERIOD_EXPIRED: u64 = 11;
    /// Error when the receivable type specified does not match the allowed set.
    const E_INVALID_RECEIVABLE_TYPE: u64 = 12;
    /// Error when trying to reuse an attestation that already backed a draw.
    const E_ATTESTATION_ALREADY_USED: u64 = 13;
    /// Error when the attestation identifier cannot be located on-chain.
    const E_ATTESTATION_NOT_FOUND: u64 = 14;

    /// Extra window after maturity during which attestators can settle, in seconds.
    const ATTESTATOR_GRACE_PERIOD_SECONDS: u64 = 21600;

    /// Minimum stake in base units (e.g., 10,000 USDC with 6 decimals) required for attestators.
    const MIN_ATTESTATOR_STAKE: u64 = 10000_000000;

    /// Fee charged by attestators on successful settlements, expressed in basis points.
    const ATTESTATOR_FEE_BPS: u64 = 10;

    /// Attestator information
    struct AttestatorInfo has store {
        attestator_address: address,
        supported_receivable_types: vector<vector<u8>>, // e.g., ["NGN_COLLECTION", "INVOICE"]
        is_active: bool,

        // Reputation tracking
        total_attestations: u64,
        successful_settlements: u64,
        defaulted_settlements: u64,
        revoked_attestations: u64,

        // Stake for slashing
        stake_amount: u64,

        // Metadata
        metadata_uri: String, // Off-chain info about attestator
        registered_at: u64,
        last_activity: u64
    }

    /// Global registry of attestators
    struct AttestatorRegistry has key {
        admin_address: address,
        attestators: vector<address>,
        total_attestators: u64,

        // Attestator address => AttestatorInfo
        attestator_info: vector<AttestatorInfo>
    }

    /// Attestation record - created BEFORE PRT exists
    /// Keyed by a unique attestation ID (generated at attestation time)
    struct Attestation has key {
        attestation_id: address, // Unique ID for this attestation
        attestator_address: address,
        borrower_address: address,
        proof_hash: vector<u8>,
        receivable_type: vector<u8>, // "NGN_COLLECTION", "INVOICE", etc.
        amount: u64, // Expected receivable amount
        attestation_timestamp: u64,
        attestation_metadata: String, // Attestator's verification notes
        can_delegate_settlement: bool,

        // PRT tracking (set when PRT is created)
        prt_address: address, // @0x0 until PRT created
        is_used: bool, // Has credit been drawn using this attestation?

        // Settlement tracking
        is_settled: bool,
        settled_by_attestator: bool,
        settlement_timestamp: u64,

        // Object management
        extend_ref: ExtendRef,
        delete_ref: DeleteRef
    }

    /// Events
    #[event]
    struct AttestatorRegistered has drop, store {
        attestator: address,
        supported_receivable_types: vector<vector<u8>>,
        stake_amount: u64,
        timestamp: u64
    }

    #[event]
    struct AttestatorDeactivated has drop, store {
        attestator: address,
        reason: String,
        timestamp: u64
    }

    #[event]
    struct AttestatorStakeUpdated has drop, store {
        attestator: address,
        old_stake: u64,
        new_stake: u64,
        timestamp: u64
    }

    #[event]
    struct ReceivableAttested has drop, store {
        attestation_id: address,
        attestator: address,
        borrower: address,
        receivable_type: vector<u8>,
        proof_hash: vector<u8>,
        amount: u64,
        timestamp: u64
    }

    #[event]
    struct AttestationRevoked has drop, store {
        attestation_id: address,
        attestator: address,
        reason: String,
        timestamp: u64
    }

    #[event]
    struct AttestationUsed has drop, store {
        attestation_id: address,
        prt_address: address,
        timestamp: u64
    }

    #[event]
    struct PRTSettledByAttestator has drop, store {
        prt_address: address,
        attestator: address,
        borrower: address,
        principal: u64,
        interest: u64,
        attestator_fee: u64,
        was_within_grace_period: bool,
        timestamp: u64
    }

    #[event]
    struct AttestatorSlashed has drop, store {
        attestator: address,
        amount: u64,
        reason: String,
        timestamp: u64
    }

    /// Initialize attestator registry
    public entry fun initialize_registry(admin: &signer) {
        let admin_addr = signer::address_of(admin);

        let registry = AttestatorRegistry {
            admin_address: admin_addr,
            attestators: vector::empty<address>(),
            total_attestators: 0,
            attestator_info: vector::empty<AttestatorInfo>()
        };

        move_to(admin, registry);
    }

    /// Register a new attestator (admin only)
    /// Attestator must stake collateral
    public entry fun register_attestator<FA>(
        admin: &signer,
        attestator: &signer,
        attestator_address: address,
        supported_receivable_types: vector<vector<u8>>,
        stake_amount: u64,
        metadata_uri: String,
        fa_metadata: Object<Metadata>
    ) acquires AttestatorRegistry {
        let admin_addr = signer::address_of(admin);

        // Verify admin
        let registry = borrow_global_mut<AttestatorRegistry>(admin_addr);
        assert!(admin_addr == registry.admin_address, E_NOT_AUTHORIZED);

        // Verify not already registered
        assert!(
            !is_registered_internal(registry, attestator_address), E_ATTESTATOR_EXISTS
        );

        // Verify stake
        assert!(stake_amount >= MIN_ATTESTATOR_STAKE, E_INSUFFICIENT_STAKE);

        // Verify at least one receivable type
        assert!(supported_receivable_types.length() > 0, E_INVALID_RECEIVABLE_TYPE);

        let attestator_info = AttestatorInfo {
            attestator_address,
            supported_receivable_types,
            is_active: true,
            total_attestations: 0,
            successful_settlements: 0,
            defaulted_settlements: 0,
            revoked_attestations: 0,
            stake_amount,
            metadata_uri,
            registered_at: timestamp::now_seconds(),
            last_activity: timestamp::now_seconds()
        };

        registry.attestators.push_back(attestator_address);
        registry.attestator_info.push_back(attestator_info);
        registry.total_attestators += 1;

        // Transfer stake from attestator to protocol (admin address as escrow)
        pool::transfer_to_pool<FA>(
            attestator,
            admin_addr, // Using admin as protocol escrow
            stake_amount,
            fa_metadata
        );

        event::emit(
            AttestatorRegistered {
                attestator: attestator_address,
                supported_receivable_types,
                stake_amount,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Deactivate an attestator (admin only)
    public entry fun deactivate_attestator(
        admin: &signer, attestator_address: address, reason: String
    ) acquires AttestatorRegistry {
        let admin_addr = signer::address_of(admin);

        let registry = borrow_global_mut<AttestatorRegistry>(admin_addr);
        assert!(admin_addr == registry.admin_address, E_NOT_AUTHORIZED);

        let attestator_info = get_attestator_info_mut(registry, attestator_address);
        attestator_info.is_active = false;

        event::emit(
            AttestatorDeactivated {
                attestator: attestator_address,
                reason,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Reactivate an attestator (admin only)
    public entry fun reactivate_attestator(
        admin: &signer, attestator_address: address
    ) acquires AttestatorRegistry {
        let admin_addr = signer::address_of(admin);

        let registry = borrow_global_mut<AttestatorRegistry>(admin_addr);
        assert!(admin_addr == registry.admin_address, E_NOT_AUTHORIZED);

        let attestator_info = get_attestator_info_mut(registry, attestator_address);
        attestator_info.is_active = true;
    }

    /// Attestator adds more stake
    public entry fun add_stake(
        admin: &signer, attestator_address: address, additional_stake: u64
    ) acquires AttestatorRegistry {
        let admin_addr = signer::address_of(admin);

        let registry = borrow_global_mut<AttestatorRegistry>(admin_addr);
        assert!(admin_addr == registry.admin_address, E_NOT_AUTHORIZED);

        let attestator_info = get_attestator_info_mut(registry, attestator_address);
        let old_stake = attestator_info.stake_amount;
        attestator_info.stake_amount = old_stake + additional_stake;

        event::emit(
            AttestatorStakeUpdated {
                attestator: attestator_address,
                old_stake,
                new_stake: attestator_info.stake_amount,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Attest to a receivable BEFORE credit draw
    /// Called by attestator after off-chain verification
    /// Returns Object<Attestation> that can be used for credit draw
    public fun attest_receivable(
        attestator: &signer,
        borrower_address: address,
        proof_hash: vector<u8>,
        receivable_type: vector<u8>,
        amount: u64,
        attestation_metadata: String,
        can_delegate_settlement: bool,
        registry_addr: address
    ): Object<Attestation> acquires AttestatorRegistry {
        let attestator_addr = signer::address_of(attestator);

        // Verify attestator is registered and active
        let registry = borrow_global_mut<AttestatorRegistry>(registry_addr);
        assert!(
            is_registered_internal(registry, attestator_addr), E_ATTESTATOR_NOT_FOUND
        );

        let attestator_info = get_attestator_info_mut(registry, attestator_addr);
        assert!(attestator_info.is_active, E_ATTESTATOR_INACTIVE);

        // Verify receivable type is supported
        assert!(
            attestator_info.supported_receivable_types.contains(&receivable_type),
            E_INVALID_RECEIVABLE_TYPE
        );

        // Create attestation object
        let constructor_ref = object::create_object(attestator_addr);
        let object_signer = object::generate_signer(&constructor_ref);
        let attestation_id = object::address_from_constructor_ref(&constructor_ref);

        // Generate refs for future management
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let delete_ref = object::generate_delete_ref(&constructor_ref);

        // Create attestation record
        let attestation = Attestation {
            attestation_id,
            attestator_address: attestator_addr,
            borrower_address,
            proof_hash,
            receivable_type,
            amount,
            attestation_timestamp: timestamp::now_seconds(),
            attestation_metadata,
            can_delegate_settlement,
            prt_address: @0x0, // Will be set when PRT is created
            is_used: false,
            is_settled: false,
            settled_by_attestator: false,
            settlement_timestamp: 0,
            extend_ref,
            delete_ref
        };

        move_to(&object_signer, attestation);

        // Update attestator stats
        attestator_info.total_attestations += 1;
        attestator_info.last_activity = timestamp::now_seconds();

        event::emit(
            ReceivableAttested {
                attestation_id,
                attestator: attestator_addr,
                borrower: borrower_address,
                receivable_type,
                proof_hash,
                amount,
                timestamp: timestamp::now_seconds()
            }
        );

        object::object_from_constructor_ref<Attestation>(&constructor_ref)
    }

    /// Attest to a repayment for prefund loans
    /// This is used when borrower makes a partial repayment and attestator verifies they collected the receivable
    /// Returns Object<Attestation> that can be used for partial_repayment()
    public fun attest_repayment(
        attestator: &signer,
        borrower_address: address,
        prt_address: address, // Which PRT this repayment is for
        proof_hash: vector<u8>, // Proof of receivable collection (e.g., NGN transfer receipt)
        receivable_type: vector<u8>,
        amount_collected: u64, // Amount collected in USDC equivalent
        attestation_metadata: String, // Details about the collection
        registry_addr: address
    ): Object<Attestation> acquires AttestatorRegistry {
        let attestator_addr = signer::address_of(attestator);

        // Verify attestator is registered and active
        let registry = borrow_global_mut<AttestatorRegistry>(registry_addr);
        assert!(
            is_registered_internal(registry, attestator_addr), E_ATTESTATOR_NOT_FOUND
        );

        let attestator_info = get_attestator_info_mut(registry, attestator_addr);
        assert!(attestator_info.is_active, E_ATTESTATOR_INACTIVE);

        // Verify receivable type is supported
        assert!(
            attestator_info.supported_receivable_types.contains(&receivable_type),
            E_INVALID_RECEIVABLE_TYPE
        );

        // Create attestation object for this repayment
        let constructor_ref = object::create_object(attestator_addr);
        let object_signer = object::generate_signer(&constructor_ref);
        let attestation_id = object::address_from_constructor_ref(&constructor_ref);

        // Generate refs for future management
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let delete_ref = object::generate_delete_ref(&constructor_ref);

        // Create attestation record
        let attestation = Attestation {
            attestation_id,
            attestator_address: attestator_addr,
            borrower_address,
            proof_hash,
            receivable_type,
            amount: amount_collected,
            attestation_timestamp: timestamp::now_seconds(),
            attestation_metadata,
            can_delegate_settlement: false, // Repayment attestations don't delegate
            prt_address, // Already know which PRT
            is_used: false, // Will be marked used when repayment processed
            is_settled: false,
            settled_by_attestator: false,
            settlement_timestamp: 0,
            extend_ref,
            delete_ref
        };

        move_to(&object_signer, attestation);

        // Update attestator stats
        attestator_info.total_attestations += 1;
        attestator_info.last_activity = timestamp::now_seconds();

        event::emit(
            ReceivableAttested {
                attestation_id,
                attestator: attestator_addr,
                borrower: borrower_address,
                receivable_type,
                proof_hash,
                amount: amount_collected,
                timestamp: timestamp::now_seconds()
            }
        );

        object::object_from_constructor_ref<Attestation>(&constructor_ref)
    }

    /// Mark attestation as used when PRT is created
    /// Called by credit_engine when drawing credit
    /// This links the attestation to the actual PRT
    public fun mark_attestation_used(
        attestation: Object<Attestation>, prt_address: address
    ) acquires Attestation {
        let attestation_addr = object::object_address(&attestation);
        assert!(exists<Attestation>(attestation_addr), E_ATTESTATION_NOT_FOUND);

        let attestation_data = borrow_global_mut<Attestation>(attestation_addr);

        // Verify not already used
        assert!(!attestation_data.is_used, E_ATTESTATION_ALREADY_USED);

        // Mark as used and link to PRT
        attestation_data.is_used = true;
        attestation_data.prt_address = prt_address;

        event::emit(
            AttestationUsed {
                attestation_id: attestation_addr,
                prt_address,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Revoke an attestation (if borrower provided false info)
    /// This marks the attestation as invalid
    /// Can only revoke if not yet used for credit draw
    public entry fun revoke_attestation(
        attestator: &signer,
        attestation: Object<Attestation>,
        reason: String,
        registry_addr: address
    ) acquires Attestation, AttestatorRegistry {
        let attestator_addr = signer::address_of(attestator);
        let attestation_addr = object::object_address(&attestation);

        // Verify attestation exists
        assert!(exists<Attestation>(attestation_addr), E_ATTESTATION_NOT_FOUND);
        let attestation_data = borrow_global_mut<Attestation>(attestation_addr);

        // Verify caller is the attestator
        assert!(
            attestation_data.attestator_address == attestator_addr, E_WRONG_ATTESTATOR
        );

        // Verify not already used
        assert!(!attestation_data.is_used, E_ATTESTATION_ALREADY_USED);

        // Update attestator stats
        let registry = borrow_global_mut<AttestatorRegistry>(registry_addr);
        let attestator_info = get_attestator_info_mut(registry, attestator_addr);
        attestator_info.revoked_attestations += 1;

        event::emit(
            AttestationRevoked {
                attestation_id: attestation_addr,
                attestator: attestator_addr,
                reason,
                timestamp: timestamp::now_seconds()
            }
        );

        // Note: Attestation object deletion can be implemented for cleanup
        // This would require using the delete_ref stored in the Attestation struct:
        // let delete_ref = &attestation_data.delete_ref;
        // object::delete(delete_ref);
        // However, keeping revoked attestations may be useful for audit trails
    }

    /// Settle PRT on behalf of borrower (attestator provides funds)
    /// This is the key function where attestator collects off-chain and settles on-chain
    /// Attestator must provide the attestation object they created
    public entry fun settle_on_behalf<FA>(
        attestator: &signer,
        prt: Object<PRT<FA>>,
        attestation: Object<Attestation>,
        registry_addr: address,
        governance_addr: address,
        fa_metadata: Object<Metadata>
    ) acquires Attestation, AttestatorRegistry {
        let attestator_addr = signer::address_of(attestator);
        let prt_addr = object::object_address(&prt);
        let attestation_addr = object::object_address(&attestation);

        // Verify attestation exists
        assert!(exists<Attestation>(attestation_addr), E_ATTESTATION_NOT_FOUND);
        let attestation_data = borrow_global_mut<Attestation>(attestation_addr);

        // Verify attestation is for this PRT
        assert!(attestation_data.prt_address == prt_addr, E_WRONG_ATTESTATOR);

        // Verify caller is the attestator
        assert!(
            attestation_data.attestator_address == attestator_addr, E_WRONG_ATTESTATOR
        );

        // Verify can delegate settlement
        assert!(attestation_data.can_delegate_settlement, E_SETTLEMENT_NOT_ALLOWED);

        // Verify not already settled
        assert!(!attestation_data.is_settled, E_SETTLEMENT_NOT_ALLOWED);

        // Get PRT details
        let (
            borrower,
            principal,
            _interest_rate,
            maturity,
            _trust_score,
            _status,
            _creation_ts
        ) = prt::get_prt_info<FA>(prt);

        // Get pool address from PRT
        let pool_address = prt::get_pool_address<FA>(prt);

        // Calculate interest and attestator fee
        let interest = prt::calculate_interest<FA>(prt);
        let attestator_fee = (principal as u128) * (ATTESTATOR_FEE_BPS as u128) / 10000;
        let attestator_fee_u64 = (attestator_fee as u64);

        // Check if within grace period
        let current_time = timestamp::now_seconds();
        let grace_deadline = maturity + ATTESTATOR_GRACE_PERIOD_SECONDS;
        let was_within_grace = current_time <= grace_deadline;

        // Determine if on-time for trust score purposes
        // Attestator settlements within grace period count as on-time for borrower
        let is_on_time_for_borrower = current_time <= grace_deadline;

        // Transfer funds from attestator to pool
        let total_due = principal + interest;
        pool::transfer_to_pool<FA>(
            attestator,
            pool_address,
            total_due,
            fa_metadata
        );

        // Update attestation
        attestation_data.is_settled = true;
        attestation_data.settled_by_attestator = true;
        attestation_data.settlement_timestamp = current_time;

        // Update attestator stats
        let registry = borrow_global_mut<AttestatorRegistry>(registry_addr);
        let attestator_info = get_attestator_info_mut(registry, attestator_addr);

        if (was_within_grace) {
            attestator_info.successful_settlements += 1;
        } else {
            // Late settlement - attestator still settles but it's marked as late
            attestator_info.successful_settlements += 1;
        };

        attestator_info.last_activity = timestamp::now_seconds();

        // Update borrower trust score
        // If attestator settles within grace period, borrower gets credit for on-time payment
        let status = if (is_on_time_for_borrower) { 0u8 }
        else { 1u8 }; // STATUS_ON_TIME or STATUS_LATE
        trust_score::update_trust_score(borrower, principal, status, governance_addr);

        // Get pool address from PRT
        let pool_address = prt::get_pool_address<FA>(prt);

        // Update pool borrowed amount
        pool::update_borrowed<FA>(pool_address, principal, false);

        event::emit(
            PRTSettledByAttestator {
                prt_address: prt_addr,
                attestator: attestator_addr,
                borrower,
                principal,
                interest,
                attestator_fee: attestator_fee_u64,
                was_within_grace_period: was_within_grace,
                timestamp: current_time
            }
        );

        // Distribute yield to tranches
        tranche::distribute_yield<FA>(pool_address, interest, governance_addr);
    }

    /// Slash attestator stake (admin only, for false attestations leading to defaults)
    public entry fun slash_attestator<FA>(
        admin: &signer,
        attestator_address: address,
        slash_amount: u64,
        reason: String,
        pool_address: address
    ) acquires AttestatorRegistry {
        let admin_addr = signer::address_of(admin);

        let registry = borrow_global_mut<AttestatorRegistry>(admin_addr);
        assert!(admin_addr == registry.admin_address, E_NOT_AUTHORIZED);

        let attestator_info = get_attestator_info_mut(registry, attestator_address);

        // Reduce stake
        let actual_slash =
            if (attestator_info.stake_amount >= slash_amount) {
                attestator_info.stake_amount -= slash_amount;
                slash_amount
            } else {
                let slashed = attestator_info.stake_amount;
                attestator_info.stake_amount = 0;
                slashed
            };

        // Transfer slashed amount to protocol reserve
        // Note: The slashed funds are already held in escrow (admin address)
        // We add them to the pool's reserve balance
        pool::add_to_reserve<FA>(pool_address, actual_slash);

        event::emit(
            AttestatorSlashed {
                attestator: attestator_address,
                amount: slash_amount,
                reason,
                timestamp: timestamp::now_seconds()
            }
        );

        // If stake falls below minimum, deactivate
        if (attestator_info.stake_amount < MIN_ATTESTATOR_STAKE) {
            attestator_info.is_active = false;
        };
    }

    /// Internal helper to check if attestator is registered
    fun is_registered_internal(
        registry: &AttestatorRegistry, addr: address
    ): bool {
        registry.attestators.contains(&addr)
    }

    /// Internal helper to get mutable attestator info
    fun get_attestator_info_mut(
        registry: &mut AttestatorRegistry, addr: address
    ): &mut AttestatorInfo {
        let len = registry.attestators.length();
        let i = 0;

        while (i < len) {
            let attestator_addr = registry.attestators[i];
            if (attestator_addr == addr) {
                return registry.attestator_info.borrow_mut(i)
            };
            i += 1;
        };

        abort E_ATTESTATOR_NOT_FOUND
    }

    /// Internal helper to get immutable attestator info
    fun get_attestator_info(
        registry: &AttestatorRegistry, addr: address
    ): &AttestatorInfo {
        let len = registry.attestators.length();
        let i = 0;

        while (i < len) {
            let attestator_addr = registry.attestators[i];
            if (attestator_addr == addr) {
                return registry.attestator_info.borrow(i)
            };
            i += 1;
        };

        abort E_ATTESTATOR_NOT_FOUND
    }

    /// View functions

    #[view]
    public fun is_registered(
        registry_addr: address, attestator: address
    ): bool acquires AttestatorRegistry {
        if (!exists<AttestatorRegistry>(registry_addr)) {
            return false
        };
        let registry = borrow_global<AttestatorRegistry>(registry_addr);
        is_registered_internal(registry, attestator)
    }

    #[view]
    public fun is_active(
        registry_addr: address, attestator: address
    ): bool acquires AttestatorRegistry {
        if (!exists<AttestatorRegistry>(registry_addr)) {
            return false
        };
        let registry = borrow_global<AttestatorRegistry>(registry_addr);
        if (!is_registered_internal(registry, attestator)) {
            return false
        };
        let info = get_attestator_info(registry, attestator);
        info.is_active
    }

    #[view]
    public fun get_attestator_stake(
        registry_addr: address, attestator: address
    ): u64 acquires AttestatorRegistry {
        let registry = borrow_global<AttestatorRegistry>(registry_addr);
        let info = get_attestator_info(registry, attestator);
        info.stake_amount
    }

    #[view]
    public fun get_attestator_stats(
        registry_addr: address, attestator: address
    ): (u64, u64, u64, u64) acquires AttestatorRegistry {
        let registry = borrow_global<AttestatorRegistry>(registry_addr);
        let info = get_attestator_info(registry, attestator);
        (
            info.total_attestations,
            info.successful_settlements,
            info.defaulted_settlements,
            info.revoked_attestations
        )
    }

    #[view]
    public fun get_attestation_info(
        attestation: Object<Attestation>
    ): (address, address, vector<u8>, u64, bool, bool, address) acquires Attestation {
        let attestation_addr = object::object_address(&attestation);
        assert!(exists<Attestation>(attestation_addr), E_ATTESTATION_NOT_FOUND);
        let attestation_data = borrow_global<Attestation>(attestation_addr);
        (
            attestation_data.borrower_address,
            attestation_data.attestator_address,
            attestation_data.receivable_type,
            attestation_data.amount,
            attestation_data.can_delegate_settlement,
            attestation_data.is_used,
            attestation_data.prt_address
        )
    }

    #[view]
    public fun is_attestation_valid(attestation: Object<Attestation>): bool acquires Attestation {
        let attestation_addr = object::object_address(&attestation);
        if (!exists<Attestation>(attestation_addr)) {
            return false
        };
        let attestation_data = borrow_global<Attestation>(attestation_addr);
        // Valid if not used yet
        !attestation_data.is_used
    }

    #[view]
    public fun supports_receivable_type(
        registry_addr: address, attestator: address, receivable_type: vector<u8>
    ): bool acquires AttestatorRegistry {
        if (!exists<AttestatorRegistry>(registry_addr)) {
            return false
        };
        let registry = borrow_global<AttestatorRegistry>(registry_addr);
        if (!is_registered_internal(registry, attestator)) {
            return false
        };
        let info = get_attestator_info(registry, attestator);
        info.supported_receivable_types.contains(&receivable_type)
    }

    #[view]
    public fun get_all_attestators(
        registry_addr: address
    ): vector<address> acquires AttestatorRegistry {
        if (!exists<AttestatorRegistry>(registry_addr)) {
            return vector::empty<address>()
        };
        let registry = borrow_global<AttestatorRegistry>(registry_addr);
        registry.attestators
    }

    #[view]
    public fun get_grace_period_seconds(): u64 {
        ATTESTATOR_GRACE_PERIOD_SECONDS
    }

    #[view]
    public fun get_attestator_fee_bps(): u64 {
        ATTESTATOR_FEE_BPS
    }

    #[view]
    public fun get_min_stake(): u64 {
        MIN_ATTESTATOR_STAKE
    }
}
