# magneto-manager-tool

> **Note:** The canonical magneto-manager service (the Flask HTTP service that
> gets/sets the MCU and CAN bus UUIDs, and manages the linear-motor serial
> connection) lives at [`magnetox-os-update/auto-uuid/`](../magnetox-os-update/auto-uuid/).
> The stale copies of `magneto-manager.py` and `magneto-run.sh` that used to
> live here have been removed — make all service changes in the canonical copy.
>
> This directory now retains only the ESP32 flashing tools
> (`esp-update.py`, `esptool.sh`, `tool-esptool/`).
