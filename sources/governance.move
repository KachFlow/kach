module kach::governance {
    use std::signer;
    use std::vector;
    use aptos_framework::event;
    use aptos_framework::timestamp;

    /// Error when the caller lacks the required governance privilege.
    const E_NOT_AUTHORIZED: u64 = 1;
    /// Error when attempting to add an admin who already has the role.
    const E_ALREADY_ADMIN: u64 = 2;
    /// Error when referencing an admin record that doesn't exist.
    const E_NOT_ADMIN: u64 = 3;
    /// Error when attempting to add an operator who already has the role.
    const E_ALREADY_OPERATOR: u64 = 4;
    /// Error when referencing an operator record that doesn't exist.
    const E_NOT_OPERATOR: u64 = 5;
    /// Error when supplied protocol parameters fall outside acceptable bounds.
    const E_INVALID_PARAMETER: u64 = 6;
    /// Error when trying to initialize governance more than once.
    const E_GOVERNANCE_EXISTS: u64 = 7;
    /// Error when trying to mutate governance before initialization.
    const E_GOVERNANCE_NOT_FOUND: u64 = 8;

    /// Role identifier for administrators.
    const ROLE_ADMIN: u8 = 0;
    /// Role identifier for routine operators.
    const ROLE_OPERATOR: u8 = 1;
    /// Role identifier for emergency responders.
    const ROLE_EMERGENCY: u8 = 2;

    /// Global governance configuration
    /// Stored at protocol deployer address
    struct GovernanceConfig has key {
        // Multi-admin support
        admins: vector<address>,

        // Operators (can execute routine operations but not change critical params)
        operators: vector<address>,

        // Emergency responders (can pause but not unpause)
        emergency_responders: vector<address>,

        // Protocol parameters
        protocol_fee_bps: u64,           // Default protocol fee (e.g., 500 = 5%)
        max_utilization_bps: u64,        // Default max utilization (e.g., 8000 = 80%)
        min_lock_duration_seconds: u64,  // Minimum position lock time
        max_lock_duration_seconds: u64,  // Maximum position lock time

        // Credit engine parameters
        min_trust_score_threshold: u64,  // Minimum trust score to draw credit
        default_tenor_seconds: u64,      // Default loan tenor

        // Yield distribution parameters
        base_risk_premium_bps: u64,      // Base risk premium for dynamic yield calculation (e.g., 3000 = 30% = 0.3)

        // Emergency controls
        global_pause: bool,

        // Timestamps
        created_at: u64,
        last_updated: u64,
    }

    /// Events
    #[event]
    struct GovernanceInitialized has drop, store {
        admin: address,
        timestamp: u64,
    }

    #[event]
    struct AdminAdded has drop, store {
        admin: address,
        added_by: address,
        timestamp: u64,
    }

    #[event]
    struct AdminRemoved has drop, store {
        admin: address,
        removed_by: address,
        timestamp: u64,
    }

    #[event]
    struct OperatorAdded has drop, store {
        operator: address,
        added_by: address,
        timestamp: u64,
    }

    #[event]
    struct OperatorRemoved has drop, store {
        operator: address,
        removed_by: address,
        timestamp: u64,
    }

    #[event]
    struct EmergencyResponderAdded has drop, store {
        responder: address,
        added_by: address,
        timestamp: u64,
    }

    #[event]
    struct EmergencyResponderRemoved has drop, store {
        responder: address,
        removed_by: address,
        timestamp: u64,
    }

    #[event]
    struct ParameterUpdated has drop, store {
        parameter_name: vector<u8>,
        old_value: u64,
        new_value: u64,
        updated_by: address,
        timestamp: u64,
    }

    #[event]
    struct GlobalPauseToggled has drop, store {
        is_paused: bool,
        toggled_by: address,
        timestamp: u64,
    }

    /// Initialize governance (called once at deployment)
    public entry fun initialize_governance(
        deployer: &signer,
        protocol_fee_bps: u64,
        max_utilization_bps: u64,
        min_lock_duration_seconds: u64,
        max_lock_duration_seconds: u64,
        min_trust_score_threshold: u64,
        default_tenor_seconds: u64,
        base_risk_premium_bps: u64,
    ) {
        let deployer_addr = signer::address_of(deployer);

        assert!(!exists<GovernanceConfig>(deployer_addr), E_GOVERNANCE_EXISTS);

        // Validate parameters
        assert!(protocol_fee_bps <= 10000, E_INVALID_PARAMETER);
        assert!(max_utilization_bps <= 10000, E_INVALID_PARAMETER);
        assert!(min_lock_duration_seconds > 0, E_INVALID_PARAMETER);
        assert!(max_lock_duration_seconds >= min_lock_duration_seconds, E_INVALID_PARAMETER);
        assert!(min_trust_score_threshold <= 100, E_INVALID_PARAMETER);
        assert!(default_tenor_seconds > 0, E_INVALID_PARAMETER);
        assert!(base_risk_premium_bps <= 10000, E_INVALID_PARAMETER); // Max 100%

        let admins = vector::empty<address>();
        vector::push_back(&mut admins, deployer_addr);

        let config = GovernanceConfig {
            admins,
            operators: vector::empty<address>(),
            emergency_responders: vector::empty<address>(),
            protocol_fee_bps,
            max_utilization_bps,
            min_lock_duration_seconds,
            max_lock_duration_seconds,
            min_trust_score_threshold,
            default_tenor_seconds,
            base_risk_premium_bps,
            global_pause: false,
            created_at: timestamp::now_seconds(),
            last_updated: timestamp::now_seconds(),
        };

        move_to(deployer, config);

        event::emit(GovernanceInitialized {
            admin: deployer_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Add a new admin (requires existing admin)
    public entry fun add_admin(
        admin: &signer,
        new_admin: address,
        governance_addr: address,
    ) acquires GovernanceConfig {
        let admin_addr = signer::address_of(admin);

        assert!(exists<GovernanceConfig>(governance_addr), E_GOVERNANCE_NOT_FOUND);
        let config = borrow_global_mut<GovernanceConfig>(governance_addr);

        // Verify caller is admin
        assert!(is_admin_internal(&config.admins, admin_addr), E_NOT_AUTHORIZED);

        // Verify new_admin is not already admin
        assert!(!is_admin_internal(&config.admins, new_admin), E_ALREADY_ADMIN);

        vector::push_back(&mut config.admins, new_admin);
        config.last_updated = timestamp::now_seconds();

        event::emit(AdminAdded {
            admin: new_admin,
            added_by: admin_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Remove an admin (requires existing admin, cannot remove last admin)
    public entry fun remove_admin(
        admin: &signer,
        admin_to_remove: address,
        governance_addr: address,
    ) acquires GovernanceConfig {
        let admin_addr = signer::address_of(admin);

        assert!(exists<GovernanceConfig>(governance_addr), E_GOVERNANCE_NOT_FOUND);
        let config = borrow_global_mut<GovernanceConfig>(governance_addr);

        // Verify caller is admin
        assert!(is_admin_internal(&config.admins, admin_addr), E_NOT_AUTHORIZED);

        // Verify not removing last admin
        assert!(vector::length(&config.admins) > 1, E_NOT_AUTHORIZED);

        // Find and remove admin
        let (found, index) = vector::index_of(&config.admins, &admin_to_remove);
        assert!(found, E_NOT_ADMIN);

        vector::remove(&mut config.admins, index);
        config.last_updated = timestamp::now_seconds();

        event::emit(AdminRemoved {
            admin: admin_to_remove,
            removed_by: admin_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Add operator
    public entry fun add_operator(
        admin: &signer,
        new_operator: address,
        governance_addr: address,
    ) acquires GovernanceConfig {
        let admin_addr = signer::address_of(admin);

        assert!(exists<GovernanceConfig>(governance_addr), E_GOVERNANCE_NOT_FOUND);
        let config = borrow_global_mut<GovernanceConfig>(governance_addr);

        assert!(is_admin_internal(&config.admins, admin_addr), E_NOT_AUTHORIZED);
        assert!(!is_operator_internal(&config.operators, new_operator), E_ALREADY_OPERATOR);

        vector::push_back(&mut config.operators, new_operator);
        config.last_updated = timestamp::now_seconds();

        event::emit(OperatorAdded {
            operator: new_operator,
            added_by: admin_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Remove operator
    public entry fun remove_operator(
        admin: &signer,
        operator_to_remove: address,
        governance_addr: address,
    ) acquires GovernanceConfig {
        let admin_addr = signer::address_of(admin);

        assert!(exists<GovernanceConfig>(governance_addr), E_GOVERNANCE_NOT_FOUND);
        let config = borrow_global_mut<GovernanceConfig>(governance_addr);

        assert!(is_admin_internal(&config.admins, admin_addr), E_NOT_AUTHORIZED);

        let (found, index) = vector::index_of(&config.operators, &operator_to_remove);
        assert!(found, E_NOT_OPERATOR);

        vector::remove(&mut config.operators, index);
        config.last_updated = timestamp::now_seconds();

        event::emit(OperatorRemoved {
            operator: operator_to_remove,
            removed_by: admin_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Add emergency responder
    public entry fun add_emergency_responder(
        admin: &signer,
        new_responder: address,
        governance_addr: address,
    ) acquires GovernanceConfig {
        let admin_addr = signer::address_of(admin);

        assert!(exists<GovernanceConfig>(governance_addr), E_GOVERNANCE_NOT_FOUND);
        let config = borrow_global_mut<GovernanceConfig>(governance_addr);

        assert!(is_admin_internal(&config.admins, admin_addr), E_NOT_AUTHORIZED);

        vector::push_back(&mut config.emergency_responders, new_responder);
        config.last_updated = timestamp::now_seconds();

        event::emit(EmergencyResponderAdded {
            responder: new_responder,
            added_by: admin_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Remove emergency responder
    public entry fun remove_emergency_responder(
        admin: &signer,
        responder_to_remove: address,
        governance_addr: address,
    ) acquires GovernanceConfig {
        let admin_addr = signer::address_of(admin);

        assert!(exists<GovernanceConfig>(governance_addr), E_GOVERNANCE_NOT_FOUND);
        let config = borrow_global_mut<GovernanceConfig>(governance_addr);

        assert!(is_admin_internal(&config.admins, admin_addr), E_NOT_AUTHORIZED);

        let (found, index) = vector::index_of(&config.emergency_responders, &responder_to_remove);
        assert!(found, E_NOT_AUTHORIZED);

        vector::remove(&mut config.emergency_responders, index);
        config.last_updated = timestamp::now_seconds();

        event::emit(EmergencyResponderRemoved {
            responder: responder_to_remove,
            removed_by: admin_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Update protocol fee (admin only)
    public entry fun update_protocol_fee_bps(
        admin: &signer,
        new_fee_bps: u64,
        governance_addr: address,
    ) acquires GovernanceConfig {
        let admin_addr = signer::address_of(admin);

        assert!(exists<GovernanceConfig>(governance_addr), E_GOVERNANCE_NOT_FOUND);
        let config = borrow_global_mut<GovernanceConfig>(governance_addr);

        assert!(is_admin_internal(&config.admins, admin_addr), E_NOT_AUTHORIZED);
        assert!(new_fee_bps <= 10000, E_INVALID_PARAMETER);

        let old_value = config.protocol_fee_bps;
        config.protocol_fee_bps = new_fee_bps;
        config.last_updated = timestamp::now_seconds();

        event::emit(ParameterUpdated {
            parameter_name: b"protocol_fee_bps",
            old_value,
            new_value: new_fee_bps,
            updated_by: admin_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Update max utilization (admin only)
    public entry fun update_max_utilization_bps(
        admin: &signer,
        new_max_bps: u64,
        governance_addr: address,
    ) acquires GovernanceConfig {
        let admin_addr = signer::address_of(admin);

        assert!(exists<GovernanceConfig>(governance_addr), E_GOVERNANCE_NOT_FOUND);
        let config = borrow_global_mut<GovernanceConfig>(governance_addr);

        assert!(is_admin_internal(&config.admins, admin_addr), E_NOT_AUTHORIZED);
        assert!(new_max_bps <= 10000, E_INVALID_PARAMETER);

        let old_value = config.max_utilization_bps;
        config.max_utilization_bps = new_max_bps;
        config.last_updated = timestamp::now_seconds();

        event::emit(ParameterUpdated {
            parameter_name: b"max_utilization_bps",
            old_value,
            new_value: new_max_bps,
            updated_by: admin_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Update minimum trust score threshold (admin only)
    public entry fun update_min_trust_score(
        admin: &signer,
        new_threshold: u64,
        governance_addr: address,
    ) acquires GovernanceConfig {
        let admin_addr = signer::address_of(admin);

        assert!(exists<GovernanceConfig>(governance_addr), E_GOVERNANCE_NOT_FOUND);
        let config = borrow_global_mut<GovernanceConfig>(governance_addr);

        assert!(is_admin_internal(&config.admins, admin_addr), E_NOT_AUTHORIZED);
        assert!(new_threshold <= 100, E_INVALID_PARAMETER);

        let old_value = config.min_trust_score_threshold;
        config.min_trust_score_threshold = new_threshold;
        config.last_updated = timestamp::now_seconds();

        event::emit(ParameterUpdated {
            parameter_name: b"min_trust_score_threshold",
            old_value,
            new_value: new_threshold,
            updated_by: admin_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Update base risk premium (admin only)
    public entry fun update_base_risk_premium(
        admin: &signer,
        new_premium_bps: u64,
        governance_addr: address,
    ) acquires GovernanceConfig {
        let admin_addr = signer::address_of(admin);

        assert!(exists<GovernanceConfig>(governance_addr), E_GOVERNANCE_NOT_FOUND);
        let config = borrow_global_mut<GovernanceConfig>(governance_addr);

        assert!(is_admin_internal(&config.admins, admin_addr), E_NOT_AUTHORIZED);
        assert!(new_premium_bps <= 10000, E_INVALID_PARAMETER); // Max 100%

        let old_value = config.base_risk_premium_bps;
        config.base_risk_premium_bps = new_premium_bps;
        config.last_updated = timestamp::now_seconds();

        event::emit(ParameterUpdated {
            parameter_name: b"base_risk_premium_bps",
            old_value,
            new_value: new_premium_bps,
            updated_by: admin_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Toggle global pause (admin or emergency responder)
    public entry fun toggle_global_pause(
        caller: &signer,
        governance_addr: address,
    ) acquires GovernanceConfig {
        let caller_addr = signer::address_of(caller);

        assert!(exists<GovernanceConfig>(governance_addr), E_GOVERNANCE_NOT_FOUND);
        let config = borrow_global_mut<GovernanceConfig>(governance_addr);

        // For pausing: admin or emergency responder
        // For unpausing: only admin
        if (config.global_pause) {
            // Unpausing requires admin
            assert!(is_admin_internal(&config.admins, caller_addr), E_NOT_AUTHORIZED);
        } else {
            // Pausing can be done by admin or emergency responder
            assert!(
                is_admin_internal(&config.admins, caller_addr) ||
                is_emergency_responder_internal(&config.emergency_responders, caller_addr),
                E_NOT_AUTHORIZED
            );
        };

        config.global_pause = !config.global_pause;
        config.last_updated = timestamp::now_seconds();

        event::emit(GlobalPauseToggled {
            is_paused: config.global_pause,
            toggled_by: caller_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Internal helper to check if address is admin
    fun is_admin_internal(admins: &vector<address>, addr: address): bool {
        vector::contains(admins, &addr)
    }

    /// Internal helper to check if address is operator
    fun is_operator_internal(operators: &vector<address>, addr: address): bool {
        vector::contains(operators, &addr)
    }

    /// Internal helper to check if address is emergency responder
    fun is_emergency_responder_internal(responders: &vector<address>, addr: address): bool {
        vector::contains(responders, &addr)
    }

    /// Public view functions

    #[view]
    public fun is_admin(governance_addr: address, addr: address): bool acquires GovernanceConfig {
        if (!exists<GovernanceConfig>(governance_addr)) {
            return false
        };
        let config = borrow_global<GovernanceConfig>(governance_addr);
        is_admin_internal(&config.admins, addr)
    }

    #[view]
    public fun is_operator(governance_addr: address, addr: address): bool acquires GovernanceConfig {
        if (!exists<GovernanceConfig>(governance_addr)) {
            return false
        };
        let config = borrow_global<GovernanceConfig>(governance_addr);
        is_operator_internal(&config.operators, addr)
    }

    #[view]
    public fun is_emergency_responder(governance_addr: address, addr: address): bool acquires GovernanceConfig {
        if (!exists<GovernanceConfig>(governance_addr)) {
            return false
        };
        let config = borrow_global<GovernanceConfig>(governance_addr);
        is_emergency_responder_internal(&config.emergency_responders, addr)
    }

    #[view]
    public fun is_globally_paused(governance_addr: address): bool acquires GovernanceConfig {
        if (!exists<GovernanceConfig>(governance_addr)) {
            return false
        };
        let config = borrow_global<GovernanceConfig>(governance_addr);
        config.global_pause
    }

    #[view]
    public fun get_protocol_fee_bps(governance_addr: address): u64 acquires GovernanceConfig {
        assert!(exists<GovernanceConfig>(governance_addr), E_GOVERNANCE_NOT_FOUND);
        let config = borrow_global<GovernanceConfig>(governance_addr);
        config.protocol_fee_bps
    }

    #[view]
    public fun get_max_utilization_bps(governance_addr: address): u64 acquires GovernanceConfig {
        assert!(exists<GovernanceConfig>(governance_addr), E_GOVERNANCE_NOT_FOUND);
        let config = borrow_global<GovernanceConfig>(governance_addr);
        config.max_utilization_bps
    }

    #[view]
    public fun get_min_trust_score_threshold(governance_addr: address): u64 acquires GovernanceConfig {
        assert!(exists<GovernanceConfig>(governance_addr), E_GOVERNANCE_NOT_FOUND);
        let config = borrow_global<GovernanceConfig>(governance_addr);
        config.min_trust_score_threshold
    }

    #[view]
    public fun get_lock_duration_bounds(governance_addr: address): (u64, u64) acquires GovernanceConfig {
        assert!(exists<GovernanceConfig>(governance_addr), E_GOVERNANCE_NOT_FOUND);
        let config = borrow_global<GovernanceConfig>(governance_addr);
        (config.min_lock_duration_seconds, config.max_lock_duration_seconds)
    }

    #[view]
    public fun get_default_tenor_seconds(governance_addr: address): u64 acquires GovernanceConfig {
        assert!(exists<GovernanceConfig>(governance_addr), E_GOVERNANCE_NOT_FOUND);
        let config = borrow_global<GovernanceConfig>(governance_addr);
        config.default_tenor_seconds
    }

    #[view]
    public fun get_base_risk_premium_bps(governance_addr: address): u64 acquires GovernanceConfig {
        assert!(exists<GovernanceConfig>(governance_addr), E_GOVERNANCE_NOT_FOUND);
        let config = borrow_global<GovernanceConfig>(governance_addr);
        config.base_risk_premium_bps
    }

    #[view]
    public fun get_all_admins(governance_addr: address): vector<address> acquires GovernanceConfig {
        assert!(exists<GovernanceConfig>(governance_addr), E_GOVERNANCE_NOT_FOUND);
        let config = borrow_global<GovernanceConfig>(governance_addr);
        config.admins
    }

    #[view]
    public fun get_all_operators(governance_addr: address): vector<address> acquires GovernanceConfig {
        assert!(exists<GovernanceConfig>(governance_addr), E_GOVERNANCE_NOT_FOUND);
        let config = borrow_global<GovernanceConfig>(governance_addr);
        config.operators
    }

    #[view]
    public fun get_all_emergency_responders(governance_addr: address): vector<address> acquires GovernanceConfig {
        assert!(exists<GovernanceConfig>(governance_addr), E_GOVERNANCE_NOT_FOUND);
        let config = borrow_global<GovernanceConfig>(governance_addr);
        config.emergency_responders
    }
}
