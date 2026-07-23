#!/bin/sh

set -e

admin_password=$(require_env_file NUT_ADMIN_PASSWORD_FILE "${NUT_ADMIN_PASSWORD_FILE:-}" "This should point to a file containing the admin user password")
observer_password=$(require_env_file NUT_OBSERVER_PASSWORD_FILE "${NUT_OBSERVER_PASSWORD_FILE:-}" "This should point to a file containing the observer user password")

write_config /etc/nut/local/upsd.users "
[admin]
  actions = set
  actions = fsd
  instcmds = all
  password = \"$(nut_escape "${admin_password}")\"
  upsmon primary

[observer]
  password = \"$(nut_escape "${observer_password}")\"
  upsmon secondary
"
