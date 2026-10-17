# HeatBar

Menu bar switch that puts the Mac it is running on under CPU and GPU load, and takes that load off again.

The icon is a flame. **Start stress** runs one `yes` process per logical CPU and a bundled Metal matrix multiply on the GPU. **Stop stress** terminates those processes. Quitting the app stops them too. **Launch at Login** is off until you turn it on.

macOS 14 or later. The Mac needs a Metal GPU. The load is meant to make the machine hot, so the fans will spin up if the system decides they should. HeatBar does not change fan settings.

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
printf 'status\n' | nc -U "$HOME/Library/Application Support/HeatBar/control.sock"
```

Commands are `start`, `stop`, and `status`. Replies are one line: `ok running`, `ok stopped`, or `err ...`.

If the app quits without stopping the load, the next launch kills the `yes` and `gpu-heat` processes recorded in `~/Library/Application Support/HeatBar/pids`, and only those.

## License

[MIT](LICENSE)
