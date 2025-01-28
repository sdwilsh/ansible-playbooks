#!/bin/sh

set -e

# renovate: datasource=github-releases depName=hacs/integration
hacs_version="2.0.5"

mkdir -p /config/custom_components
cd /config/custom_components
rm -f hacs.zip

if [ -f hacs/manifest.json ]; then
    current_version=$(grep version < hacs/manifest.json | awk -F '"' '{print $4}')
    if [ "$current_version" = "$hacs_version" ]; then
        echo "HACS already at version $hacs_version; nothing to do!"
        exit 0
    else
        echo "HACS is currently at version $current_version, but should be at $hacs_version..."
    fi
fi

echo "Fetching HACS version $hacs_version..."
wget -O hacs.zip https://github.com/hacs/integration/releases/download/$hacs_version/hacs.zip

echo "Removing existing integration (if present)..."
rm -rf hacs
echo "Existing integration removed!"

echo "Installing HACS $hacs_version..."
unzip hacs.zip -d hacs >/dev/null 2>&1
echo "Unpacked hacs.zip to custom_components/hacs!"

echo "Cleaning up..."
rm -f hacs.zip
echo "Installation complete!"
