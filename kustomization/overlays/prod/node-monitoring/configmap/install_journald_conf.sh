#!/bin/sh

set -e

config_dest=/host/usr/local/lib/systemd/journald.conf.d/90-marinatedconcrete-monitoring.conf
echo "Creating ${config_dest}..."
echo "
# This file is generated in an initContainer for Grafana Alloy which ingests
# logs, and any modifications will be dropped at the next restart!

[Journal]
# Alloy in node-monitoring namespace will read from journalctl.
ForwardToSyslog=no

# Alloy should be ingesting this, but keep a bit extra just in case!
MaxRetentionSec=3day
" > $config_dest

echo "Successfully installed journald configutation at ${config_dest}.  This will be applied at next restart..."
