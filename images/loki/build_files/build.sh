#!/bin/bash

set -ouex pipefail

# Temporarily install Raspberry Pi firmware.
dnf install --setopt=install_weak_deps=False -y \
    bcm2711-firmware \
    uboot-images-armv8
cp -P /usr/share/uboot/rpi_arm64/u-boot.bin /boot/efi/rpi-u-boot.bin
mkdir -p /usr/lib/bootc-raspi-firmwares
cp -a /boot/efi/. /usr/lib/bootc-raspi-firmwares/

# Swap out bootupctl with a shim.
mkdir /usr/bin/bootupctl-orig
mv /usr/bin/bootupctl /usr/bin/bootupctl-orig/
rsync -rvK /ctx/bootupctl-hack/ /

# Remove the temporarily installed firmware.
dnf remove -y \
    bcm2711-firmware \
    uboot-images-armv8

# Cleanup
dnf clean all
rm -rf /var/lib/dnf
