module kach::credit_engine {
    use std::signer;
    use std::string::String;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::event;
    use aptos_framework::timestamp;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::smart_table::{Self, SmartTable};

    use kach::pool;
    use kach::prt;
    use kach::trust_score;
    use kach::attestator::{Self, Attestation};
    use kach::interest_rate;
    use kach::governance;

    /// Error when caller is not authorized to mutate the credit engine state.
    const E_NOT_AUTHORIZED: u64 = 1;
    /// Error when trying to create a credit line that already exists.
    const E_CREDIT_LINE_EXISTS: u64 = 2;
    /// Error when referencing a credit line that has not been created.
    const E_CREDIT_LINE_NOT_FOUND: u64 = 3;
    /// Error when a draw exceeds the attestator's remaining limit.
    const E_INSUFFICIENT_LIMIT: u64 = 4;
    /// Error when an inactive credit line is used for a draw or update.
    const E_CREDIT_LINE_INACTIVE: u64 = 5;
    /// Error when the underlying pool cannot supply the requested liquidity.
    const E_POOL_INSUFFICIENT_LIQUIDITY: u64 = 6;
    /// Error when a attestator's trust score fails to meet the required threshold.
    const E_TRUST_SCORE_TOO_LOW: u64 = 7;

    /// Minimum tenor for standard draws (1 day in seconds)
    const MIN_STANDARD_TENOR_SECONDS: u64 = 86400; // 1 day

    /// Maximum tenor for standard draws (5 days in seconds)
    const MAX_STANDARD_TENOR_SECONDS: u64 = 432000; // 5 days

    /// Credit line for a attestator - tied to specific asset pool
    struct CreditLine<phantom FA> has store, drop {
        attestator_address: address,
        pool_address: address,

        // Limits
        max_outstanding: u64, // Maximum total outstanding
        current_outstanding: u64, // Currently borrowed

        // Default tenor settings
        default_tenor_seconds: u64, // e.g., 259200 = 3 days
        default_interest_rate_bps: u64, // e.g., 20 bps

        // Status
        is_active: bool,

        // Timestamps
        created_at: u64,
        last_review_timestamp: u64,
        last_draw_timestamp: u64,

        // Statistics
        total_draws_count: u64,
        total_volume_drawn: u64,
        total_repayments_count: u64,
        total_volume_repaid: u64
    }

    /// Global registry of credit lines per asset type
    /// Maps attestator address -> credit line
    struct CreditLineRegistry<phantom FA> has key {
        credit_lines: SmartTable<address, CreditLine<FA>>,
        total_credit_lines: u64
    }

    /// Events
    #[event]
    struct CreditLineCreated has drop, store {
        attestator: address,
        pool_address: address,
        max_outstanding: u64,
        timestamp: u64
    }

    #[event]
    struct CreditDrawn has drop, store {
        attestator: address,
        pool_address: address,
        amount: u64,
        tenor_seconds: u64,
        interest_rate_bps: u64,
        prt_address: address,
        trust_score: u64,
        timestamp: u64
    }

    #[event]
    struct CreditRepaid has drop, store {
        attestator: address,
        pool_address: address,
        principal: u64,
        interest: u64,
        was_on_time: bool,
        prt_address: address,
        timestamp: u64
    }

    #[event]
    struct CreditLineUpdated has drop, store {
        attestator: address,
        old_max_outstanding: u64,
        new_max_outstanding: u64,
        timestamp: u64
    }

    #[event]
    struct CreditLineDeactivated has drop, store {
        attestator: address,
        reason: String,
        timestamp: u64
    }

    /// Initialize credit line registry for an asset type
    public entry fun initialize_registry<FA>(admin: &signer) {
        let registry = CreditLineRegistry<FA> {
            credit_lines: smart_table::new(),
            total_credit_lines: 0
        };

        move_to(admin, registry);
    }

    /// Create a new credit line for a attestator
    /// Only admin can create credit lines (after KYB/underwriting)
    public entry fun create_credit_line<FA>(
        admin: &signer,
        registry_address: address,
        attestator_address: address,
        pool_address: address,
        max_outstanding: u64,
        default_tenor_seconds: u64,
        default_interest_rate_bps: u64,
        governance_address: address
    ) acquires CreditLineRegistry {
        let admin_addr = signer::address_of(admin);

        // Check permission to create credit line
        assert!(
            governance::can_create_credit_line(governance_address, admin_addr),
            E_NOT_AUTHORIZED
        );

        // Get registry
        let registry = borrow_global_mut<CreditLineRegistry<FA>>(registry_address);

        // Verify credit line doesn't already exist
        assert!(
            !smart_table::contains(&registry.credit_lines, attestator_address),
            E_CREDIT_LINE_EXISTS
        );

        // Initialize trust score for attestator in this pool
        trust_score::initialize_trust_score(
            admin,
            attestator_address,
            pool_address,
            max_outstanding,
            governance_address
        );

        let credit_line = CreditLine<FA> {
            attestator_address,
            pool_address,
            max_outstanding,
            current_outstanding: 0,
            default_tenor_seconds,
            default_interest_rate_bps,
            is_active: true,
            created_at: timestamp::now_seconds(),
            last_review_timestamp: timestamp::now_seconds(),
            last_draw_timestamp: 0,
            total_draws_count: 0,
            total_volume_drawn: 0,
            total_repayments_count: 0,
            total_volume_repaid: 0
        };

        smart_table::add(&mut registry.credit_lines, attestator_address, credit_line);
        registry.total_credit_lines += 1;

        event::emit(
            CreditLineCreated {
                attestator: attestator_address,
                pool_address,
                max_outstanding,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Draw credit from the pool
    /// REQUIRES attestation to be created first by an approved attestator
    /// Creates a PRT and transfers fungible assets to attestator
    public entry fun draw_credit<FA>(
        attestator: &signer,
        registry_address: address,
        attestation: Object<Attestation>,
        tenor_seconds: u64,
        governance_address: address,
        fa_metadata: Object<Metadata>
    ) acquires CreditLineRegistry {
        let attestator_addr = signer::address_of(attestator);

        // Get credit line
        let registry = borrow_global_mut<CreditLineRegistry<FA>>(registry_address);
        assert!(
            smart_table::contains(&registry.credit_lines, attestator_addr),
            E_CREDIT_LINE_NOT_FOUND
        );
        let credit_line = smart_table::borrow_mut(&mut registry.credit_lines, attestator_addr);

        // Verify active
        assert!(credit_line.is_active, E_CREDIT_LINE_INACTIVE);

        // Verify attestation is valid (not already used)
        assert!(attestator::is_attestation_valid(attestation), E_NOT_AUTHORIZED);

        // Get attestation details
        let (
            attestator_from_attestation,
            _receivable_type,
            amount,
            _is_used,
            _prt_addr
        ) = attestator::get_attestation_info(attestation);

        // Verify attestation is for this attestator
        assert!(attestator_from_attestation == attestator_addr, E_NOT_AUTHORIZED);

        // Get trust score
        let trust_score_value =
            trust_score::get_trust_score(attestator_addr, credit_line.pool_address, governance_address);
        assert!(
            trust_score_value >= trust_score::min_trust_score_to_draw(),
            E_TRUST_SCORE_TOO_LOW
        );

        // Check limit (use attested amount)
        let new_outstanding = credit_line.current_outstanding + amount;
        assert!(new_outstanding <= credit_line.max_outstanding, E_INSUFFICIENT_LIMIT);

        // Check pool has liquidity
        let available = pool::available_liquidity<FA>(credit_line.pool_address);
        assert!(amount <= available, E_POOL_INSUFFICIENT_LIQUIDITY);

        // Use default values if not specified (0 means use default)
        let actual_tenor =
            if (tenor_seconds == 0) {
                credit_line.default_tenor_seconds
            } else {
                tenor_seconds
            };

        // Validate tenor is within 1-5 day range for standard draws per documentation
        assert!(
            actual_tenor >= MIN_STANDARD_TENOR_SECONDS
                && actual_tenor <= MAX_STANDARD_TENOR_SECONDS,
            E_NOT_AUTHORIZED
        );

        let interest_rate = credit_line.default_interest_rate_bps;

        // Create PRT (pool signer will be created by pool module)
        // Note: In production, this would go through pool module
        // For now, we'll emit event and update state
        let prt_address = @0x0; // Will be actual PRT address in production

        // Mark attestation as used (links attestation to PRT)
        attestator::mark_attestation_used(attestation, prt_address);

        // Update credit line state
        credit_line.current_outstanding = new_outstanding;
        credit_line.last_draw_timestamp = timestamp::now_seconds();
        credit_line.total_draws_count += 1;
        credit_line.total_volume_drawn += amount;

        // Update pool borrowed amount
        pool::update_borrowed<FA>(credit_line.pool_address, amount, true);

        // Increment PRT counter
        pool::increment_prt_counter<FA>(credit_line.pool_address);

        // Transfer fungible assets from pool to attestator
        // Note: This requires the pool to have a resource account or signer capability
        // For now, we assume the pool address has the necessary permissions
        // In production, you may need to use a resource account signer
        pool::transfer_from_pool<FA>(
            attestator, // Using attestator as proxy; replace with pool signer when available
            attestator_addr,
            amount,
            fa_metadata
        );

        event::emit(
            CreditDrawn {
                attestator: attestator_addr,
                pool_address: credit_line.pool_address,
                amount,
                tenor_seconds: actual_tenor,
                interest_rate_bps: interest_rate,
                prt_address,
                trust_score: trust_score_value,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Draw prefund credit (for trusted attestators with trust score >= 95)
    /// No attestation required upfront - attestator gets USDC immediately
    /// Must attest each repayment later
    public entry fun draw_credit_prefund<FA>(
        attestator: &signer,
        registry_address: address,
        amount: u64,
        tenor_seconds: u64, // Must be one of: 7, 14, 30, 60, 90 days
        governance_address: address,
        fa_metadata: Object<Metadata>
    ) acquires CreditLineRegistry {
        let attestator_addr = signer::address_of(attestator);

        // Get credit line
        let registry = borrow_global_mut<CreditLineRegistry<FA>>(registry_address);
        assert!(
            smart_table::contains(&registry.credit_lines, attestator_addr),
            E_CREDIT_LINE_NOT_FOUND
        );
        let credit_line = smart_table::borrow_mut(&mut registry.credit_lines, attestator_addr);

        // Verify active
        assert!(credit_line.is_active, E_CREDIT_LINE_INACTIVE);

        // STRICT trust score check for prefund (>= 95)
        let trust_score_value =
            trust_score::get_trust_score(attestator_addr, credit_line.pool_address, governance_address);
        assert!(
            trust_score_value >= trust_score::min_trust_score_for_prefund(),
            E_TRUST_SCORE_TOO_LOW
        );

        // Validate tenor is one of the allowed values
        assert!(interest_rate::is_valid_tenor(tenor_seconds), E_NOT_AUTHORIZED);

        // Get interest rate for the selected tenor
        let interest_rate = interest_rate::get_rate_for_tenor(tenor_seconds);

        // Check limit
        let new_outstanding = credit_line.current_outstanding + amount;
        assert!(new_outstanding <= credit_line.max_outstanding, E_INSUFFICIENT_LIMIT);

        // Check pool has liquidity
        let available = pool::available_liquidity<FA>(credit_line.pool_address);
        assert!(amount <= available, E_POOL_INSUFFICIENT_LIQUIDITY);

        // Create PREFUND PRT (pool signer will be created by pool module)
        // Note: In production, this would go through pool module
        // For now, we'll emit event and update state
        let prt_address = @0x0; // Will be actual PRT address in production

        // Update credit line state
        credit_line.current_outstanding = new_outstanding;
        credit_line.last_draw_timestamp = timestamp::now_seconds();
        credit_line.total_draws_count += 1;
        credit_line.total_volume_drawn += amount;

        // Update pool borrowed amount
        pool::update_borrowed<FA>(credit_line.pool_address, amount, true);

        // Increment PRT counter
        pool::increment_prt_counter<FA>(credit_line.pool_address);

        // Mint prefund PRT
        // Note: In production, get actual pool signer instead of using attestator
        let metadata_uri = std::string::utf8(b""); // Empty metadata for now
        let _prt_obj =
            prt::mint_prefund_prt<FA>(
                attestator, // Should be pool signer in production
                attestator_addr,
                amount,
                interest_rate,
                tenor_seconds,
                trust_score_value,
                metadata_uri,
                credit_line.pool_address
            );

        // Transfer fungible assets from pool to attestator
        pool::transfer_from_pool<FA>(
            attestator, // Should be pool signer in production
            attestator_addr,
            amount,
            fa_metadata
        );

        event::emit(
            CreditDrawn {
                attestator: attestator_addr,
                pool_address: credit_line.pool_address,
                amount,
                tenor_seconds,
                interest_rate_bps: interest_rate,
                prt_address,
                trust_score: trust_score_value,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Make a partial repayment on a prefund loan
    /// REQUIRES attestation proving receivable was collected
    public entry fun partial_repayment<FA>(
        attestator: &signer,
        registry_address: address,
        prt: Object<prt::PRT<FA>>,
        attestation: Object<Attestation>, // Proof of receivable collection
        repayment_amount: u64,
        governance_address: address,
        fa_metadata: Object<Metadata>
    ) acquires CreditLineRegistry {
        let attestator_addr = signer::address_of(attestator);

        // Get credit line
        let registry = borrow_global_mut<CreditLineRegistry<FA>>(registry_address);
        assert!(
            smart_table::contains(&registry.credit_lines, attestator_addr),
            E_CREDIT_LINE_NOT_FOUND
        );
        let credit_line = smart_table::borrow_mut(&mut registry.credit_lines, attestator_addr);

        // Verify attestation is valid (not already used)
        assert!(attestator::is_attestation_valid(attestation), E_NOT_AUTHORIZED);

        // Get attestation details
        let (
            attestator_from_attestation,
            _receivable_type,
            amount_attested,
            _is_used,
            attested_prt_addr
        ) = attestator::get_attestation_info(attestation);

        // Verify attestation is for this attestator
        assert!(attestator_from_attestation == attestator_addr, E_NOT_AUTHORIZED);

        // Verify attestation is for this PRT
        let prt_addr = object::object_address(&prt);
        assert!(attested_prt_addr == prt_addr, E_NOT_AUTHORIZED);

        // Verify repayment amount matches attested amount
        assert!(repayment_amount == amount_attested, E_NOT_AUTHORIZED);

        // Mark attestation as used
        attestator::mark_attestation_used(attestation, prt_addr);

        // Process partial repayment via PRT module
        // This calculates time-weighted interest and early discounts
        // Note: This requires getting the pool signer. When implemented:
        // let (principal_paid, interest_paid, early_discount, new_outstanding) =
        //     prt::partial_repay_prt<FA>(pool_signer, prt, repayment_amount);
        // For now, calculate manually to avoid blocking implementation
        let principal_paid = repayment_amount;
        let (_, prt_principal, interest_rate, _maturity, _, prt_status, _) =
            prt::get_prt_info<FA>(prt);

        // Simple interest calculation (will be replaced with actual PRT module call)
        let interest_paid =
            if (prt_status == 0) { // STATUS_OPEN
                ((prt_principal as u128) * (interest_rate as u128) / 10000 as u64)
            } else { 0u64 };
        let _early_discount = 0u64;
        let new_outstanding =
            if (prt_principal > principal_paid) {
                prt_principal - principal_paid
            } else { 0u64 };

        // Update credit line outstanding
        credit_line.current_outstanding -= principal_paid;
        credit_line.total_repayments_count += 1;
        credit_line.total_volume_repaid += principal_paid + interest_paid;

        // Update pool borrowed amount
        pool::update_borrowed<FA>(credit_line.pool_address, principal_paid, false);

        // If fully repaid (outstanding = 0), update trust score based on timing
        if (new_outstanding == 0) {
            // Get PRT maturity to check if on-time
            let (_, original_principal, _, maturity, _, _status, _) =
                prt::get_prt_info<FA>(prt);
            let was_on_time = timestamp::now_seconds() <= maturity;

            let status = if (was_on_time) { 0u8 }
            else { 1u8 }; // STATUS_ON_TIME or STATUS_LATE
            trust_score::update_trust_score(
                attestator_addr,
                credit_line.pool_address,
                original_principal,
                status,
                governance_address
            );
        };

        // Transfer assets from attestator to pool
        let total_payment = principal_paid + interest_paid;
        pool::transfer_to_pool<FA>(
            attestator,
            credit_line.pool_address,
            total_payment,
            fa_metadata
        );

        event::emit(
            CreditRepaid {
                attestator: attestator_addr,
                pool_address: credit_line.pool_address,
                principal: principal_paid,
                interest: interest_paid,
                was_on_time: new_outstanding == 0, // Only matters on final repayment
                prt_address: prt_addr,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Repay credit
    /// Burns PRT, transfers assets back to pool, updates trust score
    public entry fun repay_credit<FA>(
        attestator: &signer,
        registry_address: address,
        prt: Object<prt::PRT<FA>>,
        governance_address: address,
        fa_metadata: Object<Metadata>
    ) acquires CreditLineRegistry {
        let attestator_addr = signer::address_of(attestator);

        // Get credit line
        let registry = borrow_global_mut<CreditLineRegistry<FA>>(registry_address);
        assert!(
            smart_table::contains(&registry.credit_lines, attestator_addr),
            E_CREDIT_LINE_NOT_FOUND
        );
        let credit_line = smart_table::borrow_mut(&mut registry.credit_lines, attestator_addr);

        // Get PRT details
        let (
            prt_attestator,
            principal,
            _interest_rate,
            maturity,
            _trust_score_snapshot,
            _status,
            _
        ) = prt::get_prt_info<FA>(prt);

        // Verify attestator owns this PRT
        assert!(prt_attestator == attestator_addr, E_NOT_AUTHORIZED);

        // Calculate interest
        let interest = prt::calculate_interest<FA>(prt);
        let total_due = principal + interest;

        // Transfer assets from attestator to pool
        pool::transfer_to_pool<FA>(
            attestator,
            credit_line.pool_address,
            total_due,
            fa_metadata
        );

        // Mark PRT as repaid (requires pool signer)
        // let (principal, interest, was_on_time) = prt::repay_prt<FA>(pool_signer, prt);

        // For now, calculate if on time
        let was_on_time = timestamp::now_seconds() <= maturity;

        // Update credit line
        credit_line.current_outstanding -= principal;
        credit_line.total_repayments_count += 1;
        credit_line.total_volume_repaid += total_due;

        // Update pool borrowed amount
        pool::update_borrowed<FA>(credit_line.pool_address, principal, false);

        // Update trust score based on repayment
        let status = if (was_on_time) { 0u8 }
        else { 1u8 }; // STATUS_ON_TIME or STATUS_LATE
        trust_score::update_trust_score(
            attestator_addr,
            credit_line.pool_address,
            principal,
            status,
            governance_address
        );

        event::emit(
            CreditRepaid {
                attestator: attestator_addr,
                pool_address: credit_line.pool_address,
                principal,
                interest,
                was_on_time,
                prt_address: object::object_address(&prt),
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Update credit line limit (admin only)
    public entry fun update_credit_line<FA>(
        admin: &signer,
        registry_address: address,
        attestator_address: address,
        new_max_outstanding: u64,
        governance_address: address
    ) acquires CreditLineRegistry {
        let admin_addr = signer::address_of(admin);

        // Check permission to update parameters
        assert!(
            governance::can_update_parameters(governance_address, admin_addr),
            E_NOT_AUTHORIZED
        );

        // Get credit line
        let registry = borrow_global_mut<CreditLineRegistry<FA>>(registry_address);
        assert!(
            smart_table::contains(&registry.credit_lines, attestator_address),
            E_CREDIT_LINE_NOT_FOUND
        );
        let credit_line = smart_table::borrow_mut(&mut registry.credit_lines, attestator_address);

        let old_max = credit_line.max_outstanding;
        credit_line.max_outstanding = new_max_outstanding;
        credit_line.last_review_timestamp = timestamp::now_seconds();

        event::emit(
            CreditLineUpdated {
                attestator: attestator_address,
                old_max_outstanding: old_max,
                new_max_outstanding,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Deactivate credit line (admin only, or automatic if trust score too low)
    public entry fun deactivate_credit_line<FA>(
        admin: &signer,
        registry_address: address,
        attestator_address: address,
        reason: String,
        governance_address: address
    ) acquires CreditLineRegistry {
        let admin_addr = signer::address_of(admin);

        // Check permission to manage credit lines
        assert!(
            governance::can_create_credit_line(governance_address, admin_addr),
            E_NOT_AUTHORIZED
        );

        // Get credit line
        let registry = borrow_global_mut<CreditLineRegistry<FA>>(registry_address);
        assert!(
            smart_table::contains(&registry.credit_lines, attestator_address),
            E_CREDIT_LINE_NOT_FOUND
        );
        let credit_line = smart_table::borrow_mut(&mut registry.credit_lines, attestator_address);

        credit_line.is_active = false;

        event::emit(
            CreditLineDeactivated {
                attestator: attestator_address,
                reason,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Reactivate credit line (admin only)
    public entry fun reactivate_credit_line<FA>(
        admin: &signer,
        registry_address: address,
        attestator_address: address,
        governance_address: address
    ) acquires CreditLineRegistry {
        let admin_addr = signer::address_of(admin);

        // Check permission to manage credit lines
        assert!(
            governance::can_create_credit_line(governance_address, admin_addr),
            E_NOT_AUTHORIZED
        );

        // Get credit line
        let registry = borrow_global_mut<CreditLineRegistry<FA>>(registry_address);
        assert!(
            smart_table::contains(&registry.credit_lines, attestator_address),
            E_CREDIT_LINE_NOT_FOUND
        );
        let credit_line = smart_table::borrow_mut(&mut registry.credit_lines, attestator_address);

        // Verify trust score is acceptable
        let trust_score_value =
            trust_score::get_trust_score(attestator_address, credit_line.pool_address, governance_address);
        assert!(
            trust_score_value >= trust_score::min_trust_score_to_draw(),
            E_TRUST_SCORE_TOO_LOW
        );

        credit_line.is_active = true;
        credit_line.last_review_timestamp = timestamp::now_seconds();
    }

    /// Get available credit for a attestator
    #[view]
    public fun get_available_credit<FA>(
        registry_address: address, attestator_address: address
    ): u64 acquires CreditLineRegistry {
        let registry = borrow_global<CreditLineRegistry<FA>>(registry_address);

        if (!smart_table::contains(&registry.credit_lines, attestator_address)) {
            return 0
        };

        let credit_line = smart_table::borrow(&registry.credit_lines, attestator_address);

        if (!credit_line.is_active) {
            return 0
        };

        // Available = max - current_outstanding
        credit_line.max_outstanding - credit_line.current_outstanding
    }

    /// Get credit line details
    #[view]
    public fun get_credit_line_info<FA>(
        registry_address: address, attestator_address: address
    ): (u64, u64, bool, u64, u64) acquires CreditLineRegistry {
        let registry = borrow_global<CreditLineRegistry<FA>>(registry_address);
        assert!(
            smart_table::contains(&registry.credit_lines, attestator_address),
            E_CREDIT_LINE_NOT_FOUND
        );
        let credit_line = smart_table::borrow(&registry.credit_lines, attestator_address);

        (
            credit_line.max_outstanding,
            credit_line.current_outstanding,
            credit_line.is_active,
            credit_line.total_draws_count,
            credit_line.total_repayments_count
        )
    }

    /// Get credit line statistics
    #[view]
    public fun get_credit_line_stats<FA>(
        registry_address: address, attestator_address: address
    ): (u64, u64, u64, u64) acquires CreditLineRegistry {
        let registry = borrow_global<CreditLineRegistry<FA>>(registry_address);
        assert!(
            smart_table::contains(&registry.credit_lines, attestator_address),
            E_CREDIT_LINE_NOT_FOUND
        );
        let credit_line = smart_table::borrow(&registry.credit_lines, attestator_address);

        (
            credit_line.total_volume_drawn,
            credit_line.total_volume_repaid,
            credit_line.last_draw_timestamp,
            credit_line.last_review_timestamp
        )
    }

    /// Check if attestator has active credit line
    #[view]
    public fun has_active_credit_line<FA>(
        registry_address: address, attestator_address: address
    ): bool acquires CreditLineRegistry {
        let registry = borrow_global<CreditLineRegistry<FA>>(registry_address);

        if (!smart_table::contains(&registry.credit_lines, attestator_address)) {
            return false
        };

        let credit_line = smart_table::borrow(&registry.credit_lines, attestator_address);
        credit_line.is_active
    }

    /// Get utilization percentage (bps)
    #[view]
    public fun get_utilization_bps<FA>(
        registry_address: address, attestator_address: address
    ): u64 acquires CreditLineRegistry {
        let registry = borrow_global<CreditLineRegistry<FA>>(registry_address);

        if (!smart_table::contains(&registry.credit_lines, attestator_address)) {
            return 0
        };

        let credit_line = smart_table::borrow(&registry.credit_lines, attestator_address);

        if (credit_line.max_outstanding == 0) {
            return 0
        };

        // (current_outstanding * 10000) / max_outstanding
        ((credit_line.current_outstanding as u128) * 10000
            / (credit_line.max_outstanding as u128) as u64)
    }
}
