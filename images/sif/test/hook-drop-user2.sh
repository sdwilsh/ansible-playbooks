#!/bin/sh
# Run the generator, then remove the `user2` bundle from the tree that it
# wrote.  The end-to-end test runs this script as `S6_STAGE2_HOOK`.
set -eu

/usr/local/bin/generate-model-services.sh
rm -rf "$(printcontenv S6_RUNTIME_BUNDLEDIR)/user2"
