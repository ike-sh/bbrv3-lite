#!/usr/bin/env bash
# BBRv3 Lite - measured TCP tuning for Debian/Ubuntu
# This file is assembled from src/*.sh by scripts/build.sh.
# shellcheck shell=bash

SCRIPT_VERSION="7.0.2"
SCRIPT_NAME="bbrv3-lite"
PROJECT_REPO="ike-sh/bbrv3-lite"
PROJECT_URL="https://github.com/${PROJECT_REPO}"
STATE_SCHEMA="1"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -Eeuo pipefail
fi
