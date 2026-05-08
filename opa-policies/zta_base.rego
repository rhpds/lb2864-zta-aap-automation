package zta.base

import rego.v1

# Base ZTA helper rules used across all policies

default authenticated := false

authenticated if {
	input.user != ""
	count(input.groups) > 0
}

user_in_group(group) if {
	some g in input.groups
	g == group
}

# Time-of-day helpers (UTC)
current_hour := time.clock(time.now_ns())[0]

within_business_hours if {
	current_hour >= 8
	current_hour < 18
}

within_maintenance_window if {
	current_hour >= 22
}

within_maintenance_window if {
	current_hour < 6
}
