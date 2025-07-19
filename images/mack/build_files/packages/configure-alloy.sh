#!/bin/bash

set -ouex pipefail

rsync -rvK /ctx/alloy/ /
chown 473:473 /etc/alloy/journal.alloy
