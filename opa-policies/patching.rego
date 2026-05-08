package zta.patching

import rego.v1

# Server patching policy — enforces THREE conditions before allowing a patch job.
#
# Condition 1: User must be a member of the "patch-admins" group in IdM
# Condition 2: Target server must be registered in CMDB with status "Active"
# Condition 3: A maintenance window must be approved (maintenance_approved = true)
#
# Workshop Section 3 uses this policy:
#   Part 1 — One condition fails, job is denied
#   Part 2 — All conditions met, patching succeeds

default allow := false

allow if {
	condition_user_authorized
	condition_server_active
	condition_maintenance_approved
}

# Condition 1: User is in the patch-admins group
condition_user_authorized if {
	some group in input.user_groups
	group == "patch-admins"
}

# Condition 2: Target server is registered and active in the CMDB
condition_server_active if {
	input.target_server_status == "Active"
}

# Condition 3: Maintenance window has been approved
condition_maintenance_approved if {
	input.maintenance_approved == true
}

# Detailed decision response for AAP to display
decision := {
	"allow": allow,
	"user": input.user,
	"target": input.target_server,
	"conditions": {
		"user_authorized": condition_user_authorized,
		"server_active": condition_server_active,
		"maintenance_approved": condition_maintenance_approved,
	},
	"reason": reason,
}

default reason := "all conditions met"

reason := msg if {
	not condition_user_authorized
	msg := "DENIED: user is not a member of patch-admins group"
}

reason := msg if {
	condition_user_authorized
	not condition_server_active
	msg := "DENIED: target server is not Active in CMDB"
}

reason := msg if {
	condition_user_authorized
	condition_server_active
	not condition_maintenance_approved
	msg := "DENIED: maintenance window has not been approved"
}
