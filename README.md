# sbfspot-mqtt

Read an SMA Sunny Boy inverter over Bluetooth and publish it to Home Assistant over MQTT.

It drives [SBFspot](https://github.com/SBFspot/SBFspot) — the tool that does the talking — on an
interval, and turns each reading into Home Assistant MQTT discovery: power, energy today and
total, status, temperature, the DC values per string, grid frequency, operating hours.

**It is read-only.** `-settime` is never passed, and the SBFspot configuration it generates sets
`SynchTime=0`: upstream's default for that is 1, and on a Bluetooth connection it rewrites the
plant clock on *every* poll.

This is the program behind the [SBFspot MQTT Bridge add-on](https://github.com/Stinocon/addons/tree/master/sbfspot-mqtt).
The add-on is one way to run it — the one that installs SBFspot, the runtime libraries and the
service. Nothing here needs Home Assistant: `bin/sbfspot-mqtt` takes files and paths, and runs the
same way on a Raspberry Pi with a broker on it.

## The inverter answers one master at a time

This is the constraint that explains most of what follows. A Sunny Boy accepts a single Bluetooth
connection, so a Sunny Beam on its shelf, a running Sunny Explorer or a Webbox holding the link
means this program gets failed connections and nothing else. The fix is not a setting here: it is
to switch the other master off.

## Requirements

- A Linux machine with `bash` 4 or later, and **within Bluetooth range of the inverter** — the
  radio is the machine's own.
- **SBFspot** built for that machine (upstream's `make nosql` is enough: no database is used), with
  its `date_time_zonespec.csv` next to the binary, which is where SBFspot looks for it.
- `mosquitto_pub` and `mosquitto_sub` (the `mosquitto-clients` package), `jq`.
- An MQTT broker that Home Assistant also uses. The Mosquitto add-on is the usual one.
- The inverter's **Bluetooth address** and its **user password** (`0000` is SMA's default, and
  the installer password is neither needed nor wanted: nothing here writes).

## Usage

```
sbfspot-mqtt watch            # the normal mode: poll, publish, publish discovery when it changes
sbfspot-mqtt poll             # one read, one publish
sbfspot-mqtt discover         # read a payload on stdin and publish discovery from it
sbfspot-mqtt publish          # SBFspot's publisher interface, called by SBFspot
sbfspot-mqtt offline          # mark the inverter offline on the availability topic
sbfspot-mqtt generate-config  # write the SBFspot configuration from the options
sbfspot-mqtt version
```

Two JSON files carry everything it needs, because that is what an add-on has and what keeps
credentials off a command line:

`options.json` — what the inverter is and how often to ask:

```json
{ "bt_address": "00:11:22:33:44:55", "password": "0000",
  "plantname": "MyPlant", "interval": 60, "log_level": "info" }
```

`mqtt.json` — where to publish, and under which topics:

```json
{ "host": "localhost", "port": 1883, "username": "", "password": "",
  "topic": "sbfspot_mqtt/state", "availability_topic": "sbfspot_mqtt/availability",
  "discovery_prefix": "homeassistant" }
```

A complete run without Home Assistant:

```bash
cat > /etc/sbfspot-mqtt.json <<'EOF'
{ "host": "localhost", "port": 1883, "username": "", "password": "",
  "topic": "sbfspot_mqtt/state", "availability_topic": "sbfspot_mqtt/availability",
  "discovery_prefix": "homeassistant" }
EOF
bin/sbfspot-mqtt watch \
  --options /etc/sbfspot-mqtt-options.json \
  --mqtt /etc/sbfspot-mqtt.json \
  --sbfspot /usr/local/bin/SBFspot
```

`--log-level debug` is passed through to SBFspot as `-v5`, which is its full configuration and
data dump: useful for one diagnosis, unreadable as a permanent setting.

## What it publishes

One device in Home Assistant, named after the inverter, with the sensors it reports:

| Sensor | Unit | Notes |
|--------|------|-------|
| Power | W | Instantaneous AC power. |
| Energy today | kWh | Resets at midnight. |
| Energy total | kWh | Lifetime yield — this is the one for the Energy dashboard. |
| Status | — | `Ok`, `Derating`, `Fault`, … as the inverter reports it. |
| Temperature | °C | |
| DC voltage / current / power, string N | V / A / W | One set per string the inverter reports; an input nobody wired reads zero. |
| Grid frequency | Hz | |
| Operating time, Feed-in time | h | Lifetime counters. |
| Grid relay, Inverter time, Data timestamp | — | Diagnostic entities, kept out of the way of a dashboard. |

**Energy dashboard:** *Settings → Dashboards → Energy → Solar production*, and pick **Energy
total**: it carries `device_class: energy`, `state_class: total_increasing` and `kWh`, which is
what the dashboard requires.

Two things about that list are worth knowing in advance, because both look like faults and
neither is:

- the channels *asked for* are a fixed list, and SBFspot answers every one of them — with `0` or
  `?` when the model has no such channel. A constant zero on the device page means the inverter
  reports nothing on that channel; it is not a fault.
- both MPPT slots are asked for, and an inverter that uses one of them reports a hard zero on the
  other: on the Sunny Boy this was written for, the array arrives in the *second* slot and the
  first reads 0 V, 0 A and 0 W on every poll. Which slot a model fills is the inverter's business
  and not something this program can know, so it asks for both rather than naming one. What that
  costs is three entities that read zero for as long as the installation exists, saying "a string
  input nobody wired" — disable them in Home Assistant if they are in the way on the device page.
- discovery is a set, not a list that only grows: a channel that stops appearing in the reading has
  its configuration deleted from the broker, so an entity does not outlive the channel behind it.

If the inverter stops answering, every entity goes **unavailable** after three failed polls, and
comes back on the next successful one. Stopping the program publishes `offline` too, so a stopped
bridge does not leave an hour-old value looking current.

## How it works

- **The configuration is generated, never shipped**, because it contains the inverter's password.
  It is written at every start and read by SBFspot, which is what makes `SynchTime=0` and
  `CSV_Export=0` enforceable rather than documented.
- **SBFspot reports through a hook this program provides.** Upstream builds a shell command line
  from `MQTT_Publisher` and `MQTT_PublisherArgs` and runs it with `system(3)`. Those two settings
  point back at `sbfspot-mqtt publish`, so the credentials stay in a file that the command line
  only names.
- **Two of upstream's habits are handled instead of documented away.** `to_keyvalue()` collapses
  an empty string value into an unterminated one — `"InvName": ""` arrives as `"InvName": "`, which
  is what an inverter nobody named produces — and that is repaired. A payload cut off by a single
  quote inside a value cannot be repaired, because the rest is gone: it is refused, with the raw
  text in the log, rather than published as a sensor that stops updating.
- **Discovery is derived from a real payload**, not from a wish list: a sensor is published for a
  key the reading actually carries, and a key with no mapping is reported and skipped, so a channel
  nobody has seen yet gets noticed instead of invented. It subtracts as well: a channel that stops
  appearing has its configuration deleted, rather than left on the broker describing nothing.

## Development

```bash
./check.sh          # syntax, shellcheck, and the behaviour tests against a broker
```

`check.sh` uses the broker on `localhost:1883` if there is one, starts a throwaway one if
`mosquitto` is installed, and says so if neither.

The tests in [`tests/glue.sh`](tests/glue.sh) drive the command line against a real broker. SBFspot
itself is not required: the parts of it this program has a contract with are the ones that have
broken before — the `-cfg<path>` argument form, the flags of a spot read, and the publisher hook
including upstream's message templating — and those are reproduced by a stub, so a change on
either side of that contract fails here.

## Credits and licence

MIT, see [`LICENSE`](LICENSE). SBFspot is not this repository's work and is not vendored here; its
licence is CC BY-NC-SA 3.0 — attribution, non-commercial, share-alike — and [`NOTICE.md`](NOTICE.md)
records what that means in practice.

SMA, Sunny Boy, Sunny Beam, Sunny Explorer and Webbox are registered trademarks of SMA Solar
Technology AG. This program is not affiliated with, or endorsed by, SMA.
