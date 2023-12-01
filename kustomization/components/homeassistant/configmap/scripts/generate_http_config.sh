#!/bin/sh

if [ -z "${HTTP_TRUSTED_PROXIES}" ]; then
    echo "HTTP_TRUSTED_PROXIES must be set!  See https://www.home-assistant.io/integrations/http/#trusted_proxies"
    exit 1
fi


http_dest=/config/http.yaml
echo "Creating ${http_dest}..."
rm -f $http_dest
echo "---
# This file is generated in an initContainer, and any modifications will be
# dropped at the next restart!

use_x_forwarded_for: true
trusted_proxies: ${HTTP_TRUSTED_PROXIES}
" > $http_dest

echo "Successfully setup configuration at ${http_dest}"

echo "http: !include http.yaml" >> $config_dest
echo "Successfully added http configuration to ${config_dest}"
