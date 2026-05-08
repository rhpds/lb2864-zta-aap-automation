package zta.data_classification

import rego.v1

# Data classification policy — controls access to databases based on their
# sensitivity tag and the user's clearance level (group membership).
#
# BUG 1: PII rule uses OR instead of AND — any user in security-ops OR
#         db-admins can access PII data. Should require BOTH groups.
#
# BUG 2: Confidential rule checks for "app-deployers" instead of "db-admins"
#         — allows app developers to access confidential data they shouldn't see.
#
# BUG 3: No classification check on the "internal" rule — it allows access
#         to ANY classification level if the user is in app-deployers.

default allow := false

# Public data — any authenticated user
allow if {
	input.data_classification == "public"
	input.user != ""
}

# Internal data — BUG 3: missing classification check
# Should check input.data_classification == "internal" but doesn't
allow if {
	user_in_group("app-deployers")
}

allow if {
	input.data_classification == "internal"
	user_in_group("db-admins")
}

# Confidential data — BUG 2: wrong group (app-deployers instead of db-admins)
allow if {
	input.data_classification == "confidential"
	user_in_group("app-deployers")
}

# PII data — BUG 1: uses OR instead of AND (two separate rules)
allow if {
	input.data_classification == "pii"
	user_in_group("security-ops")
}

allow if {
	input.data_classification == "pii"
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
