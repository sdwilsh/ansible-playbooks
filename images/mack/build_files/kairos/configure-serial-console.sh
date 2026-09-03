#!/bin/bash

set -ouex pipefail

# This hardware has no real ttyS0 UART.  Kairos's grub config sets
# console=ttyS0 on the kernel cmdline.  systemd-getty-generator then
# spawns a getty on ttyS0 at every boot.  The getty fails at once.
# systemd restarts the failed getty again and again.  This step masks
# the unit at the image layer.  A symlink under /usr survives Kairos's
# /etc persistence overlay.  `systemctl mask` and `systemctl disable`
# do not work against a unit from a generator.
ln -sf /dev/null /usr/lib/systemd/system/serial-getty@ttyS0.service
