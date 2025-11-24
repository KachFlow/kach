module kach::tranche {
    use aptos_framework::event;
    use aptos_framework::timestamp;
    use kach::pool;

    /// Identifier used when referring to the senior tranche.
    const TRANCHE_SENIOR: u8 = 0;
    /// Identifier used when referring to the junior tranche.
    const TRANCHE_JUNIOR: u8 = 1;

    /// Error when a caller lacks the privileges to execute tranche operations.
    const E_NOT_AUTHORIZED: u64 = 1;
    /// Error when an invalid tranche identifier is supplied.
    const E_INVALID_TRANCHE: u64 = 2;
    /// Error when a tranche does not have enough capital to fulfill an action.
    const E_INSUFFICIENT_FUNDS: u64 = 3;

    /// Maximum share of capital that the junior tranche can lose (basis points).
    const JUNIOR_MAX_LOSS_BPS: u64 = 8000;
    /// Maximum share of capital that the senior tranche can lose (basis points).
    const SENIOR_MAX_LOSS_BPS: u64 = 2000;

    /// Capital weighting multiplier for senior tranche (scaled by 10)
    /// Documentation specifies 0.8x weight for senior
    const SENIOR_CAPITAL_WEIGHT: u64 = 8; // 0.8 * 10

    /// Capital weighting multiplier for junior tranche (scaled by 10)
    /// Documentation specifies 1.3x weight for junior
    const JUNIOR_CAPITAL_WEIGHT: u64 = 13; // 1.3 * 10

    /// Protocol fee percentage (7% of gross interest per documentation)
    const PROTOCOL_FEE_BPS: u64 = 700; // 7%

    /// Events
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

    /// Distribute yield from interest to tranches
    /// Called after PRT repayment
    /// Uses capital-weighted distribution per documentation:
    /// - Senior weight: 0.8x
    /// - Junior weight: 1.3x
    /// - Protocol fee: 7% of gross interest
    public fun distribute_yield<FA>(
        pool_address: address, total_interest: u64
    ) {
        // Calculate protocol reserve share (7% per documentation)
        let protocol_share = (total_interest as u128) * (PROTOCOL_FEE_BPS as u128) / 10000;
        let protocol_share_u64 = (protocol_share as u64);

        // Add to protocol reserve
        pool::add_to_reserve<FA>(pool_address, protocol_share_u64);

        // Remaining yield for tranches after protocol fee
        let tranche_yield = total_interest - protocol_share_u64;

        // Get actual tranche deposits
        let senior_deposits = pool::get_tranche_deposits<FA>(pool_address, TRANCHE_SENIOR);
        let junior_deposits = pool::get_tranche_deposits<FA>(pool_address, TRANCHE_JUNIOR);

        // Calculate capital-weighted shares per documentation
        // Senior weight = senior_deposits × 0.8
        // Junior weight = junior_deposits × 1.3
        // Each tranche receives: (interest_after_fee) × (tranche_weight / total_weight)

        let senior_weight = (senior_deposits as u128) * (SENIOR_CAPITAL_WEIGHT as u128); // × 8 (scaled)
        let junior_weight = (junior_deposits as u128) * (JUNIOR_CAPITAL_WEIGHT as u128); // × 13 (scaled)
        let total_weight = senior_weight + junior_weight;

        // Distribute yield proportionally by capital weight
        let senior_share = if (total_weight > 0) {
            ((tranche_yield as u128) * senior_weight / total_weight as u64)
        } else {
            0u64
        };

        let junior_share = if (total_weight > 0) {
            ((tranche_yield as u128) * junior_weight / total_weight as u64)
        } else {
            0u64
        };

        // Update NAV multipliers for each tranche
        update_nav_for_yield<FA>(
            pool_address,
            TRANCHE_SENIOR,
            senior_share
        );

        update_nav_for_yield<FA>(
            pool_address,
            TRANCHE_JUNIOR,
            junior_share
        );

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
    /// Per documentation (tranches.mdx):
    /// 1. Protocol Reserve absorbs first
    /// 2. Junior tranche (up to 80% of junior capital)
    /// 3. Senior tranche (up to 20% of senior capital, if needed)
    public fun allocate_loss<FA>(pool_address: address, total_loss: u64) {
        let remaining_loss = total_loss;

        // Step 0: Protocol reserve absorbs first
        let (_, _, protocol_reserve_balance, _, _, _) =
            pool::get_pool_stats<FA>(pool_address);

        let protocol_absorbed =
            if (protocol_reserve_balance >= remaining_loss) {
                remaining_loss
            } else {
                protocol_reserve_balance
            };

        remaining_loss -= protocol_absorbed;

        // Deduct from protocol reserve
        if (protocol_absorbed > 0) {
            pool::deduct_from_reserve<FA>(pool_address, protocol_absorbed);
        };

        let junior_absorbed = 0u64;
        let senior_absorbed = 0u64;

        if (remaining_loss > 0) {
            // Step 1: Junior tranche absorbs (up to 80% of junior deposits)
            (remaining_loss, junior_absorbed) = absorb_loss_in_tranche<FA>(
                pool_address,
                TRANCHE_JUNIOR,
                remaining_loss,
                JUNIOR_MAX_LOSS_BPS
            );
        };

        if (remaining_loss > 0) {
            // Step 2: Senior tranche absorbs (up to 20% of senior deposits)
            (_, senior_absorbed) = absorb_loss_in_tranche<FA>(
                pool_address,
                TRANCHE_SENIOR,
                remaining_loss,
                SENIOR_MAX_LOSS_BPS
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
        pool_address: address,
        tranche: u8,
        loss_amount: u64,
        max_loss_bps: u64
    ): (u64, u64) {
        // Get tranche deposits from pool
        let tranche_deposits = pool::get_tranche_deposits<FA>(pool_address, tranche);

        // Max loss this tranche can absorb
        let max_absorbable = (tranche_deposits as u128) * (max_loss_bps as u128) / 10000;
        let max_absorbable_u64 = (max_absorbable as u64);

        let absorbed =
            if (loss_amount <= max_absorbable_u64) {
                loss_amount
            } else {
                max_absorbable_u64
            };

        let remaining = loss_amount - absorbed;

        // Update NAV multiplier (decrease for loss)
        update_nav_for_loss<FA>(pool_address, tranche, absorbed);

        (remaining, absorbed)
    }

    /// Update NAV multiplier when yield is distributed
    fun update_nav_for_yield<FA>(
        pool_address: address, tranche: u8, yield_amount: u64
    ) {
        let old_multiplier = pool::get_nav_multiplier<FA>(pool_address, tranche);

        // Get tranche deposits from pool module
        let tranche_deposits = pool::get_tranche_deposits<FA>(pool_address, tranche);

        if (tranche_deposits == 0) { return };

        // New multiplier = old_multiplier * (1 + yield/deposits)
        // NAV multipliers are scaled by 1e18
        let yield_ratio =
            (yield_amount as u128) * 1_000_000_000_000_000_000
                / (tranche_deposits as u128);
        let new_multiplier = old_multiplier + yield_ratio;

        pool::update_nav_multiplier<FA>(pool_address, tranche, new_multiplier);

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
    ) {
        let old_multiplier = pool::get_nav_multiplier<FA>(pool_address, tranche);

        // Get tranche deposits from pool module
        let tranche_deposits = pool::get_tranche_deposits<FA>(pool_address, tranche);

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

        pool::update_nav_multiplier<FA>(pool_address, tranche, new_multiplier);

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

    /// Get capital weight multiplier for a tranche (scaled by 10)
    /// Senior: 0.8x (returns 8)
    /// Junior: 1.3x (returns 13)
    #[view]
    public fun get_capital_weight(tranche: u8): u64 {
        if (tranche == TRANCHE_SENIOR) {
            SENIOR_CAPITAL_WEIGHT
        } else {
            JUNIOR_CAPITAL_WEIGHT
        }
    }

    /// Get max loss a tranche can absorb (in bps of tranche capital)
    #[view]
    public fun get_max_loss_bps(tranche: u8): u64 {
        if (tranche == TRANCHE_JUNIOR) {
            JUNIOR_MAX_LOSS_BPS
        } else {
            SENIOR_MAX_LOSS_BPS
        }
    }

    /// Get protocol fee in basis points (7%)
    #[view]
    public fun get_protocol_fee_bps(): u64 {
        PROTOCOL_FEE_BPS
    }
}

