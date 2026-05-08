package zta.db_access

import rego.v1

# Database credential request policy — validates that credential requests
# through the GitOps pipeline meet ZTA requirements.
#
# Workshop Section 2 uses this policy to gate Vault credential issuance.

default allow := false

allow if {
	condition_user_authorized
	condition_valid_target
	condition_least_privilege
}

# Requester must be in the app-deployers group
condition_user_authorized if {
	some group in input.user_groups
	group == "app-deployers"
}

# Target database must be a known, registered database
known_databases := {"ztaapp", "inventory", "monitoring"}

condition_valid_target if {
	known_databases[input.target_database]
}

# Requested permissions must not exceed least-privilege scope
allowed_permissions := {"SELECT", "INSERT", "UPDATE"}

condition_least_privilege if {
	every perm in input.requested_permissions {
		allowed_permissions[perm]
	}
}

decision := {
	"allow": allow,
	"user": input.user,
	"target_database": input.target_database,
	"conditions": {
		"user_authorized": condition_user_authorized,
		"valid_target": condition_valid_target,
		"least_privilege": condition_least_privilege,
	},
	"reason": reason,
}

default reason := "all conditions met — credential issuance approved"

reason := msg if {
	not condition_user_authorized
	msg := "DENIED: user is not a member of app-deployers group"
}

reason := msg if {
	condition_user_authorized
	not condition_valid_target
	msg := sprintf("DENIED: database '%s' is not a registered target", [input.target_database])
}

reason := msg if {
	condition_user_authorized
	condition_valid_target
	not condition_least_privilege
	msg := "DENIED: requested permissions exceed least-privilege scope"
}
