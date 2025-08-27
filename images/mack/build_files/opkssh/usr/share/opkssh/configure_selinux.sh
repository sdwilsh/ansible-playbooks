#!/usr/bin/env bash

set -ouex pipefail

MODULE_TEMP=/tmp/opkssh.mod
PACKAGE_TEMP=/tmp/opkssh.pp

restorecon /usr/bin/opkssh
checkmodule -M -m -o "${MODULE_TEMP}" /usr/share/opkssh/opkssh.te
semodule_package -o "${PACKAGE_TEMP}" -m "${MODULE_TEMP}"
semodule -i "${PACKAGE_TEMP}"
rm -f "${MODULE_TEMP}" "${PACKAGE_TEMP}"
