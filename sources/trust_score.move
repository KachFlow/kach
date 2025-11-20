module kach::trust_score {
    use std::signer;
    use aptos_framework::event;
    use aptos_framework::timestamp;

    /// Error when a signer without admin rights attempts to mutate trust scores.
    const E_NOT_AUTHORIZED: u64 = 1;
    /// Error when initializing a score for a borrower that already has one.
    const E_TRUST_SCORE_EXISTS: u64 = 2;
    /// Error when attempting to access a non-existent trust score record.
    const E_TRUST_SCORE_NOT_FOUND: u64 = 3;

    /// Starting score given to every borrower upon initialization.
    const INITIAL_TRUST_SCORE: u64 = 70;
    /// Minimum possible trust score.
    const MIN_TRUST_SCORE: u64 = 0;
    /// Maximum possible trust score.
    const MAX_TRUST_SCORE: u64 = 100;
    /// Score threshold below which credit draws are frozen.
    const CUTOFF_SCORE: u64 = 60;

    /// Score increment applied for each on-time repayment.
    const ON_TIME_INCREMENT: u64 = 1;
    /// Score decrement applied for each late repayment.
    const LATE_DECREMENT: u64 = 5;
    /// Score decrement applied whenever a repayment defaults.
    const DEFAULT_DECREMENT: u64 = 20;

    /// Trust Score for a borrower
    /// Starts at 70, moves up/down based on behavior
    struct TrustScore has key {
        borrower_address: address,
        current_score: u64,

        // Payment history
        total_payments: u64,
        on_time_payments: u64,
        late_payments: u64,
        defaulted_payments: u64,

        // Review tracking
        last_review_timestamp: u64,
        last_score_change_timestamp: u64,

        // Timestamps
        created_at: u64
    }

    /// Global registry
    struct TrustScoreRegistry has key {
        admin_address: address,
        total_scores: u64
    }

    /// Events
    #[event]
    struct TrustScoreInitialized has drop, store {
        borrower: address,
        initial_score: u64,
        timestamp: u64
    }

    #[event]
    struct TrustScoreUpdated has drop, store {
        borrower: address,
        old_score: u64,
        new_score: u64,
        reason: vector<u8>, // "on_time", "late", "default", "manual"
        timestamp: u64
    }

    #[event]
    struct TrustScoreFrozen has drop, store {
        borrower: address,
        score: u64,
        timestamp: u64
    }

    /// Initialize trust score registry
    public entry fun initialize_registry(admin: &signer) {
        let admin_addr = signer::address_of(admin);

        let registry = TrustScoreRegistry { admin_address: admin_addr, total_scores: 0 };

        move_to(admin, registry);
    }

    /// Initialize trust score for a new borrower (admin only)
    public fun initialize_trust_score(
        admin: &signer, borrower_address: address
    ) acquires TrustScoreRegistry {
        let admin_addr = signer::address_of(admin);

        // Verify admin
        let registry = borrow_global_mut<TrustScoreRegistry>(admin_addr);
        assert!(admin_addr == registry.admin_address, E_NOT_AUTHORIZED);

        // Verify doesn't exist
        assert!(!exists<TrustScore>(borrower_address), E_TRUST_SCORE_EXISTS);

        let trust_score = TrustScore {
            borrower_address,
            current_score: INITIAL_TRUST_SCORE,
            total_payments: 0,
            on_time_payments: 0,
            late_payments: 0,
            defaulted_payments: 0,
            last_review_timestamp: timestamp::now_seconds(),
            last_score_change_timestamp: timestamp::now_seconds(),
            created_at: timestamp::now_seconds()
        };

        move_to(admin, trust_score);

        registry.total_scores += 1;

        event::emit(
            TrustScoreInitialized {
                borrower: borrower_address,
                initial_score: INITIAL_TRUST_SCORE,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Increment on-time payment count and potentially increase score
    public fun increment_on_time_payments(borrower_address: address) acquires TrustScore {
        assert!(exists<TrustScore>(borrower_address), E_TRUST_SCORE_NOT_FOUND);
        let trust_score = borrow_global_mut<TrustScore>(borrower_address);

        let old_score = trust_score.current_score;

        trust_score.total_payments += 1;
        trust_score.on_time_payments += 1;

        // Increase score (capped at MAX_TRUST_SCORE)
        let new_score =
            if (trust_score.current_score + ON_TIME_INCREMENT > MAX_TRUST_SCORE) {
                MAX_TRUST_SCORE
            } else {
                trust_score.current_score + ON_TIME_INCREMENT
            };

        trust_score.current_score = new_score;
        trust_score.last_score_change_timestamp = timestamp::now_seconds();

        if (old_score != new_score) {
            event::emit(
                TrustScoreUpdated {
                    borrower: borrower_address,
                    old_score,
                    new_score,
                    reason: b"on_time",
                    timestamp: timestamp::now_seconds()
                }
            );
        }
    }

    /// Increment late payment count and decrease score
    public fun increment_late_payments(borrower_address: address) acquires TrustScore {
        assert!(exists<TrustScore>(borrower_address), E_TRUST_SCORE_NOT_FOUND);
        let trust_score = borrow_global_mut<TrustScore>(borrower_address);

        let old_score = trust_score.current_score;

        trust_score.total_payments += 1;
        trust_score.late_payments += 1;

        // Decrease score (floored at MIN_TRUST_SCORE)
        let new_score =
            if (trust_score.current_score < LATE_DECREMENT) {
                MIN_TRUST_SCORE
            } else {
                trust_score.current_score - LATE_DECREMENT
            };

        trust_score.current_score = new_score;
        trust_score.last_score_change_timestamp = timestamp::now_seconds();

        event::emit(
            TrustScoreUpdated {
                borrower: borrower_address,
                old_score,
                new_score,
                reason: b"late",
                timestamp: timestamp::now_seconds()
            }
        );

        // Check if score dropped below cutoff
        if (new_score < CUTOFF_SCORE) {
            event::emit(
                TrustScoreFrozen {
                    borrower: borrower_address,
                    score: new_score,
                    timestamp: timestamp::now_seconds()
                }
            );
        }
    }

    /// Increment default count and severely decrease score
    public fun increment_defaulted_payments(borrower_address: address) acquires TrustScore {
        assert!(exists<TrustScore>(borrower_address), E_TRUST_SCORE_NOT_FOUND);
        let trust_score = borrow_global_mut<TrustScore>(borrower_address);

        let old_score = trust_score.current_score;

        trust_score.total_payments += 1;
        trust_score.defaulted_payments += 1;

        // Severe decrease for default
        let new_score =
            if (trust_score.current_score < DEFAULT_DECREMENT) {
                MIN_TRUST_SCORE
            } else {
                trust_score.current_score - DEFAULT_DECREMENT
            };

        trust_score.current_score = new_score;
        trust_score.last_score_change_timestamp = timestamp::now_seconds();

        event::emit(
            TrustScoreUpdated {
                borrower: borrower_address,
                old_score,
                new_score,
                reason: b"default",
                timestamp: timestamp::now_seconds()
            }
        );

        event::emit(
            TrustScoreFrozen {
                borrower: borrower_address,
                score: new_score,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Manually adjust trust score (admin only)
    public entry fun manual_adjust_score(
        admin: &signer, borrower_address: address, new_score: u64
    ) acquires TrustScore, TrustScoreRegistry {
        let admin_addr = signer::address_of(admin);

        // Verify admin
        let registry = borrow_global<TrustScoreRegistry>(admin_addr);
        assert!(admin_addr == registry.admin_address, E_NOT_AUTHORIZED);

        assert!(exists<TrustScore>(borrower_address), E_TRUST_SCORE_NOT_FOUND);
        let trust_score = borrow_global_mut<TrustScore>(borrower_address);

        let old_score = trust_score.current_score;

        // Ensure new score is within bounds
        assert!(
            new_score >= MIN_TRUST_SCORE && new_score <= MAX_TRUST_SCORE,
            99
        );

        trust_score.current_score = new_score;
        trust_score.last_review_timestamp = timestamp::now_seconds();
        trust_score.last_score_change_timestamp = timestamp::now_seconds();

        event::emit(
            TrustScoreUpdated {
                borrower: borrower_address,
                old_score,
                new_score,
                reason: b"manual",
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Get current trust score
    #[view]
    public fun get_trust_score(borrower_address: address): u64 acquires TrustScore {
        if (!exists<TrustScore>(borrower_address)) {
            return 0
        };

        let trust_score = borrow_global<TrustScore>(borrower_address);
        trust_score.current_score
    }

    /// Check if trust score is above cutoff (eligible for credit)
    #[view]
    public fun is_eligible_for_credit(borrower_address: address): bool acquires TrustScore {
        if (!exists<TrustScore>(borrower_address)) {
            return false
        };

        let trust_score = borrow_global<TrustScore>(borrower_address);
        trust_score.current_score >= CUTOFF_SCORE
    }

    /// Get payment statistics
    #[view]
    public fun get_payment_stats(borrower_address: address): (u64, u64, u64, u64) acquires TrustScore {
        assert!(exists<TrustScore>(borrower_address), E_TRUST_SCORE_NOT_FOUND);
        let trust_score = borrow_global<TrustScore>(borrower_address);

        (
            trust_score.total_payments,
            trust_score.on_time_payments,
            trust_score.late_payments,
            trust_score.defaulted_payments
        )
    }

    /// Calculate on-time payment rate (in basis points)
    #[view]
    public fun get_on_time_rate_bps(borrower_address: address): u64 acquires TrustScore {
        if (!exists<TrustScore>(borrower_address)) {
            return 0
        };

        let trust_score = borrow_global<TrustScore>(borrower_address);

        if (trust_score.total_payments == 0) {
            return 10000 // 100% if no history
        };

        // (on_time_payments * 10000) / total_payments
        ((trust_score.on_time_payments as u128) * 10000
            / (trust_score.total_payments as u128) as u64)
    }

    /// Get full trust score details
    #[view]
    public fun get_trust_score_details(
        borrower_address: address
    ): (u64, u64, u64, u64, u64, u64) acquires TrustScore {
        assert!(exists<TrustScore>(borrower_address), E_TRUST_SCORE_NOT_FOUND);
        let trust_score = borrow_global<TrustScore>(borrower_address);

        (
            trust_score.current_score,
            trust_score.total_payments,
            trust_score.on_time_payments,
            trust_score.late_payments,
            trust_score.defaulted_payments,
            trust_score.created_at
        )
    }
}

