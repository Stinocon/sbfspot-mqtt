#!/usr/bin/env bash
# Tests for sbfspot-mqtt, run by CI (.github/workflows/ci.yml) and by check.sh.
#
# These are behaviour tests, on a real broker, driven through the command line: the program is a
# CLI around SBFspot, so what needs testing is what a command does to a broker and what
# configuration it hands to SBFspot — not the internals of a function.
#
# SBFspot itself is not required. The parts of it this program has a contract with are the ones
# that have broken before, so they are reproduced here by a stub: the `-cfg<path>` argument form,
# the flags of a spot read, and the publisher hook — including upstream's message templating,
# which is where an integration bug would live.
#
# Requires: jq, sed, mosquitto_pub/mosquitto_sub, and a broker on localhost:1883 that accepts
# anonymous connections.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly app="${root}/bin/sbfspot-mqtt"
work="$(mktemp -d)"
readonly work
readonly options="${work}/options.json"
readonly mqtt="${work}/mqtt.json"
readonly state_topic=sbfspot_mqtt/state
readonly availability_topic=sbfspot_mqtt/availability

failures=0
ok() { printf 'ok   - %s\n' "$1"; }
ko() { printf 'FAIL - %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; failures=$((failures + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else ko "$1" "$2" "$3"; fi; }

cleanup() { rm -rf "${work}"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------------------------
# The environment the program is given: the same two JSON files the add-on writes.
# ---------------------------------------------------------------------------------------------
if ! command -v mosquitto_pub > /dev/null; then
    echo "mosquitto_pub is not installed: this test needs a broker and its clients" >&2
    exit 1
fi
if ! mosquitto_pub -h localhost -t smoke -m 1 2> /dev/null; then
    echo "no MQTT broker on localhost:1883 accepting anonymous connections" >&2
    exit 1
fi

cat > "${options}" <<'EOF'
{"bt_address":"00:11:22:33:44:55","password":"0000","plantname":"TestPlant","interval":2,"log_level":"info"}
EOF
cat > "${mqtt}" <<EOF
{"host":"localhost","port":1883,"username":"","password":"","topic":"${state_topic}","availability_topic":"${availability_topic}","discovery_prefix":"homeassistant"}
EOF

# One reading, or "<missing>" when nothing was published at all — so an assertion that expects an
# empty string cannot pass because the publish failed instead of because the value was empty.
key() {
    mosquitto_sub -h localhost -t "${state_topic}" -W 2 -C 1 2> /dev/null \
        | jq -r --arg k "$1" '.[$k] // "<missing>"'
}
# The discovery topic is <prefix>/sensor/<node>/<key>/config: the node is one level, the key
# another, so both are passed rather than glued together.
config_of() { mosquitto_sub -h localhost -t "homeassistant/sensor/$1/$2/config" -W 2 -C 1 2> /dev/null || true; }
availability() { mosquitto_sub -h localhost -t "${availability_topic}" -W 2 -C 1 2> /dev/null || true; }
discovery_count() {
    mosquitto_sub -h localhost -t 'homeassistant/#' -W 2 -v 2> /dev/null | grep -c 'homeassistant/sensor/sbfspot_' || true
}

# ---------------------------------------------------------------------------------------------
# A stub for SBFspot. It records the command line it was given and the configuration it was
# pointed at, which is the contract; everything else about it is out of scope here.
# ---------------------------------------------------------------------------------------------
readonly fake="${work}/sbfspot"
cat > "${fake}" <<'EOF'
#!/usr/bin/env bash
# A stand-in for SBFspot, built to break if this program's side of the contract changes.
set -uo pipefail
printf '%s\n' "$*" >> "${FAKE_LOG}"

if [[ "${1:-}" == "-version" ]]; then
    echo "FAKE-SBFSPOT 1.0"
    exit 0
fi

# The configuration path arrives attached to -cfg, as SBFspot reads it.
for arg in "$@"; do
    case "${arg}" in
        -cfg*) cp "${arg#-cfg}" "${FAKE_CONFIG}" ;;
    esac
done

[[ -n "${FAKE_PAYLOAD:-}" ]] || exit 0

# Upstream's publisher hook, reproduced in its real order: the double quotes of the *template*
# become single quotes first, and only then is the message substituted. What the template receives
# is the message *body* — upstream builds `{` + body + `}` from the `<brace><brace>message<brace><brace>`
# in the configuration — which is why the JSON keeps its own double quotes and arrives whole.
publisher="$(grep '^MQTT_Publisher=' "${FAKE_CONFIG}" | cut -d= -f2-)"
args="$(grep '^MQTT_PublisherArgs=' "${FAKE_CONFIG}" | cut -d= -f2-)"
args="${args//\"/\'}"
body="${FAKE_PAYLOAD#\{}"
args="${args//\{message\}/${body%\}}}"
sh -c "${publisher} ${args}"
EOF
chmod +x "${fake}"
export FAKE_LOG="${work}/fake.log"
export FAKE_CONFIG="${work}/fake-config"
: > "${FAKE_LOG}"

# ---------------------------------------------------------------------------------------------
section() { printf '\n--- %s\n' "$1"; }

section "the CLI itself"
check "version prints the version" "0.1.0" "$("${app}" version)"
if "${app}" --help | grep -q 'SBFspot'; then
    ok "--help describes the program"
else
    ko "--help describes the program" "usage text" "no match"
fi
check "an unknown command fails" "1" "$("${app}" nonsense > /dev/null 2>&1; echo $?)"

section "generate-config"
cfg="${work}/SBFspot.cfg"
BT_ADDRESS=00:11:22:33:44:55 "${app}" generate-config \
    --options "${options}" --mqtt "${mqtt}" --sbfspot "${fake}" --target "${cfg}"
check "writes the inverter address" "BTAddress=00:11:22:33:44:55" "$(grep '^BTAddress=' "${cfg}")"
# SynchTime=0 is what keeps this read-only: upstream's default of 1 writes the plant clock over
# Bluetooth on every poll. A regression here silently starts writing to the inverter.
check "disables the clock write" "SynchTime=0" "$(grep '^SynchTime=' "${cfg}")"
check "writes no database" "CSV_Export=0" "$(grep '^CSV_Export=' "${cfg}")"
check "points the publisher hook at this program" "MQTT_Publisher=${app}" "$(grep '^MQTT_Publisher=' "${cfg}")"
check "keeps the file private" "600" "$(stat -c %a "${cfg}")"
check "refuses a plantname with a quote" "1" \
    "$(jq '.plantname = "O'\''Brien"' "${options}" > "${work}/quoted.json"; \
       "${app}" generate-config --options "${work}/quoted.json" --mqtt "${mqtt}" --sbfspot "${fake}" --target "${work}/x.cfg" > /dev/null 2>&1; echo $?)"

section "publish: SBFspot's payload, including the two ways it is malformed"
publish() { "${app}" publish --mqtt "${mqtt}" -m "$1" > /dev/null 2>&1 && echo 0 || echo $?; }

good='{"Timestamp": "2026-09-23T19:00:00","InvSerial": 1234567890,"InvName": "Test inverter","ETotal": 12345.67,"PACTot": 1234.5}'
check "a valid payload is accepted" "0" "$(publish "${good}")"
check "and published as it arrived" "1234.5" "$(key PACTot)"
check "with the numbers still numbers" "1234567890" "$(key InvSerial)"

# Upstream's to_keyvalue() collapses "" into ", so an empty value arrives unterminated:
# `"InvName": ""` becomes `"InvName": "`. This is what an inverter nobody named produces.
collapsed='{"Timestamp": "2026-09-23T19:00:00","InvSerial": 987654321,"InvName": ","InvStatus": "Ok"}'
check "the empty-value corruption is repaired, not refused" "0" "$(publish "${collapsed}")"
check "the empty value comes back as an empty string" "" "$(key InvName)"
check "the keys after the repaired one survive" "Ok" "$(key InvStatus)"

# The same corruption with a plant name that begins with a comma: a broader repair pattern would
# rewrite the plant name too, and leave the payload refused for good.
awkward='{"Plantname": ",MyPlant","InvName": ","InvStatus": "Ok"}'
check "a comma-leading value is not mistaken for the corruption" "0" "$(publish "${awkward}")"
check "and the plant name survives intact" ",MyPlant" "$(key Plantname)"

before="$(key PACTot)"
check "a payload truncated by a single quote is refused" "1" "$(publish '{"InvName": "O')"
check "and the previous reading is left standing" "${before}" "$(key PACTot)"
check "an empty message is refused" "1" "$(publish '')"
check "no arguments at all is refused" "1" "$("${app}" publish --mqtt "${mqtt}" > /dev/null 2>&1; echo $?)"

section "the publisher hook, as SBFspot calls it"
# This is the integration that has no unit test anywhere else: the argument template in the
# configuration, substituted and quoted the way upstream does it, has to reach this program as one
# JSON argument.
export FAKE_PAYLOAD='{"InvSerial": 555,"InvName": "Hooked","PACTot": 42.0}'
"${app}" poll --options "${options}" --mqtt "${mqtt}" --sbfspot "${fake}" > /dev/null
check "the read uses -cfg with the path attached" "yes" \
    "$(grep -qE -- '-cfg/[^ ]+$' "${FAKE_LOG}" && echo yes || echo no)"
check "the read asks for spot data only" "yes" \
    "$(grep -q -- '-q -ad0 -am0 -finq -mqtt' "${FAKE_LOG}" && echo yes || echo no)"
check "the hook publishes the reading" "42.0" "$(key PACTot)"
check "with the value it was given" "Hooked" "$(key InvName)"
check "and the generated configuration inside the poll had SynchTime=0" "SynchTime=0" "$(grep '^SynchTime=' "${FAKE_CONFIG}")"
unset FAKE_PAYLOAD

section "discovery"
payload='{"Timestamp":"2026-09-23T19:00:00","Plantname":"TestPlant","InvSerial":1234567890,"InvName":"Test inverter","InvTime":"2026-09-23T19:00:00","InvStatus":"Ok","InvTemperature":35.5,"InvGridRelay":"Closed","InvClass":"Solar Inverters","InvType":"SB 3000TL-20","InvSwVer":"03.30.06.R","EToday":12.34,"ETotal":12345.67,"PACTot":1234.5,"PDC1":1300.0,"PDC2":0.0,"IDC1":3.6,"IDC2":0.0,"UDC1":365.0,"UDC2":0.0,"GridFreq":50.01,"OperTm":34567.0,"FeedTm":33456.0}'
printf '%s' "${payload}" | "${app}" discover --mqtt "${mqtt}" > /dev/null
# 11 fixed sensors plus six for the two strings upstream always reports — upstream seeds both
# MPPT slots before every read, so a single-string inverter reports the second as 0.
check "17 configurations are published" "17" "$(discovery_count)"

power="$(config_of sbfspot_1234567890 pactot)"
check "power carries its unit" "W" "$(printf '%s' "${power}" | jq -r '.unit_of_measurement')"
check "power carries its device class" "power" "$(printf '%s' "${power}" | jq -r '.device_class')"
check "power reads the payload key" "{{ value_json.PACTot }}" "$(printf '%s' "${power}" | jq -r '.value_template')"
check "the device is registered once" "sbfspot_1234567890" "$(printf '%s' "${power}" | jq -r '.device.identifiers[0]')"
check "the device carries the model" "SB 3000TL-20" "$(printf '%s' "${power}" | jq -r '.device.model')"
check "the entities follow the availability topic" "${availability_topic}" "$(printf '%s' "${power}" | jq -r '.availability_topic')"

energy="$(config_of sbfspot_1234567890 etotal)"
check "lifetime energy is a total_increasing counter" "total_increasing" "$(printf '%s' "${energy}" | jq -r '.state_class')"
check "lifetime energy is in kWh" "kWh" "$(printf '%s' "${energy}" | jq -r '.unit_of_measurement')"
operating="$(config_of sbfspot_1234567890 opertm)"
check "operating time is a duration in hours" "duration/h" "$(printf '%s' "${operating}" | jq -r '.device_class')/$(printf '%s' "${operating}" | jq -r '.unit_of_measurement')"

output="$(printf '%s' '{"InvSerial":1,"InvName":"X","SomethingNew":5}' | "${app}" discover --mqtt "${mqtt}" 2>&1)"
if echo "${output}" | grep -q "no mapping for key 'SomethingNew'"; then
    ok "an unmapped key is reported, not published"
else
    ko "an unmapped key is reported, not published" "a warning naming the key" "${output}"
fi
check "a payload without a serial is refused" "1" \
    "$(printf '%s' '{"InvName":"X"}' | "${app}" discover --mqtt "${mqtt}" > /dev/null 2>&1; echo $?)"

section "watch: the loop"
# A fake that always fails, and a loop that must not die of it: three failures mark the inverter
# offline, and the loop keeps going. `timeout` is what proves it: 124 means it was still running
# when it was killed.
: > "${work}/failing.log"
cat > "${work}/failing" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "-version" ]] && { echo "FAKE-SBFSPOT 1.0"; exit 0; }
exit 1
EOF
chmod +x "${work}/failing"
"${app}" offline --mqtt "${mqtt}" > /dev/null 2>&1
rc=0
timeout 12 "${app}" watch --options "${options}" --mqtt "${mqtt}" --sbfspot "${work}/failing" \
    > "${work}/watch.log" 2>&1 || rc=$?
check "the loop survives a failing inverter" "124" "${rc}"
check "it marks the inverter offline after three failures" "offline" "$(availability)"
if grep -q "another Bluetooth" "${work}/watch.log"; then
    ok "the first failure is explained"
else
    ko "the first failure is explained" "the diagnosis in the log" "$(cat "${work}/watch.log")"
fi

# A fake that reports a reading: the loop publishes it, publishes discovery, and marks online.
export FAKE_PAYLOAD='{"InvSerial": 777,"InvName": "Watched","InvType":"SB 3000TL-20","PACTot": 99.0}'
"${app}" offline --mqtt "${mqtt}" > /dev/null 2>&1
rc=0
timeout 12 "${app}" watch --options "${options}" --mqtt "${mqtt}" --sbfspot "${fake}" \
    > "${work}/watch2.log" 2>&1 || rc=$?
check "the loop survives being killed by the supervisor" "124" "${rc}"
check "a successful read marks the inverter online" "online" "$(availability)"
check "and the reading reaches the broker" "99.0" "$(key PACTot)"
check "and its discovery was published" "yes" "$(config_of sbfspot_777 pactot | jq -e '.device.model == "SB 3000TL-20"' > /dev/null 2>&1 && echo yes || echo no)"
unset FAKE_PAYLOAD

printf '\n'
if (( failures > 0 )); then
    echo "${failures} test(s) failed"
    exit 1
fi
echo "all tests passed"
