#!/bin/sh

cd /mosquitto/data || exit 1
touch password.conf
chmod o-rwx password.conf
for username_path in password-conf-data/* ; do
    username="$(echo "$username_path" | awk -F / -e '{print $2}')"
    password="$(cat password-conf-data/"$username")"
    mosquitto_passwd -b password.conf "$username" "$password"
done
