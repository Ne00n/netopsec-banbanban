#!/usr/bin/env bash
#
# update-banlist.sh - fetch a JSON banlist and DROP the prefixes with iptables.
#
# Expected API response:
#   {"results": ["34.97.202.0/24", "2001:db8::/32", ...]}
#
# Uses ipset (hash:net) so thousands of prefixes cost one iptables rule,
# and the set is swapped atomically so there is no window with an empty list.
#
# Requires: curl, jq, ipset, iptables (and ip6tables for IPv6). Run as root.

set -euo pipefail

API_URL="${API_URL:-https://report.opsec.wang/bans}"
CHAIN="${CHAIN:-INPUT}"             # use DOCKER-USER to also filter container traffic
SET4="${SET4:-netopsec4}"
SET6="${SET6:-netopsec6}"
MAXELEM="${MAXELEM:-262144}"

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
for cmd in curl jq ipset iptables; do
    command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2; exit 1; }
done

# ---- fetch -----------------------------------------------------------------
response="$(curl --silent --show-error --fail --max-time 30 --retry 3 "$API_URL")"

# One entry per line, deduplicated; fails if JSON is malformed.
entries="$(jq -r '.results[]?' <<<"$response" | sort -u)"

# Never wipe the existing ban set because of an empty/failed response.
if [[ -z "$entries" ]]; then
    echo "API returned no entries; leaving current rules untouched." >&2
    exit 1
fi

# ---- split by address family and validate -----------------------------------
v4="$(grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$' <<<"$entries" || true)"
v6="$(grep -E '^[0-9a-fA-F:]*:[0-9a-fA-F:.]*(/[0-9]{1,3})?$' <<<"$entries" || true)"

# ---- atomically (re)build an ipset ------------------------------------------
update_set() {
    local name="$1" family="$2" list="$3" tmp="${1}_tmp"
    [[ -n "$list" ]] || return 0

    ipset create -exist "$name" hash:net family "$family" maxelem "$MAXELEM"
    ipset destroy "$tmp" 2>/dev/null || true
    ipset create "$tmp" hash:net family "$family" maxelem "$MAXELEM"

    while read -r cidr; do
        echo "add $tmp $cidr"
    done <<<"$list" | ipset restore -exist

    ipset swap "$tmp" "$name"
    ipset destroy "$tmp"
    echo "$name: $(wc -l <<<"$list") prefixes loaded"
}

# ---- make sure the DROP rule exists (idempotent) ----------------------------
ensure_rule() {
    local ipt="$1" name="$2"
    if ! "$ipt" -C "$CHAIN" -m set --match-set "$name" src -j DROP 2>/dev/null; then
        "$ipt" -I "$CHAIN" 1 -m set --match-set "$name" src -j DROP
    fi
}

update_set "$SET4" inet "$v4"
[[ -n "$v4" ]] && ensure_rule iptables "$SET4"

if [[ -n "$v6" ]]; then
    if command -v ip6tables >/dev/null; then
        update_set "$SET6" inet6 "$v6"
        ensure_rule ip6tables "$SET6"
    else
        echo "ip6tables not found; skipping IPv6 prefixes." >&2
    fi
fi