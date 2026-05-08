package zta.data_classification

import rego.v1

# Data classification policy — controls access to databases based on their
# sensitivity tag and the user's clearance level (group membership).
#
# This is the CORRECT version of the policy. The "buggy" version deployed
# by break-opa-policy.yml has deliberate logic errors for the workshop exercise.
#
# Classification levels:
#   public       — any authenticated user
#   internal     — app-deployers or db-admins
#   confidential — db-admins only
#   pii          — security-ops AND db-admins (dual-group requirement)

default allow := false

# Public data — any authenticated user
allow if {
	input.data_classification == "public"
	input.user != ""
}

# Internal data — app-deployers or db-admins
allow if {
	input.data_classification == "internal"
	user_in_group("app-deployers")
}

allow if {
	input.data_classification == "internal"
	user_in_group("db-admins")
}

# Confidential data — db-admins only
allow if {
	input.data_classification == "confidential"
	user_in_group("db-admins")
}

# PII data — requires BOTH security-ops AND db-admins membership
allow if {
	input.data_classification == "pii"
	user_in_group("security-ops")
	user_in_group("db-admins")
}

user_in_group(group) if {
	some g in input.user_groups
	g == group
}

decision := {
	"allow": allow,
	"user": input.user,
	"data_classification": input.data_classification,
	"reason": reason,
}

default reason := "access granted — user meets classification requirements"

reason := "DENIED: no matching access rule for this classification level" if {
	not allow
}
