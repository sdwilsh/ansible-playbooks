#!/bin/bash

set -ouex pipefail

rsync -rvK /ctx/node-exporter/ /
