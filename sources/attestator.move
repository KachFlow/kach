module kach::attestator {
    use std::signer;
    use std::string::String;
    use std::vector;
    use aptos_framework::object::{Self, Object, ExtendRef, DeleteRef};
    use aptos_framework::event;
    use aptos_framework::timestamp;

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
    /// Error when the receivable type specified does not match the allowed set.
    const E_INVALID_RECEIVABLE_TYPE: u64 = 10;
    /// Error when trying to reuse an attestation that already backed a draw.
    const E_ATTESTATION_ALREADY_USED: u64 = 11;
    /// Error when the attestation identifier cannot be located on-chain.
    const E_ATTESTATION_NOT_FOUND: u64 = 12;
    /// Error when a settlement attempt is made by a different attestator.
    const E_WRONG_ATTESTATOR: u64 = 13;

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
        timestamp: u64
    }

    #[event]
    struct AttestatorDeactivated has drop, store {
        attestator: address,
        reason: String,
        timestamp: u64
    }

    #[event]
    struct ReceivableAttested has drop, store {
        attestation_id: address,
        attestator: address,
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
    public entry fun register_attestator(
        admin: &signer,
        attestator_address: address,
        supported_receivable_types: vector<vector<u8>>,
        metadata_uri: String
    ) acquires AttestatorRegistry {
        let admin_addr = signer::address_of(admin);

        // Verify admin
        let registry = borrow_global_mut<AttestatorRegistry>(admin_addr);
        assert!(admin_addr == registry.admin_address, E_NOT_AUTHORIZED);

        // Verify not already registered
        assert!(
            !is_registered_internal(registry, attestator_address), E_ATTESTATOR_EXISTS
        );

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
            metadata_uri,
            registered_at: timestamp::now_seconds(),
            last_activity: timestamp::now_seconds()
        };

        registry.attestators.push_back(attestator_address);
        registry.attestator_info.push_back(attestator_info);
        registry.total_attestators += 1;

        event::emit(
            AttestatorRegistered {
                attestator: attestator_address,
                supported_receivable_types,
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

    /// Attest to a receivable BEFORE credit draw
    /// Called by attestator after off-chain verification
    /// Returns Object<Attestation> that can be used for credit draw
    public fun attest_receivable(
        attestator: &signer,
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
                receivable_type,
                proof_hash,
                amount,
                timestamp: timestamp::now_seconds()
            }
        );

        object::object_from_constructor_ref<Attestation>(&constructor_ref)
    }

    /// Attest to a repayment for prefund loans
    /// This is used when attestator verifies they collected the receivable
    /// Returns Object<Attestation> that can be used for partial_repayment()
    public fun attest_repayment(
        attestator: &signer,
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

    /// Revoke an attestation (if attestator determines it's invalid)
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
    ): (address, vector<u8>, u64, bool, bool, address) acquires Attestation {
        let attestation_addr = object::object_address(&attestation);
        assert!(exists<Attestation>(attestation_addr), E_ATTESTATION_NOT_FOUND);
        let attestation_data = borrow_global<Attestation>(attestation_addr);
        (
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
}
