package zta.network

import rego.v1

# Network VLAN management policy — enforces group-based authorization
# and SPIFFE workload identity verification.
#
# Workshop Section 4 uses this policy:
#   1. The automation workload must present a valid SPIFFE ID.
#   2. The user must be in network-admins.
#   3. The VLAN ID must be in the permitted range.
#   4. The action must be allowed.

default allow := false

allow if {
	condition_user_authorized
	condition_valid_vlan
	condition_action_permitted
	condition_workload_verified
}

# ── User identity (from IdM / Keycloak) ─────────────────────────────

default condition_user_authorized := false

condition_user_authorized if {
	some group in input.user_groups
	group == "network-admins"
}

# ── VLAN validation ─────────────────────────────────────────────────

default condition_valid_vlan := false

condition_valid_vlan if {
	input.vlan_id >= 100
	input.vlan_id <= 999
}

# ── Action allowlist ────────────────────────────────────────────────

permitted_actions := {"create_vlan", "modify_vlan", "delete_vlan", "assign_port"}

default condition_action_permitted := false

condition_action_permitted if {
	permitted_actions[input.action]
}

# ── SPIFFE workload identity ────────────────────────────────────────
# Only trusted automation workloads may request network changes.

allowed_spiffe_ids := {
	"spiffe://zta.lab/workload/network-automation",
}

default condition_workload_verified := false

condition_workload_verified if {
	allowed_spiffe_ids[input.spiffe_id]
}

# ── Decision object ─────────────────────────────────────────────────

decision := {
	"allow": allow,
	"user": input.user,
	"action": input.action,
	"vlan_id": input.vlan_id,
	"spiffe_id": object.get(input, "spiffe_id", "none"),
	"conditions": {
		"user_authorized": condition_user_authorized,
		"valid_vlan": condition_valid_vlan,
		"action_permitted": condition_action_permitted,
		"workload_verified": condition_workload_verified,
	},
	"reason": reason,
}

# ── Denial reasons (evaluated in priority order) ────────────────────

default reason := "all conditions met"

reason := msg if {
	not condition_workload_verified
	msg := sprintf("DENIED: workload SPIFFE ID '%s' is not in the trusted set", [object.get(input, "spiffe_id", "none")])
}

reason := msg if {
	condition_workload_verified
	not condition_user_authorized
	msg := sprintf("DENIED: user '%s' is not a member of network-admins group", [input.user])
}

reason := msg if {
	condition_workload_verified
	condition_user_authorized
	not condition_valid_vlan
	msg := sprintf("DENIED: VLAN ID %d is outside the permitted range (100-999)", [input.vlan_id])
}

reason := msg if {
	condition_workload_verified
	condition_user_authorized
	condition_valid_vlan
	not condition_action_permitted
	msg := sprintf("DENIED: action '%s' is not permitted", [input.action])
}
