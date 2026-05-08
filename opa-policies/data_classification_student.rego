package zta.data_classification

import rego.v1

# Student Exercise: Write a data classification policy
#
# This policy controls access to databases based on their sensitivity level
# and the user's group membership in IdM.
#
# Classification levels (from least to most sensitive):
#   public       — any authenticated user
#   internal     — app-deployers or db-admins
#   confidential — db-admins only
#   pii          — security-ops AND db-admins (dual-group requirement)
#
# Input fields available:
#   input.user                — username (string)
#   input.user_groups         — list of IdM groups (array of strings)
#   input.data_classification — one of: "public", "internal", "confidential", "pii"
#
# Test your policy with curl:
#   # Public — should allow any user
#   curl -s -X POST http://central.zta.lab:8181/v1/data/zta/data_classification/decision \
#     -d '{"input":{"user":"appdev","user_groups":["app-deployers"],"data_classification":"public"}}' \
#     | python3 -m json.tool
#
#   # PII — should DENY security-ops alone (needs BOTH groups)
#   curl -s -X POST http://central.zta.lab:8181/v1/data/zta/data_classification/decision \
#     -d '{"input":{"user":"spatel","user_groups":["security-ops"],"data_classification":"pii"}}' \
#     | python3 -m json.tool
#
#   # PII — should ALLOW user with BOTH security-ops AND db-admins
#   curl -s -X POST http://central.zta.lab:8181/v1/data/zta/data_classification/decision \
#     -d '{"input":{"user":"nobrien","user_groups":["db-admins","security-ops"],"data_classification":"pii"}}' \
#     | python3 -m json.tool

default allow := false

# ── Helper function (provided) ─────────────────────────────────────
# Returns true if the user is a member of the given group.

user_in_group(group) if {
	some g in input.user_groups
	g == group
}

# ── YOUR RULES START HERE ──────────────────────────────────────────

# RULE 1: Public data — any authenticated user (non-empty username)
#
# allow if {
# 	input.data_classification == "public"
# 	FILL_IN — check that user is not empty
# }

# RULE 2: Internal data — app-deployers OR db-admins
# (You need TWO separate allow rules — one per group)
#
# allow if {
# 	input.data_classification == "internal"
# 	FILL_IN — use user_in_group()
# }
#
# allow if {
# 	input.data_classification == "internal"
# 	FILL_IN
# }

# RULE 3: Confidential data — db-admins ONLY
#
# allow if {
# 	FILL_IN
# }

# RULE 4: PII data — requires BOTH security-ops AND db-admins
# IMPORTANT: Both conditions must be in the SAME rule body (AND logic).
# Putting them in separate rules would create OR logic — a common bug!
#
# allow if {
# 	input.data_classification == "pii"
# 	FILL_IN — check BOTH groups in one rule
# }

# ── Decision object (provided) ─────────────────────────────────────

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
