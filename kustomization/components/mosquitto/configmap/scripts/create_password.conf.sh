#!/bin/sh

cd /mosquitto/data
touch password.conf
chmod o-rwx password.conf
for username in `ls password-conf-data`;
    do mosquitto_passwd -b password.conf $username $(cat password-conf-data/$username);
done