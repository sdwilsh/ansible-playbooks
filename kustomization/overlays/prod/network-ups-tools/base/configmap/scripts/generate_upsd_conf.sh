#!/bin/sh

set -e

pod_ip=$(require_env POD_IP "${POD_IP:-}" "")

write_config /etc/nut/local/upsd.conf "
LISTEN ${pod_ip} 3493
"
