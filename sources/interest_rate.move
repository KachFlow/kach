module kach::interest_rate {
    use aptos_framework::timestamp;

    /// Tenor option representing 7 days, expressed in seconds.
    const TENOR_7_DAYS: u64 = 604800;
    /// Tenor option representing 14 days, expressed in seconds.
    const TENOR_14_DAYS: u64 = 1209600;
    /// Tenor option representing 30 days, expressed in seconds.
    const TENOR_30_DAYS: u64 = 2592000;
    /// Tenor option representing 60 days, expressed in seconds.
    const TENOR_60_DAYS: u64 = 5184000;
    /// Tenor option representing 90 days, expressed in seconds.
    const TENOR_90_DAYS: u64 = 7776000;

    /// Base interest rate for the 7-day tenor, measured in basis points.
    const RATE_7_DAYS_BPS: u64 = 35;
    /// Base interest rate for the 14-day tenor, measured in basis points.
    const RATE_14_DAYS_BPS: u64 = 60;
    /// Base interest rate for the 30-day tenor, measured in basis points.
    const RATE_30_DAYS_BPS: u64 = 120;
    /// Base interest rate for the 60-day tenor, measured in basis points.
    const RATE_60_DAYS_BPS: u64 = 220;
    /// Base interest rate for the 90-day tenor, measured in basis points.
    const RATE_90_DAYS_BPS: u64 = 320;

    /// Additional interest discount awarded on any saved interest for early repayment.
    const EARLY_REPAYMENT_DISCOUNT_BPS: u64 = 200;

    /// Error raised when a caller supplies a tenor outside the supported list.
    const E_INVALID_TENOR: u64 = 1;

    /// Get interest rate for a given tenor
    public fun get_rate_for_tenor(tenor_seconds: u64): u64 {
        if (tenor_seconds == TENOR_7_DAYS) {
            RATE_7_DAYS_BPS
        } else if (tenor_seconds == TENOR_14_DAYS) {
            RATE_14_DAYS_BPS
        } else if (tenor_seconds == TENOR_30_DAYS) {
            RATE_30_DAYS_BPS
        } else if (tenor_seconds == TENOR_60_DAYS) {
            RATE_60_DAYS_BPS
        } else if (tenor_seconds == TENOR_90_DAYS) {
            RATE_90_DAYS_BPS
        } else {
            abort E_INVALID_TENOR
        }
    }

    /// Validate that tenor is one of the allowed values
    public fun is_valid_tenor(tenor_seconds: u64): bool {
        tenor_seconds == TENOR_7_DAYS
            || tenor_seconds == TENOR_14_DAYS
            || tenor_seconds == TENOR_30_DAYS
            || tenor_seconds == TENOR_60_DAYS
            || tenor_seconds == TENOR_90_DAYS
    }

    /// Calculate time-weighted interest for prefund loans
    ///
    /// Formula:
    /// 1. Calculate total interest if held to maturity: principal × rate_bps / 10000
    /// 2. For each time period, calculate: outstanding_balance × (days_elapsed / total_days) × total_interest
    /// 3. Apply early repayment discount if applicable
    ///
    /// Example:
    /// - Principal: 10,000 USDC, Tenor: 30 days, Rate: 120 bps
    /// - Total interest at maturity: 10,000 × 120 / 10000 = 120 USDC
    /// - Day 0-10: Outstanding = 10,000 USDC → Interest = 10,000 × (10/30) × 120 = 40 USDC
    /// - Repay 5,000 USDC on day 10
    /// - Day 10-20: Outstanding = 5,000 USDC → Interest = 5,000 × (10/30) × 120 = 20 USDC
    /// - Repay 5,000 USDC on day 20 (early by 10 days)
    /// - Early discount: Saved 10 days on 5,000 USDC = (5,000 × (10/30) × 120) × (1 + 0.02) = 17 USDC saved
    /// - Total interest: 40 + 20 - discount on early portion
    ///
    /// This function calculates interest owed for a specific time period
    public fun calculate_time_weighted_interest(
        outstanding_principal: u64,
        rate_bps: u64,
        days_elapsed: u64,
        total_tenor_days: u64
    ): u64 {
        // Interest = outstanding × rate × (days_elapsed / total_days)
        let daily_rate = (rate_bps as u128) * (days_elapsed as u128)
            / (total_tenor_days as u128);
        let interest = (outstanding_principal as u128) * daily_rate / 10000;
        (interest as u64)
    }

    /// Calculate early repayment discount
    /// When borrower repays early, they save interest on remaining days
    /// Plus a bonus discount as incentive
    public fun calculate_early_repayment_discount(
        repayment_amount: u64,
        rate_bps: u64,
        days_remaining: u64,
        total_tenor_days: u64
    ): u64 {
        // Calculate interest that would have accrued on this amount for remaining days
        let saved_interest =
            calculate_time_weighted_interest(
                repayment_amount,
                rate_bps,
                days_remaining,
                total_tenor_days
            );

        // Apply discount bonus: saved_interest * (1 + discount_bps / 10000)
        let discount_multiplier = 10000 + EARLY_REPAYMENT_DISCOUNT_BPS;
        let total_discount = (saved_interest as u128) * (discount_multiplier as u128)
            / 10000;
        (total_discount as u64)
    }

    /// Calculate accrued interest for a repayment event
    /// Returns (interest_owed, early_discount)
    public fun calculate_repayment_interest(
        outstanding_principal: u64,
        repayment_amount: u64,
        rate_bps: u64,
        creation_timestamp: u64,
        last_repayment_timestamp: u64,
        maturity_timestamp: u64
    ): (u64, u64) {
        let current_time = timestamp::now_seconds();

        // Calculate days since last repayment (or creation if first repayment)
        let seconds_elapsed = current_time - last_repayment_timestamp;
        let days_elapsed = seconds_elapsed / 86400; // Convert to days

        // Calculate total tenor in days
        let total_tenor_seconds = maturity_timestamp - creation_timestamp;
        let total_tenor_days = total_tenor_seconds / 86400;

        // Calculate interest for the elapsed period on outstanding principal
        let interest_owed =
            calculate_time_weighted_interest(
                outstanding_principal,
                rate_bps,
                days_elapsed,
                total_tenor_days
            );

        // Calculate early repayment discount if repaying before maturity
        let early_discount =
            if (current_time < maturity_timestamp) {
                let seconds_remaining = maturity_timestamp - current_time;
                let days_remaining = seconds_remaining / 86400;

                calculate_early_repayment_discount(
                    repayment_amount,
                    rate_bps,
                    days_remaining,
                    total_tenor_days
                )
            } else { 0 };

        (interest_owed, early_discount)
    }

    /// Calculate total interest owed on a prefund loan at maturity
    /// This is the maximum interest if no early repayments are made
    public fun calculate_max_interest(principal: u64, rate_bps: u64): u64 {
        ((principal as u128) * (rate_bps as u128) / 10000 as u64)
    }

    /// View functions for supported tenors and rates

    #[view]
    public fun get_supported_tenors(): vector<u64> {
        vector[
            TENOR_7_DAYS,
            TENOR_14_DAYS,
            TENOR_30_DAYS,
            TENOR_60_DAYS,
            TENOR_90_DAYS
        ]
    }

    #[view]
    public fun get_all_rates(): vector<u64> {
        vector[
            RATE_7_DAYS_BPS,
            RATE_14_DAYS_BPS,
            RATE_30_DAYS_BPS,
            RATE_60_DAYS_BPS,
            RATE_90_DAYS_BPS
        ]
    }

    #[view]
    public fun get_tenor_days(tenor_seconds: u64): u64 {
        tenor_seconds / 86400
    }

    #[view]
    public fun get_early_discount_bps(): u64 {
        EARLY_REPAYMENT_DISCOUNT_BPS
    }

    /// Helper to get human-readable tenor options
    #[view]
    public fun get_tenor_7_days(): u64 {
        TENOR_7_DAYS
    }

    #[view]
    public fun get_tenor_14_days(): u64 {
        TENOR_14_DAYS
    }

    #[view]
    public fun get_tenor_30_days(): u64 {
        TENOR_30_DAYS
    }

    #[view]
    public fun get_tenor_60_days(): u64 {
        TENOR_60_DAYS
    }

    #[view]
    public fun get_tenor_90_days(): u64 {
        TENOR_90_DAYS
    }
}
