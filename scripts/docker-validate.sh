#!/usr/bin/env bash
# Full disposable-container validation for every release candidate.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_IMAGES=(debian:12 debian:13 ubuntu:22.04 ubuntu:24.04)

command -v docker >/dev/null 2>&1 || {
    echo "docker is required for the release validation matrix" >&2
    exit 1
}
docker info >/dev/null 2>&1 || {
    echo "docker daemon is not available" >&2
    exit 1
}

if [[ -n "${BBRV3_DOCKER_IMAGES:-}" ]]; then
    # shellcheck disable=SC2206
    IMAGES=(${BBRV3_DOCKER_IMAGES})
else
    IMAGES=("${DEFAULT_IMAGES[@]}")
fi

for image in "${IMAGES[@]}"; do
    printf '==> Docker validation: %s\n' "$image"
    docker run --rm --privileged \
        -e DEBIAN_FRONTEND=noninteractive \
        -v "$ROOT_DIR:/src:ro" \
        "$image" \
        bash -lc '
            set -Eeuo pipefail
            apt-get update -qq
            apt-get install -y -qq \
                bash ca-certificates coreutils curl findutils gawk grep iperf3 \
                iproute2 iputils-ping jq kmod openssl procps shellcheck util-linux >/dev/null
            mkdir -p /work
            cp -a /src/. /work/
            cd /work
            export BBRV3_NETWORK_INTEGRATION=1
            export BBRV3_IPV6_REAL_INTEGRATION=1
            SKIP_RELEASE_CHECKSUM=1 bash scripts/validate.sh
            if ! cmp -s /src/net-tcp-tune.sh /work/net-tcp-tune.sh; then
                echo "tracked net-tcp-tune.sh is stale; run scripts/build.sh before Docker validation" >&2
                diff -u /src/net-tcp-tune.sh /work/net-tcp-tune.sh >&2 || true
                exit 1
            fi
            for test_file in tests/integration_*.sh; do
                [[ -f "$test_file" ]] || continue
                case "$test_file" in
                    tests/integration_dns_systemd.sh|tests/integration_systemd_unit_state.sh) continue ;;
                esac
                printf "==> %s\n" "$test_file"
                bash "$test_file"
            done
        '
done

run_systemd_resolved=0
for image in "${IMAGES[@]}"; do
    if [[ "$image" == debian:12 ]]; then
        run_systemd_resolved=1
        break
    fi
done

if (( run_systemd_resolved )); then
    printf '==> Docker validation: Debian 12 with systemd-resolved as a real service\n'
    systemd_container=""
    cleanup_systemd_container() {
        if [[ -n "$systemd_container" ]]; then
            docker rm -f "$systemd_container" >/dev/null 2>&1 || true
        fi
    }
    trap cleanup_systemd_container EXIT

    systemd_container=$(docker run --rm -d --privileged --cgroupns=host \
        --tmpfs /run --tmpfs /run/lock \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        -v "$ROOT_DIR:/src:ro" \
        -e DEBIAN_FRONTEND=noninteractive \
        debian:12 \
        bash -lc '
            set -Eeuo pipefail
            apt-get update -qq
            apt-get install -y -qq \
                bash coreutils dbus iproute2 procps systemd systemd-resolved systemd-sysv >/dev/null
            exec /sbin/init
        ')

    systemd_ready=0
    for _ in $(seq 1 120); do
        if docker exec "$systemd_container" systemctl show-environment >/dev/null 2>&1; then
            systemd_ready=1
            break
        fi
        if [[ $(docker inspect -f '{{.State.Running}}' "$systemd_container" 2>/dev/null || true) != true ]]; then
            docker logs "$systemd_container" >&2 || true
            echo "nested systemd container exited before it became ready" >&2
            exit 1
        fi
        sleep 1
    done
    if (( systemd_ready == 0 )); then
        docker logs "$systemd_container" >&2 || true
        echo "nested systemd container did not become ready within 120 seconds" >&2
        exit 1
    fi

    docker exec "$systemd_container" bash /src/tests/integration_dns_systemd.sh
    docker exec "$systemd_container" bash /src/tests/integration_systemd_unit_state.sh
    docker rm -f "$systemd_container" >/dev/null
    systemd_container=""
    trap - EXIT
fi

echo "==> Docker validation matrix passed"
