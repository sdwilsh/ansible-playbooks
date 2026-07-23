#!/bin/sh

set -eu

if [ -z "${DUMMY_UPS_FILE:-}" ]; then
    echo "DUMMY_UPS_FILE must be set!"
    exit 1
fi

cat > /etc/nut/ups.conf <<EOF
[testups]
    driver = dummy-ups
    port = ${DUMMY_UPS_FILE}
EOF

cat > /etc/nut/upsd.conf <<EOF
LISTEN 0.0.0.0 3493
EOF

# `upsc` has no authentication mechanism at all (see its man page), so
# `monitor.sh` never presents credentials; no accounts are needed here.
: > /etc/nut/upsd.users

# Alpine's nut package is compiled with --with-user=nut --with-group=nut
# (see:
# https://gitlab.alpinelinux.org/alpine/aports/-/blob/master/community/nut/APKBUILD),
# so `upsdrvctl`/`upsd` drop from root to the "nut" user internally, the
# same way the real production `nut-upsd` container does.  That user has
# no write access to `/var/run/nut` (the compiled statepath) until we
# create and hand it over here; the package itself doesn't do this, since
# it normally relies on an OpenRC init script or `tmpfiles.d` entry we're
# bypassing by invoking the binaries directly.
mkdir -p /var/run/nut
chown nut:nut /var/run/nut

upsdrvctl start
exec upsd -F
