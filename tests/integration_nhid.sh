#!/usr/bin/env bash
# Real Linux/iproute2 nexthop-object coverage. Run only in a disposable
# privileged container or an otherwise explicitly authorized test host.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for module in 00-header.sh core.sh config.sh platform.sh path.sh state.sh sysctl.sh tc.sh nic.sh measure.sh; do
    # shellcheck source=/dev/null
    source "$ROOT_DIR/src/$module"
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo 'SKIP: integration_nhid requires root'; exit 0; }
command -v ip >/dev/null 2>&1 || { echo 'SKIP: integration_nhid requires iproute2'; exit 0; }

iface="nhv804$$"
other="nhx804$$"
leaf4=703065541
leaf6=703065542
leaf4b=703065543
group4=703065544
blackhole4=703065545

cleanup_nhid_integration() {
    ip -6 route del default nhid "$leaf6" metric 512 2>/dev/null || true
    ip -4 route del 198.18.40.0/24 2>/dev/null || true
    ip -4 route del 198.18.41.0/24 2>/dev/null || true
    ip -6 route del 2001:db8:805::/64 2>/dev/null || true
    ip nexthop del id "$group4" 2>/dev/null || true
    ip nexthop del id "$blackhole4" 2>/dev/null || true
    ip nexthop del id "$leaf4b" 2>/dev/null || true
    ip nexthop del id "$leaf6" 2>/dev/null || true
    ip nexthop del id "$leaf4" 2>/dev/null || true
    ip link del "$other" 2>/dev/null || true
    ip link del "$iface" 2>/dev/null || true
}
trap cleanup_nhid_integration EXIT

ip link add "$iface" type dummy
ip link add "$other" type dummy
ip link set "$iface" up
ip link set "$other" up
ip -4 address add 192.0.2.1/24 dev "$iface"
ip -6 address add 2001:db8:804::1/64 dev "$iface"

ip nexthop add id "$leaf4" via 192.0.2.2 dev "$iface"
ip nexthop add id "$leaf4b" via 192.0.2.3 dev "$iface"
ip nexthop add id "$leaf6" via 2001:db8:804::2 dev "$iface"
ip nexthop add id "$group4" group "$leaf4/$leaf4b"
ip nexthop add id "$blackhole4" blackhole
ip -4 route add 198.18.40.0/24 nhid "$leaf4"
ip -4 route add 198.18.41.0/24 nhid "$group4"
ip -6 route add 2001:db8:805::/64 nhid "$leaf6" metric 50
ip -6 route add default nhid "$leaf6" metric 512

[[ "$(default_route_interface_for_family -6)" == "$iface" ]] || {
    echo 'FAIL: real IPv6 default nhid route did not resolve to the expected interface' >&2
    exit 1
}

single4=$(ip -4 route get fibmatch 198.18.40.1)
[[ "$(route_unique_path_iface "$single4" 'real IPv4 leaf nhid' 4)" == "$iface" ]] || {
    echo 'FAIL: real IPv4 leaf nexthop object did not resolve to the expected interface' >&2
    exit 1
}

single6=$(ip -6 route get fibmatch 2001:db8:805::99)
[[ "$(route_unique_path_iface "$single6" 'real IPv6 leaf nhid' 6)" == "$iface" ]] || {
    echo 'FAIL: real IPv6 leaf nexthop object did not resolve to the expected interface' >&2
    exit 1
}

group_output=$(ip -4 route get fibmatch 198.18.41.1)
if route_unique_path_iface "$group_output" 'real multipath nhid group' 4 >/dev/null 2>&1; then
    echo 'FAIL: real nexthop group was accepted' >&2
    exit 1
fi

if route_unique_path_iface "198.18.40.0/24 nhid $blackhole4" 'real blackhole nhid' 4 >/dev/null 2>&1; then
    echo 'FAIL: real blackhole nexthop object was accepted' >&2
    exit 1
fi
if route_unique_path_iface '198.18.40.0/24 nhid 703065599 dev nhv0' 'missing nhid' 4 >/dev/null 2>&1; then
    echo 'FAIL: missing nexthop object was accepted' >&2
    exit 1
fi
if route_unique_path_iface "198.18.40.0/24 nhid $leaf4 via 192.0.2.2 dev $other" 'route/object mismatch' 4 >/dev/null 2>&1; then
    echo 'FAIL: real route/object interface mismatch was accepted' >&2
    exit 1
fi
if route_unique_path_iface "default nexthop via 192.0.2.2 dev $iface nexthop via 192.0.2.3 dev $iface" 'inline ECMP' 4 >/dev/null 2>&1; then
    echo 'FAIL: inline ECMP was accepted' >&2
    exit 1
fi

echo 'nhid integration tests: PASS'
