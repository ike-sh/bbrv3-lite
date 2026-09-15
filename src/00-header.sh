#!/usr/bin/env bash
# BBRv3 Lite - measured TCP tuning for Debian/Ubuntu
# This file is assembled from src/*.sh by scripts/build.sh.
# shellcheck shell=bash

SCRIPT_VERSION="8.0.7"
SCRIPT_NAME="bbrv3-lite"
PROJECT_REPO="ike-sh/bbrv3-lite"
PROJECT_URL="https://github.com/${PROJECT_REPO}"
STATE_SCHEMA="1"

# Authoritative non-generic process return-code registry.  Keep this block
# unique: callers use these values to distinguish retry/failover decisions from
# hard safety failures.  Generic validation and I/O failures continue to use 1;
# an evidence-only inconclusive measurement continues to use 2.
IPERF_DATA_RC=65                 # malformed/incomplete iperf protocol data (fatal)
IPERF_CONTAMINATED_RC=66         # locally contaminated sample (peer failover allowed)
IPERF_UNSTABLE_RC=67             # unstable repeated samples (peer failover allowed)
MEASURE_PATH_QUALITY_RC=68       # dirty PATH_CONTROL (peer failover allowed)
MEASURE_ROUTE_MISMATCH_RC=69     # frozen route/path changed (peer failover allowed)
MEASURE_BUDGET_RC=70             # top-level operation traffic/time budget exhausted
MEASUREMENT_PREFLIGHT_RC=71      # local environment rejected high-volume measurement
DIAGNOSTIC_EXPORT_RC=72          # diagnostic bundle could not be produced safely
ROLLBACK_FAILURE_RC=73           # restoration failed; highest-priority user failure
IPERF_UNAVAILABLE_RC=75          # endpoint busy/reset/timeout/unavailable; retryable

operation_rc_class() {
    case "$1" in
        0) printf 'success\n' ;;
        2|"$IPERF_CONTAMINATED_RC"|"$IPERF_UNSTABLE_RC"|"$MEASURE_PATH_QUALITY_RC"|\
        "$MEASURE_ROUTE_MISMATCH_RC"|"$IPERF_UNAVAILABLE_RC") printf 'peer-failover\n' ;;
        "$MEASURE_BUDGET_RC") printf 'budget\n' ;;
        "$MEASUREMENT_PREFLIGHT_RC") printf 'preflight\n' ;;
        "$ROLLBACK_FAILURE_RC") printf 'rollback\n' ;;
        *) printf 'fatal\n' ;;
    esac
}

operation_rc_is_retryable() {
    [[ "$1" == "$IPERF_UNAVAILABLE_RC" ]]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -Eeuo pipefail
fi
