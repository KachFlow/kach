module kach::prt {
    use std::signer;
    use std::string::String;
    use std::vector;

    use aptos_framework::object::{Self, Object, ExtendRef, DeleteRef};
    use aptos_framework::event;
    use aptos_framework::timestamp;

    /// Status assigned to every newly minted PRT while the loan is still outstanding.
    const STATUS_OPEN: u8 = 0;
    /// Status used once the attestator has fully repaid the receivable.
    const STATUS_REPAID: u8 = 1;
    /// Status indicating the receivable defaulted and cannot be collected.
    const STATUS_DEFAULTED: u8 = 2;
    /// Status representing that the receivable is overdue but not yet defaulted.
    const STATUS_LATE: u8 = 3;

    /// Error when a caller without the proper capability or signer attempts an action.
    const E_NOT_AUTHORIZED: u64 = 1;
    /// Error when attempting to settle or repay a PRT that is already closed out.
    const E_ALREADY_SETTLED: u64 = 2;
    /// Error when trying to repay or settle before the maturity timestamp is reached.
    const E_NOT_MATURED: u64 = 3;

    /// Payment Receivable Token - non-transferable, soulbound to Pool<FA>
    /// Generic design ensures type safety with the underlying asset
    /// Flexible receivable type (fiat transfer, invoice, shipment, etc.)
    /// Supports both standard (single repayment) and prefund (partial repayments)
    struct PRT<phantom FA> has key {
        // Loan details
        principal: u64, // Original principal
        outstanding_principal: u64, // Remaining principal (decreases with partial repayments)
        interest_rate_bps: u64, // Per tenor (e.g., 120 bps for 30-day)
        tenor_seconds: u64,
        maturity_timestamp: u64,

        // Attestator information
        attestator_address: address,
        trust_score_snapshot: u64,

        // Prefund specific fields
        is_prefund: bool, // TRUE for prefund loans
        requires_attested_repayments: bool, // TRUE for prefund (every repayment needs attestation)

        // Partial repayment tracking
        total_repaid: u64, // Total principal repaid so far
        total_interest_paid: u64, // Total interest paid so far
        repayment_count: u64, // Number of repayments made
        last_repayment_timestamp: u64, // Last time a repayment was made (for interest calc)
        accrued_interest: u64, // Interest accrued but not yet paid

        // Generic proof of underlying receivable (for standard flow)
        // For prefund, proof comes with each repayment attestation
        proof_hash: vector<u8>,

        // Optional off-chain metadata (URI to JSON with context)
        // Can include corridor info, business details, etc.
        metadata_uri: String,

        // Status tracking
        status: u8,
        creation_timestamp: u64,
        actual_repayment_timestamp: u64, // Final repayment timestamp

        // Pool reference - type-safe association with Pool<FA>
        pool_address: address,

        // Object management
        extend_ref: ExtendRef,
        delete_ref: DeleteRef
    }

    /// Events
    #[event]
    struct PRTMinted has drop, store {
        prt_address: address,
        attestator: address,
        pool_address: address,
        principal: u64,
        interest_rate_bps: u64,
        tenor_seconds: u64,
        maturity_timestamp: u64,
        timestamp: u64
    }

    #[event]
    struct PRTRepaid has drop, store {
        prt_address: address,
        attestator: address,
        principal: u64,
        interest: u64,
        actual_repayment_timestamp: u64,
        is_on_time: bool,
        timestamp: u64
    }

    #[event]
    struct PRTDefaulted has drop, store {
        prt_address: address,
        attestator: address,
        principal: u64,
        interest_owed: u64,
        timestamp: u64
    }

    #[event]
    struct PRTMarkedLate has drop, store {
        prt_address: address,
        attestator: address,
        days_late: u64,
        timestamp: u64
    }

    #[event]
    struct PRTPartialRepayment has drop, store {
        prt_address: address,
        attestator: address,
        repayment_amount: u64,
        interest_paid: u64,
        early_discount: u64,
        outstanding_principal: u64,
        repayment_number: u64,
        timestamp: u64
    }

    /// Mint a new PRT for a credit draw
    /// FA type parameter ensures type safety with Pool<FA>
    /// Only callable by pool or credit engine
    public fun mint_prt<FA>(
        pool_signer: &signer,
        attestator_address: address,
        principal: u64,
        interest_rate_bps: u64,
        tenor_seconds: u64,
        trust_score: u64,
        proof_hash: vector<u8>,
        metadata_uri: String,
        pool_address: address
    ): Object<PRT<FA>> {
        // Create object owned by pool (non-transferable)
        let constructor_ref = object::create_object(signer::address_of(pool_signer));
        let object_signer = object::generate_signer(&constructor_ref);

        // Generate refs
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let delete_ref = object::generate_delete_ref(&constructor_ref);

        // Make object non-transferable (soulbound to pool)
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        object::disable_ungated_transfer(&transfer_ref);

        let maturity_timestamp = timestamp::now_seconds() + tenor_seconds;
        let creation_ts = timestamp::now_seconds();

        let prt = PRT<FA> {
            principal,
            outstanding_principal: principal, // Initially equals principal
            interest_rate_bps,
            tenor_seconds,
            maturity_timestamp,
            attestator_address,
            trust_score_snapshot: trust_score,
            is_prefund: false, // Default to standard loan
            requires_attested_repayments: false,
            total_repaid: 0,
            total_interest_paid: 0,
            repayment_count: 0,
            last_repayment_timestamp: creation_ts,
            accrued_interest: 0,
            proof_hash,
            metadata_uri,
            status: STATUS_OPEN,
            creation_timestamp: creation_ts,
            actual_repayment_timestamp: 0,
            pool_address,
            extend_ref,
            delete_ref
        };

        let prt_address = object::address_from_constructor_ref(&constructor_ref);

        move_to(&object_signer, prt);

        // Emit event
        event::emit(
            PRTMinted {
                prt_address,
                attestator: attestator_address,
                pool_address,
                principal,
                interest_rate_bps,
                tenor_seconds,
                maturity_timestamp,
                timestamp: timestamp::now_seconds()
            }
        );

        object::object_from_constructor_ref<PRT<FA>>(&constructor_ref)
    }

    /// Mint a new prefund PRT (allows partial repayments)
    /// Similar to mint_prt but sets is_prefund = true
    public fun mint_prefund_prt<FA>(
        pool_signer: &signer,
        attestator_address: address,
        principal: u64,
        interest_rate_bps: u64,
        tenor_seconds: u64,
        trust_score: u64,
        metadata_uri: String,
        pool_address: address
    ): Object<PRT<FA>> {
        // Create object owned by pool (non-transferable)
        let constructor_ref = object::create_object(signer::address_of(pool_signer));
        let object_signer = object::generate_signer(&constructor_ref);

        // Generate refs
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let delete_ref = object::generate_delete_ref(&constructor_ref);

        // Make object non-transferable (soulbound to pool)
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        object::disable_ungated_transfer(&transfer_ref);

        let maturity_timestamp = timestamp::now_seconds() + tenor_seconds;
        let creation_ts = timestamp::now_seconds();

        let prt = PRT<FA> {
            principal,
            outstanding_principal: principal,
            interest_rate_bps,
            tenor_seconds,
            maturity_timestamp,
            attestator_address,
            trust_score_snapshot: trust_score,
            is_prefund: true, // PREFUND loan
            requires_attested_repayments: true, // Every repayment needs attestation
            total_repaid: 0,
            total_interest_paid: 0,
            repayment_count: 0,
            last_repayment_timestamp: creation_ts,
            accrued_interest: 0,
            proof_hash: vector::empty<u8>(), // No single proof for prefund
            metadata_uri,
            status: STATUS_OPEN,
            creation_timestamp: creation_ts,
            actual_repayment_timestamp: 0,
            pool_address,
            extend_ref,
            delete_ref
        };

        let prt_address = object::address_from_constructor_ref(&constructor_ref);

        move_to(&object_signer, prt);

        // Emit event
        event::emit(
            PRTMinted {
                prt_address,
                attestator: attestator_address,
                pool_address,
                principal,
                interest_rate_bps,
                tenor_seconds,
                maturity_timestamp,
                timestamp: timestamp::now_seconds()
            }
        );

        object::object_from_constructor_ref<PRT<FA>>(&constructor_ref)
    }

    /// Make a partial repayment on a prefund PRT
    /// Can only be called on prefund PRTs
    /// Returns (repayment_amount, interest_paid, early_discount, new_outstanding)
    public fun partial_repay_prt<FA>(
        _pool_signer: &signer, prt: Object<PRT<FA>>, repayment_amount: u64
    ): (u64, u64, u64, u64) acquires PRT {
        let prt_addr = object::object_address(&prt);
        let prt_data = borrow_global_mut<PRT<FA>>(prt_addr);

        // Verify this is a prefund PRT
        assert!(prt_data.is_prefund, E_NOT_AUTHORIZED);

        // Verify not already fully settled
        assert!(
            prt_data.status == STATUS_OPEN || prt_data.status == STATUS_LATE,
            E_ALREADY_SETTLED
        );

        // Verify repayment amount doesn't exceed outstanding
        assert!(repayment_amount <= prt_data.outstanding_principal, E_NOT_AUTHORIZED);

        // Calculate time-weighted interest using interest_rate module
        // This will be imported and called properly
        let (interest_owed, early_discount) =
            calculate_prefund_interest(
                prt_data.outstanding_principal,
                repayment_amount,
                prt_data.interest_rate_bps,
                prt_data.creation_timestamp,
                prt_data.last_repayment_timestamp,
                prt_data.maturity_timestamp
            );

        // Update PRT state
        prt_data.total_repaid += repayment_amount;
        prt_data.total_interest_paid += interest_owed - early_discount;
        prt_data.outstanding_principal -= repayment_amount;
        prt_data.repayment_count += 1;
        prt_data.last_repayment_timestamp = timestamp::now_seconds();

        // If fully repaid, mark as settled
        if (prt_data.outstanding_principal == 0) {
            prt_data.status = STATUS_REPAID;
            prt_data.actual_repayment_timestamp = timestamp::now_seconds();
        };

        let new_outstanding = prt_data.outstanding_principal;
        let attestator = prt_data.attestator_address;
        let repayment_number = prt_data.repayment_count;

        // Emit partial repayment event
        event::emit(
            PRTPartialRepayment {
                prt_address: prt_addr,
                attestator,
                repayment_amount,
                interest_paid: interest_owed - early_discount,
                early_discount,
                outstanding_principal: new_outstanding,
                repayment_number,
                timestamp: timestamp::now_seconds()
            }
        );

        (
            repayment_amount,
            interest_owed - early_discount,
            early_discount,
            new_outstanding
        )
    }

    /// Helper function to calculate interest for prefund PRTs
    /// This uses the interest_rate module's time-weighted calculation
    fun calculate_prefund_interest(
        outstanding_principal: u64,
        repayment_amount: u64,
        rate_bps: u64,
        creation_timestamp: u64,
        last_repayment_timestamp: u64,
        maturity_timestamp: u64
    ): (u64, u64) {
        // Use the interest_rate module's calculate_repayment_interest function
        use kach::interest_rate;

        interest_rate::calculate_repayment_interest(
            outstanding_principal,
            repayment_amount,
            rate_bps,
            creation_timestamp,
            last_repayment_timestamp,
            maturity_timestamp
        )
    }

    /// Mark PRT as repaid and burn it
    /// Returns (principal, interest, was_on_time)
    public fun repay_prt<FA>(_pool_signer: &signer, prt: Object<PRT<FA>>): (u64, u64, bool) acquires PRT {
        let prt_addr = object::object_address(&prt);
        let prt_data = borrow_global_mut<PRT<FA>>(prt_addr);

        // Verify not already settled
        assert!(
            prt_data.status == STATUS_OPEN || prt_data.status == STATUS_LATE,
            E_ALREADY_SETTLED
        );

        let interest = calculate_interest_internal(prt_data);
        let principal = prt_data.principal;
        let attestator = prt_data.attestator_address;
        let is_on_time = timestamp::now_seconds() <= prt_data.maturity_timestamp;

        // Update status
        prt_data.status = STATUS_REPAID;
        prt_data.actual_repayment_timestamp = timestamp::now_seconds();

        // Emit event
        event::emit(
            PRTRepaid {
                prt_address: prt_addr,
                attestator,
                principal,
                interest,
                actual_repayment_timestamp: timestamp::now_seconds(),
                is_on_time,
                timestamp: timestamp::now_seconds()
            }
        );

        // Note: Don't delete yet, keep for historical record
        // Can add cleanup function later

        (principal, interest, is_on_time)
    }

    /// Mark PRT as defaulted
    public fun default_prt<FA>(
        _pool_signer: &signer, prt: Object<PRT<FA>>
    ): (u64, u64) acquires PRT {
        let prt_addr = object::object_address(&prt);
        let prt_data = borrow_global_mut<PRT<FA>>(prt_addr);

        assert!(
            prt_data.status == STATUS_OPEN || prt_data.status == STATUS_LATE,
            E_ALREADY_SETTLED
        );

        let principal = prt_data.principal;
        let interest = calculate_interest_internal(prt_data);
        let attestator = prt_data.attestator_address;

        prt_data.status = STATUS_DEFAULTED;

        event::emit(
            PRTDefaulted {
                prt_address: prt_addr,
                attestator,
                principal,
                interest_owed: interest,
                timestamp: timestamp::now_seconds()
            }
        );

        (principal, interest)
    }

    /// Mark PRT as late (for monitoring)
    public entry fun mark_late<FA>(
        _pool_signer: &signer, prt: Object<PRT<FA>>
    ) acquires PRT {
        let prt_addr = object::object_address(&prt);
        let prt_data = borrow_global_mut<PRT<FA>>(prt_addr);

        assert!(prt_data.status == STATUS_OPEN, E_ALREADY_SETTLED);
        assert!(timestamp::now_seconds() > prt_data.maturity_timestamp, E_NOT_MATURED);

        prt_data.status = STATUS_LATE;

        let days_late = (timestamp::now_seconds() - prt_data.maturity_timestamp) / 86400;

        event::emit(
            PRTMarkedLate {
                prt_address: prt_addr,
                attestator: prt_data.attestator_address,
                days_late,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Calculate interest owed on a PRT
    #[view]
    public fun calculate_interest<FA>(prt: Object<PRT<FA>>): u64 acquires PRT {
        let prt_data = borrow_global<PRT<FA>>(object::object_address(&prt));
        calculate_interest_internal(prt_data)
    }

    /// Internal interest calculation
    fun calculate_interest_internal<FA>(prt_data: &PRT<FA>): u64 {
        // Interest = principal * rate_bps / 10000
        ((prt_data.principal as u128) * (prt_data.interest_rate_bps as u128) / 10000 as u64)
    }

    /// Check if PRT is late
    #[view]
    public fun is_late<FA>(prt: Object<PRT<FA>>): bool acquires PRT {
        let prt_data = borrow_global<PRT<FA>>(object::object_address(&prt));
        prt_data.status == STATUS_OPEN
            && timestamp::now_seconds() > prt_data.maturity_timestamp
    }

    /// Check if PRT is open
    #[view]
    public fun is_open<FA>(prt: Object<PRT<FA>>): bool acquires PRT {
        let prt_data = borrow_global<PRT<FA>>(object::object_address(&prt));
        prt_data.status == STATUS_OPEN || prt_data.status == STATUS_LATE
    }

    /// Get PRT details
    #[view]
    public fun get_prt_info<FA>(prt: Object<PRT<FA>>)
        : (address, u64, u64, u64, u64, u8, u64) acquires PRT {
        let prt_data = borrow_global<PRT<FA>>(object::object_address(&prt));
        (
            prt_data.attestator_address,
            prt_data.principal,
            prt_data.interest_rate_bps,
            prt_data.maturity_timestamp,
            prt_data.trust_score_snapshot,
            prt_data.status,
            prt_data.creation_timestamp
        )
    }

    /// Get days until maturity (returns days and is_late flag)
    #[view]
    public fun days_until_maturity<FA>(prt: Object<PRT<FA>>): (u64, bool) acquires PRT {
        let prt_data = borrow_global<PRT<FA>>(object::object_address(&prt));
        let current_time = timestamp::now_seconds();

        if (current_time >= prt_data.maturity_timestamp) {
            // Late - return days overdue with late=true
            let days_overdue = (current_time - prt_data.maturity_timestamp) / 86400;
            (days_overdue, true)
        } else {
            // On time - return days remaining with late=false
            let days_remaining = (prt_data.maturity_timestamp - current_time) / 86400;
            (days_remaining, false)
        }
    }

    /// Get total amount due (principal + interest)
    #[view]
    public fun total_amount_due<FA>(prt: Object<PRT<FA>>): u64 acquires PRT {
        let prt_data = borrow_global<PRT<FA>>(object::object_address(&prt));
        prt_data.principal + calculate_interest_internal(prt_data)
    }

    /// Get proof hash (for verification)
    #[view]
    public fun get_proof_hash<FA>(prt: Object<PRT<FA>>): vector<u8> acquires PRT {
        let prt_data = borrow_global<PRT<FA>>(object::object_address(&prt));
        prt_data.proof_hash
    }

    /// Get metadata URI
    #[view]
    public fun get_metadata_uri<FA>(prt: Object<PRT<FA>>): String acquires PRT {
        let prt_data = borrow_global<PRT<FA>>(object::object_address(&prt));
        prt_data.metadata_uri
    }

    /// Get pool address (for verification)
    #[view]
    public fun get_pool_address<FA>(prt: Object<PRT<FA>>): address acquires PRT {
        let prt_data = borrow_global<PRT<FA>>(object::object_address(&prt));
        prt_data.pool_address
    }

    /// Get attestator address
    #[view]
    public fun get_attestator<FA>(prt: Object<PRT<FA>>): address acquires PRT {
        let prt_data = borrow_global<PRT<FA>>(object::object_address(&prt));
        prt_data.attestator_address
    }
}
