#!/bin/sh

set -e

admin_password=$(require_env_file NUT_ADMIN_PASSWORD_FILE "${NUT_ADMIN_PASSWORD_FILE:-}" "This should point to a file containing the admin user password")
ups_name=$(require_env NUT_UPS_NAME "${NUT_UPS_NAME:-}" "This is used as the ups.conf section name.")
pod_ip=$(require_env POD_IP "${POD_IP:-}" "")

# There is no `SHUTDOWNCMD` here on purpose.  This `upsmon` only monitors
# this `Pod`'s own local `upsd`; if FSD ever triggered a real shutdown here,
# it would kill the UPS telemetry source right when every shutdown-agent
# polling `upsc` depends on it most.  An unset `SHUTDOWNCMD` just logs a
# startup warning and is a no-op at FSD time (`upsmon` calls
# `system(NULL)`, which per POSIX does nothing); it does not crash or
# otherwise misbehave.
write_config /etc/nut/local/upsmon.conf "
MONITOR ${ups_name}@${pod_ip} 1 admin \"$(nut_escape "${admin_password}")\" primary
"
