package aap.gateway

import rego.v1

# AAP 2.6 Platform Policy — evaluated by the controller BEFORE a job launches.
#
# This is the OUTER defence ring:
#   "Is this user's team allowed to launch this class of job template?"
#
# AAP 2.6 sends the full job context as input (see Configuring automation
# execution, Chapter 7.4).  Key fields:
#   input.name                          — job template name
#   input.created_by.username           — who launched the job
#   input.created_by.is_superuser       — platform superuser flag
#   input.created_by.teams[].name       — AAP team memberships (via LDAP)
#   input.playbook                      — playbook path
#   input.extra_vars                    — survey / extra variables
#   input.launched_by                   — launcher metadata
#
# Output contract: {"allowed": bool, "violations": [strings]}
#
# Enforcement point: Organisation → policy_enforcement = "aap/gateway/decision"

# ── Default: allow unless a deny rule fires ───────────────────────

default decision := {"allowed": true, "violations": []}

# ── Team-to-template mapping ─────────────────────────────────────
#
#  | Template pattern        | Required AAP team          |
#  |-------------------------|----------------------------|
#  | Patch                   | Infrastructure or Security |
#  | VLAN, Network           | Infrastructure             |
#  | Deploy, Credential,     | Applications or DevOps     |
#  |   Application           |                            |
#  | Everything else         | Any authenticated user     |

patching_teams := {"Infrastructure", "Security"}
network_teams := {"Infrastructure"}
app_teams := {"Applications", "DevOps"}

# ── Extract team names from input ─────────────────────────────────

user_teams := {name | name := input.created_by.teams[_].name}

team_match(required) if {
	some team in user_teams
	team in required
}

# ── Template name classification ──────────────────────────────────

template_name := lower(input.name)

is_patching_template if contains(template_name, "patch")

is_network_template if contains(template_name, "vlan")
is_network_template if contains(template_name, "network")

is_app_template if contains(template_name, "deploy")
is_app_template if contains(template_name, "credential")
is_app_template if contains(template_name, "application")

# ── Deny: patching without authorised team ────────────────────────

decision := {
	"allowed": false,
	"violations": [sprintf(
		"user '%s' is not in an authorised team for patching templates (requires: %v, has: %v)",
		[input.created_by.username, patching_teams, user_teams],
	)],
} if {
	not input.created_by.is_superuser
	is_patching_template
	not team_match(patching_teams)
}

# ── Deny: network without authorised team ─────────────────────────

decision := {
	"allowed": false,
	"violations": [sprintf(
		"user '%s' is not in an authorised team for network templates (requires: %v, has: %v)",
		[input.created_by.username, network_teams, user_teams],
	)],
} if {
	not input.created_by.is_superuser
	is_network_template
	not is_patching_template
	not team_match(network_teams)
}

# ── Deny: application without authorised team ─────────────────────

decision := {
	"allowed": false,
	"violations": [sprintf(
		"user '%s' is not in an authorised team for application templates (requires: %v, has: %v)",
		[input.created_by.username, app_teams, user_teams],
	)],
} if {
	not input.created_by.is_superuser
	is_app_template
	not is_patching_template
	not is_network_template
	not team_match(app_teams)
}
