# Running homebridge-poplight on a Synology NAS

Short version: it can work, but Synology dropped USB Bluetooth support in DSM 7 and ships no
Bluetooth kernel modules, so you have to add them yourself for your exact NAS model and DSM
build. If any step below fails, a Raspberry Pi next to the lights is the painless alternative.

## 1. Check the NAS can do it before buying anything

- Find your model's **platform** (package arch) and kernel: `uname -a` and
  `cat /etc.defaults/synoinfo.conf | grep platform` over SSH. Common ones: `geminilake`,
  `apollolake`, `v1000`, `r1000`, `rtd1296`.
- Search the Home Assistant community thread "USB Bluetooth support on Synology DSM 7.1 – 7.4"
  for prebuilt `bluetooth.ko` and `btusb.ko` matching **that platform and DSM version**. Modules
  built for a different kernel will not load. If nobody has built them for your model, stop here
  and use a Pi.
- The NAS must sit within ~10 m of the sconces with no large metal obstacles. A short USB
  extension cable to move the dongle out from behind the NAS helps a lot.

## 2. Dongle

Pick a dongle whose chipset the Linux `btusb` driver supports **without extra firmware files**,
because DSM has no `/lib/firmware` tooling:

- **CSR8510 (Cambridge Silicon Radio) "Bluetooth 4.0" dongles**: the safe choice. Cheap, no
  firmware, BLE 4.0 is all this plugin needs.
- Avoid Realtek (RTL8761B, most "Bluetooth 5.x" dongles) and Intel chipsets: they need firmware
  blobs loaded by the kernel, which is extra work on DSM.

## 3. Load the modules on the host

Over SSH as root, after copying the `.ko` files to a folder that survives updates (for example
`/volume1/docker/bt/`):

```sh
insmod /volume1/docker/bt/bluetooth.ko
insmod /volume1/docker/bt/btusb.ko
ls /sys/class/bluetooth        # expect hci0
```

Make it stick with a Task Scheduler "triggered task" that runs at boot as root. Some models also
need `rfkill`-style unblocking; `hciconfig hci0 up` from Entware's `bluez` package is the usual
test, but the plugin itself does not need BlueZ.

## 4. Homebridge container

The Homebridge Docker image needs host networking and raw socket rights. In Container Manager
use a Compose project:

```yaml
services:
  homebridge:
    image: homebridge/homebridge:latest
    network_mode: host
    privileged: true            # or: cap_add: [NET_ADMIN, NET_RAW]
    volumes:
      - /volume1/docker/homebridge:/homebridge
    environment:
      - NOBLE_HCI_DEVICE_ID=0   # which hciN to use
    restart: unless-stopped
```

Then in the plugin settings set **Bluetooth bindings** to `hci`. The HCI binding talks to the
adapter directly, so BlueZ/D-Bus is not required inside the container. If a `bluetoothd` is
running on the host (from Entware), stop it: two stacks on one adapter conflict.

If the log shows `adapter state unauthorized`, the container lacks `NET_RAW`/`NET_ADMIN`.
If it shows `unsupported` or never leaves `poweredOff`, the modules are not loaded or the dongle
is not detected (`lsusb` on the host should list it).

## 5. Install the plugin

Until it is on npm, install from the repo inside the container's terminal:

```sh
cd /homebridge && git clone https://github.com/aaronfisher/poplight.git
cd poplight/homebridge && npm install && npm run build && npm link
```

`@stoprocent/noble` compiles a small native module; the Homebridge image has the build tools.
Restart Homebridge, open the plugin's settings in the UI, set bindings to `hci`, enable the
battery tiles if you want them, save, restart. The lights appear in Home automatically because
they are added to the bridge you are already paired with.

## Removing the Mac dev bridge from Home first

In the Home app, long-press any "Poplight Dev Bridge" tile → settings → scroll to the bridge →
**Remove Bridge from Home**. That removes all its tiles at once.
