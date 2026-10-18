# macha

A small background service for macOS that reports your Mac's state to [Home Assistant](https://www.home-assistant.io/) over MQTT. It has no window and no menu bar icon.

| Entity | Description |
|---|---|
| **Bluetooth connected devices** | How many paired devices are connected. The attributes `connected` and `paired` list their names. |
| **Wi-Fi network** | The name of the Wi-Fi network the Mac is on. |
| **Location** | The Mac's position, as a device tracker (so Home Assistant zones work). |

## Requirements

- macOS 13 or later, and Xcode 27 or later (Homebrew builds macha from source).
- An MQTT broker that Home Assistant uses, reachable over WebSocket (`ws://` or `wss://`), with a username and password. The Mosquitto add-on works.
- MQTT discovery enabled in Home Assistant (the default).

## Install

```bash
brew tap humanfriend22/tap
brew install macha
```

## Set up

1. Run `macha configure`. It asks for the broker URL, your MQTT username and password, and which sensors to send.
2. Sensors may require additional permissions and will be requested at the end of `configure`.
3. Run `macha doctor` to check the config, permissions, and broker connection.
4. Start the service:

   ```bash
   brew services start macha
   ```

   It now runs in the background and starts at login. The entities appear in Home Assistant under a device named after your MQTT username.

To change settings later, run `macha configure` again, then `brew services restart macha`.

## Commands

| Command | What it does |
|---|---|
| `macha configure` | Create or change the config. |
| `macha doctor` | Check the config, Bluetooth and Location access, and the broker connection. |
| `macha status` | List paired Bluetooth devices and which are connected. |
| `macha run` | Run in the foreground (this is what the service runs). |
| `macha config` | Print the config file path. |

The config lives at `~/.config/macha/config.json`.

## Privacy

MQTT username and password are stored in plain text but with the right Access Control List config, this won't be a worry.

```
pattern write macha/%u/#
pattern readwrite homeassistant/sensor/macha_%u/+/config
pattern readwrite homeassistant/binary_sensor/macha_%u/+/config
pattern readwrite homeassistant/device_tracker/macha_%u/+/config
```

## Build from source

```bash
git clone https://github.com/humanfriend22/macha.git
cd macha
./scripts/build.sh
.build/macha.app/Contents/MacOS/macha doctor
```

You may notice that `build.sh` packages an app. macOS only grants Location access to a signed app bundle, so `scripts/build.sh` wraps the binary in `macha.app` and tells Homebrew to symlink to the binary inside.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
