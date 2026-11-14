# HeatBar

Menu bar switch that puts the Mac it is running on under CPU and GPU load, and takes that load off again.

The icon is a flame. Clicking it opens a panel with three controls:

- **CPU** and **GPU** each have their own switch, so you can load one, the other, or both. The CPU load spins every logical core. The GPU load is a Metal matrix multiply.
- Each has a **target** from 10% to 100%. HeatBar reads the Mac's CPU load and the GPU's "Device Utilization %" once a second and adjusts its own load until the reading matches the target. Other software counts toward the reading, so a target of 60% means the Mac sits at 60%, not HeatBar's share of it.
- **Power cap** holds the whole Mac under a wattage you set, 20 W to 200 W. With the cap on, the load starts low and climbs until total system power reaches the cap, then stays there. While the cap is holding the load back, the utilization targets are not reached.

The panel shows total system power and the measured CPU and GPU load. Targets and the cap are remembered between launches. Quitting the app stops the load. **Launch at login** is off until you turn it on.

macOS 14 or later, with a Metal GPU. The load is meant to make the machine hot, so the fans will spin up if the system decides they should. HeatBar does not change fan settings.

The power cap needs the SMC key `PSTR`, which Apple silicon Macs report without root. On a Mac that does not report it, the cap is disabled. The reading trails the load by two to three seconds, so the cap takes about 15 seconds to settle and power can pass it briefly by a few watts.

## Build

```sh
./build.sh
cp -R build/HeatBar.app /Applications/
open /Applications/HeatBar.app
```

The build script compiles with `swiftc`, ad-hoc signs the app, and writes `build/HeatBar.app`. There is no Xcode project. The first time you open an unsigned local build, macOS may ask you to allow it under System Settings, Privacy & Security.

## Control socket

The running app listens on a user-only Unix socket:

```sh
printf 'start cpu 60\n' | nc -U "$HOME/Library/Application Support/HeatBar/control.sock"
```

| Command | Effect |
| --- | --- |
| `start` | Start CPU and GPU load at their current targets |
| `start cpu`, `start gpu` | Start one of them |
| `start cpu 60` | Set the target to 60% and start |
| `stop`, `stop cpu`, `stop gpu` | Stop both, or one |
| `cpu 80`, `gpu 80` | Change a target, running or not |
| `limit 60` | Turn the power cap on at 60 W |
| `limit off` | Turn the power cap off |
| `status` | Report state |

Every command replies with one status line, or `err ...`:

```
ok running cpu=60 gpu=off limit=60 power=57 scale=0.42
```

The second word is `running` when either load is on and `stopped` otherwise. `cpu` and `gpu` give the target or `off`. `power` is system power in watts. `scale` appears while the power cap is holding the load back, and is the fraction of full strength it allows.

The load runs in `heat-worker` processes inside the app bundle. They exit when the app does. If one is left behind anyway, the next launch kills the processes recorded in `~/Library/Application Support/HeatBar/pids`, and only those.

## License

[MIT](LICENSE)
