#!/usr/bin/env bash
# check.sh — the repository's gate, to be run before every commit and by CI.
#
# One pass over what has to stay true: the program parses, shellcheck finds nothing, and the
# behaviour tests pass against a real broker.
#
# The broker is the one thing this needs from the machine. If there is already one on 1883 it is
# used as it is; if mosquitto is installed but idle, one is started on a throwaway configuration
# and shut down again on the way out; if neither, this says so instead of failing somewhere inside
# the tests with "no broker".
set -uo pipefail

if [ -t 1 ]; then
    GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; BOLD='\033[1m'; OFF='\033[0m'
else
    GREEN=''; RED=''; YELLOW=''; BOLD=''; OFF=''
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}" || exit 1
FAILED=0
WARNINGS=0

section() { printf '\n%b%s%b\n' "${BOLD}" "$1" "${OFF}"; }
ok()      { printf '  %b+%b %s\n' "${GREEN}" "${OFF}" "$1"; }
ko()      { printf '  %b-%b %s\n' "${RED}" "${OFF}" "$1"; FAILED=$((FAILED + 1)); }
warn()    { printf '  %b!%b %s\n' "${YELLOW}" "${OFF}" "$1"; WARNINGS=$((WARNINGS + 1)); }

# The throwaway broker started below is shut down on the way out. Inline rather than a function:
# a function reachable only from a trap is one static analysis cannot see, and silencing that with
# a directive would be a line to maintain in exchange for nothing.
broker_pid=""
trap 'if [[ -n "${broker_pid}" ]]; then kill "${broker_pid}" 2> /dev/null || true; fi' EXIT

# ---------------------------------------------------------------- 1. syntax
section "Syntax"
if bash -n bin/sbfspot-mqtt && bash -n tests/glue.sh; then
    ok "the program and the tests parse"
else
    ko "a syntax error"
fi

# ---------------------------------------------------------------- 2. shellcheck
section "shellcheck"
if command -v shellcheck > /dev/null; then
    if shellcheck bin/sbfspot-mqtt tests/glue.sh check.sh; then
        ok "shellcheck is clean"
    else
        ko "shellcheck reported findings"
    fi
else
    warn "shellcheck is not installed here: CI runs it, this run did not"
fi

# ---------------------------------------------------------------- 3. a broker
section "Broker"
if mosquitto_pub -h localhost -t check -m 1 2> /dev/null; then
    ok "using the broker already on localhost:1883"
elif command -v mosquitto > /dev/null; then
    # 644: mosquitto drops privileges after reading this, and a 600 file owned by the invoking
    # user is one it cannot open — which looks exactly like "the broker did not start".
    conf="$(mktemp)"
    log="$(mktemp)"
    chmod 644 "${conf}"
    printf 'listener 1883 127.0.0.1\nallow_anonymous true\npid_file /tmp/sbfspot-mqtt-check.pid\n' > "${conf}"
    mosquitto -c "${conf}" -d 2> "${log}" || true
    for _ in $(seq 1 20); do
        if mosquitto_pub -h localhost -t check -m 1 2> /dev/null; then break; fi
        sleep 0.5
    done
    if [[ -r /tmp/sbfspot-mqtt-check.pid ]]; then
        broker_pid="$(cat /tmp/sbfspot-mqtt-check.pid)"
    fi
    if mosquitto_pub -h localhost -t check -m 1 2> /dev/null; then
        ok "started a local broker for this run (pid ${broker_pid:-unknown})"
    else
        ko "could not start a broker"
        tail -3 "${log}" | sed 's/^/      /'
    fi
else
    ko "no broker on localhost:1883 and mosquitto is not installed"
    printf '      install mosquitto, or start one with:\n'
    printf '      printf "listener 1883 127.0.0.1\\\\nallow_anonymous true\\\\n" | mosquitto -c /dev/stdin -d\n'
fi

# ---------------------------------------------------------------- 4. behaviour
section "Behaviour"
if (( FAILED == 0 )); then
    if ./tests/glue.sh; then
        ok "the behaviour tests passed"
    else
        ko "the behaviour tests failed"
    fi
else
    warn "skipped: the checks above have to pass first"
fi

# ---------------------------------------------------------------- outcome
printf '\n'
if (( FAILED == 0 )) && (( WARNINGS > 0 )); then
    printf '%b\n\n' "${YELLOW}${BOLD}Green, with ${WARNINGS} warning(s).${OFF}"
    exit 0
elif (( FAILED == 0 )); then
    printf '%b\n\n' "${GREEN}${BOLD}All green.${OFF}"
    exit 0
fi
printf '%b\n\n' "${RED}${BOLD}${FAILED} check(s) failed.${OFF} Fix before committing."
exit 1
