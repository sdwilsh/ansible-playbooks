#!/bin/sh

BIND_GID=101
BIND_UID=101
cd /var/cache/bind || exit 1
cp /zones/* .
mkdir data dynamic
chown -R root:$BIND_GID /var/cache/bind
chown -R $BIND_UID:$BIND_GID dynamic
chown -R $BIND_UID:$BIND_GID data
