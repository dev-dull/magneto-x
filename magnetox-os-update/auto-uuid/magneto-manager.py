from flask import Flask, request, jsonify
import os
import re
import socket
import subprocess
import shutil
import glob
import threading
import serial
import serial.tools.list_ports

CONFIG_PATH = "/home/pi/printer_data/config/magneto_device.cfg"
BACKUP_PATH = "/home/pi/printer_data/config/magneto_device.cfg.backup"
VERSION_STR = "magneto-x-mainsailOS-2024-5-1-v1.1.3-mag-x"

app = Flask(__name__)
serial_connection = None
# Serializes connect/disconnect/write on the shared LM serial connection so a
# concurrent /connect_lm cannot swap the global mid-write of a /send_command.
serial_lock = threading.Lock()
motor_control_process = None


def connect_to_serial():
    ports = serial.tools.list_ports.comports()
    for port in ports:
        # print(port.description)
        if "USB Serial" in port.description:
            try:
                return serial.Serial(port.device, 115200)
            except Exception as e:
                print(f"Connect failed: {e}")
    return None


def reconnect_serial():
    """(Re)establish the shared LM serial connection. Caller holds serial_lock.

    Closes any existing (possibly stale) handle first, then runs the same
    port-scan logic as /connect_lm. Returns the new connection or None.
    """
    global serial_connection
    if serial_connection is not None:
        try:
            serial_connection.close()
        except Exception:
            pass
    serial_connection = connect_to_serial()
    return serial_connection


@app.route("/get_os_version", methods=["GET"])
def get_os_version():
    return jsonify({"version": VERSION_STR})


@app.route("/get_git_version", methods=["GET"])
def get_git_version():
    # -c safe.directory=... scopes the safe-directory grant to this call
    # instead of appending a duplicate global config entry on every request.
    git_base = [
        "git",
        "-c",
        "safe.directory=/home/pi/magnetox-os-update",
        "-C",
        "/home/pi/magnetox-os-update/",
    ]
    try:
        version_from_git_branch = subprocess.run(
            git_base + ["rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        )
        version_from_git_commit = subprocess.run(
            git_base + ["rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        )
    except subprocess.CalledProcessError as e:
        # e.g. /home/pi/magnetox-os-update is absent mid-update (the _UPDATE_OS
        # macro deletes it before re-cloning) or is not a git repo.
        return (
            jsonify({"error": f"git version query failed: {e.stderr or e}"}),
            500,
        )
    except OSError as e:
        return jsonify({"error": f"git version query failed: {e}"}), 500
    return jsonify(
        {
            "git_branch": version_from_git_branch.stdout.replace("\n", ""),
            "git_commit": version_from_git_commit.stdout.replace("\n", ""),
        }
    )


@app.route("/get_timezone", methods=["GET"])
def get_timezone():
    # Ported from upstream PR mypeopoly/magnetox-os-update#8 (author: nmavor),
    # with -p Timezone --value so the raw value is returned rather than the
    # literal 'Timezone=...' key=value pair.
    try:
        timezone = subprocess.run(
            ["timedatectl", "show", "-p", "Timezone", "--value"],
            capture_output=True,
            text=True,
            check=True,
        )
    except subprocess.CalledProcessError as e:
        return (
            jsonify({"error": f"Failed to read timezone: {e.stderr or e}"}),
            500,
        )
    except OSError as e:
        return jsonify({"error": f"Failed to read timezone: {e}"}), 500
    return jsonify({"timezone": timezone.stdout.strip()})


@app.route("/set_timezone", methods=["GET", "POST"])
def set_timezone():
    new_timezone = request.args.get("timezone", default=None)
    if new_timezone is None:
        # No timezone given: geolocate one from the printer's public IP.
        try:
            result = subprocess.run(
                ["curl", "--fail", "https://ipapi.co/timezone"],
                capture_output=True,
                text=True,
                check=True,
            )
        except subprocess.CalledProcessError as e:
            return (
                jsonify(
                    {
                        "error": "Failed to look up timezone from ipapi.co: "
                        f"{e.stderr or e}"
                    }
                ),
                502,
            )
        except OSError as e:
            return (
                jsonify({"error": f"Failed to look up timezone from ipapi.co: {e}"}),
                502,
            )
        new_timezone = result.stdout.strip()
        if not new_timezone:
            return jsonify({"error": "ipapi.co returned an empty timezone"}), 502
    try:
        subprocess.run(
            ["timedatectl", "set-timezone", new_timezone],
            capture_output=True,
            text=True,
            check=True,
        )
    except subprocess.CalledProcessError as e:
        return (
            jsonify(
                {
                    "error": f"Failed to set timezone {new_timezone!r}: "
                    f"{e.stderr or e}"
                }
            ),
            500,
        )
    except OSError as e:
        return (
            jsonify({"error": f"Failed to set timezone {new_timezone!r}: {e}"}),
            500,
        )
    return jsonify({"timezone": new_timezone})


@app.route("/connect_lm", methods=["GET"])
def connect_esplm():
    global serial_connection
    with serial_lock:
        connection = reconnect_serial()
        if connection is None:
            return jsonify({"error": "No device found"}), 503
        print(f"Connected {connection.port}")
        return jsonify({"connected": connection.port})


@app.route("/disconnect_lm", methods=["GET"])
def disconnect_serial():
    global serial_connection
    with serial_lock:
        if serial_connection is not None and serial_connection.is_open:
            serial_connection.close()
            # Drop the handle: a closed pyserial Serial is still truthy, and a
            # lingering closed-but-truthy global silently disabled every later
            # LM enable (see issue #47).
            serial_connection = None
            print("Serial connection closed.")
            return jsonify({"info": "Serial connection closed"})
        serial_connection = None
        print("No open serial connection to close.")
        return jsonify({"info": "No open serial connection to close"})


@app.route("/motor_control", methods=["GET"])
def linear_motor_debug():
    global motor_control_process
    if motor_control_process is not None and motor_control_process.poll() is None:
        return jsonify({"error": "Magmotor GUI is already running"}), 409
    try:
        # mag_motor_control.sh launches the Magmotor Qt GUI on the printer's
        # touchscreen; it requires a running X session (the script exports
        # DISPLAY=:0). Launch via Popen so this handler returns immediately
        # instead of blocking for the lifetime of the GUI (which made the
        # macro's 2s curl timeout trip on every call).
        motor_control_process = subprocess.Popen(
            ["/home/pi/auto-uuid/mag_motor_control.sh"]
        )
        return jsonify({"suc": "Magmotor GUI launched"})
    except Exception as e:
        return jsonify({"error": f"Failed to launch Magmotor GUI: {e}"}), 500


@app.route("/send_command", methods=["GET"])
def send_command():
    global serial_connection
    command = request.args.get("command")
    if not command:
        return jsonify({"error": "Missing required parameter: command"}), 400
    data = (command + "\n").encode()

    with serial_lock:
        # Guard against both a never-connected port and a closed-but-truthy
        # handle left behind by /disconnect_lm; attempt one reconnect before
        # failing (the LM board may have enumerated late or re-enumerated).
        if serial_connection is None or not serial_connection.is_open:
            if reconnect_serial() is None:
                return (
                    jsonify(
                        {"error": "Serial port not connected and reconnect failed"}
                    ),
                    503,
                )

        try:
            serial_connection.write(data)
            return jsonify({"suc": "Send success"})
        except Exception as first_error:
            # The write failed on an open-looking port (e.g. USB dropped):
            # attempt one reconnect, then retry the write once.
            if reconnect_serial() is None:
                return (
                    jsonify(
                        {
                            "error": f"Send failed ({first_error}); "
                            "reconnect failed"
                        }
                    ),
                    503,
                )
            try:
                serial_connection.write(data)
                return jsonify({"suc": "Send success (after reconnect)"})
            except Exception as e:
                return jsonify({"error": f"Send failed after reconnect: {e}"}), 503


@app.route("/auto_resize_filesystem", methods=["GET"])
def auto_resize_filesystem():
    try:
        output = run_command("systemctl start orangepi-resize-filesystem.service")
        print("resize filesystem")
        return jsonify({"success": output})
    except subprocess.CalledProcessError as e:
        return (
            jsonify(
                {
                    "error": "Error occurred while resizing filesystem: "
                    + format_called_process_error(e)
                }
            ),
            500,
        )


def run_command(command):
    """Run a shell command and return its output.

    Raises subprocess.CalledProcessError (with combined stdout/stderr attached
    as e.output) on a non-zero exit, so callers can distinguish failure output
    from real results instead of having errors silently fed downstream.
    """
    return subprocess.check_output(
        command, shell=True, stderr=subprocess.STDOUT
    ).decode("utf-8")


def format_called_process_error(e):
    output = e.output
    if isinstance(output, bytes):
        output = output.decode("utf-8", "replace")
    return f"command failed (exit {e.returncode}): {output}"


def extract_uuids(output):
    uuids = re.findall(r"canbus_uuid=(\w+)", output)
    return uuids


def backup_config_file(filename):
    backup_filename = filename + ".backup"
    shutil.copy2(filename, backup_filename)


def modify_config_file(filename, uuid):
    """Replace the canbus_uuid line in the config file.

    Returns True if a canbus_uuid line was found and rewritten, False if the
    file contains no canbus_uuid line (in which case the file is untouched).
    """
    with open(filename, "r") as file:
        lines = file.readlines()

    found = False
    for index, line in enumerate(lines):
        if "canbus_uuid:" in line:
            lines[index] = f"canbus_uuid: {uuid}\n"
            found = True
            break

    if not found:
        return False

    with open(filename, "w") as file:
        file.writelines(lines)
        file.flush()
        os.fsync(file.fileno())
    return True

    ## mcu uuid get


def get_serial_devices():
    devices = glob.glob("/dev/serial/by-id/*")
    return devices


def backup_config():
    shutil.copy2(CONFIG_PATH, BACKUP_PATH)


def update_config_file(device):
    """Point the [mcu] serial: line at the given device.

    Returns True if the config file was updated (an existing serial: line was
    rewritten, or a new [mcu] section was appended because none existed).
    Returns False if nothing was written — no device given, or an [mcu]
    section exists but has no serial: line to rewrite.
    """
    if not device:
        return False

    with open(CONFIG_PATH, "r") as file:
        content = file.readlines()

    mcu_section_found = False
    updated = False
    for index, line in enumerate(content):
        if line.strip() == "[mcu]":
            mcu_section_found = True

            while (
                index < len(content)
                and "serial:" not in content[index]
                and content[index].strip() != ""
            ):
                index += 1
            if index < len(content) and "serial:" in content[index]:
                content[index] = "serial: {}\n".format(device)
                updated = True
                break

    if not mcu_section_found:
        content.append("\n[mcu]\n")
        content.append("serial: {}\n".format(device))
        updated = True

    if not updated:
        return False

    with open(CONFIG_PATH, "w") as file:
        file.writelines(content)
        file.flush()
        os.fsync(file.fileno())
    return True


@app.route("/get-ip", methods=["GET"])
def get_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # 使用一个不存在的地址，目的是为了初始化一个连接，以获取正确的IP
        s.connect(("10.255.255.255", 1))
        IP = s.getsockname()[0]
    except Exception:
        IP = "127.0.0.1"
    finally:
        s.close()
    return jsonify({"ip": IP})


@app.route("/get-mcu-uuid", methods=["GET"])
def get_mcu_uuid():
    if not os.path.exists(CONFIG_PATH):
        print("Error: Config file not found at", CONFIG_PATH)
        return jsonify({"error": "Config file not found"}), 404

    devices = get_serial_devices()
    for device in devices:
        if device.startswith("/dev/serial/by-id/usb-Klipper"):
            return jsonify({"mcu-uuid": device})
    return jsonify({"error": "No Klipper MCU serial device found"}), 404


@app.route("/set-mcu-uuid", methods=["GET"])
def set_mcu_uuid():
    if not os.path.exists(CONFIG_PATH):
        print("Error: Config file not found at", CONFIG_PATH)
        return jsonify({"error": "Config file not found"}), 404

    devices = get_serial_devices()
    for device in devices:
        if device.startswith("/dev/serial/by-id/usb-Klipper"):
            backup_config()
            if update_config_file(device):
                return jsonify({"mcu-uuid-success": device})
            return (
                jsonify(
                    {
                        "error": "[mcu] section has no serial: line to update; "
                        "config file left unchanged"
                    }
                ),
                500,
            )
    return jsonify({"error": "No MCU uuid found"}), 404


@app.route("/set-can-uuid", methods=["GET"])
def set_can_uuid():
    config_path = "/home/pi/printer_data/config/magneto_device.cfg"

    # 检查文件是否存在
    if not os.path.exists(config_path):
        return jsonify({"error": f"{config_path} not found!"}), 404

    command = (
        "/home/pi/klippy-env/bin/python /home/pi/klipper/scripts/canbus_query.py can0"
    )
    try:
        output = run_command(command)
    except subprocess.CalledProcessError as e:
        return (
            jsonify({"error": "canbus_query.py " + format_called_process_error(e)}),
            500,
        )
    uuids = extract_uuids(output)

    # 判断uuids的数量并取适当的值
    if len(uuids) == 2:
        uuid_to_use = uuids[-1]
        # Only overwrite the last-good .backup once the new state has been
        # validated — a failed query must not destroy the rollback copy.
        backup_config_file(config_path)
        if modify_config_file(config_path, uuid_to_use):
            return jsonify({"suc": "set canbus uuid successful"})
        return (
            jsonify(
                {
                    "error": "no canbus_uuid: line found in config; "
                    "config file left unchanged"
                }
            ),
            500,
        )
    else:
        return jsonify({"error": f"only {len(uuids)} canbus uuids found!"}), 500


@app.route("/get-can-uuid", methods=["GET"])
def get_can_uuid():
    command = (
        "/home/pi/klippy-env/bin/python /home/pi/klipper/scripts/canbus_query.py can0"
    )
    try:
        output = run_command(command)
    except subprocess.CalledProcessError as e:
        return (
            jsonify({"error": "canbus_query.py " + format_called_process_error(e)}),
            500,
        )
    uuids = extract_uuids(output)

    return jsonify({"can-uuids": uuids})


if __name__ == "__main__":
    serial_connection = connect_to_serial()
    if serial_connection is None:
        print("No device found!")
    else:
        print(f"Connected {serial_connection.port}")
    app.run(host="0.0.0.0", port=8880)
