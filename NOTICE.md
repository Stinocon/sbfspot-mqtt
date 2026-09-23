# Provenance and licence scope

[`LICENSE`](LICENSE) is MIT and covers everything in this repository: the program in `bin/`, the
tests, the gate and the documentation are original work.

## What this program runs

Nothing is vendored here. The program shells out to tools that are installed on the machine:

| What | Licence | Why it is needed |
|---|---|---|
| [SBFspot](https://github.com/SBFspot/SBFspot) | **CC BY-NC-SA 3.0**, © SBF and the SBFspot contributors | It is the only thing that talks to the inverter: this program drives it and reads what it reports. |
| `mosquitto_pub`, `mosquitto_sub` (Eclipse Mosquitto) | EPL-2.0 / EDL-1.0 | Publishing a reading, and reading back what was published. |
| `jq` | MIT | Reading the option and credential files. |

SBFspot's licence is worth reading before using this program for anything commercial. It is
Creative Commons, not an open source licence, and the **NonCommercial** clause forbids commercial
use of the software and of anything built on it. The ShareAlike clause applies to modified
versions — this program does not modify SBFspot: it runs the upstream binary as released, and its
attribution is recorded here because anything that installs this program carries that notice with
it.

SMA, Sunny Boy, Sunny Beam, Sunny Explorer and Webbox are registered trademarks of SMA Solar
Technology AG. This program is not affiliated with, or endorsed by, SMA.
