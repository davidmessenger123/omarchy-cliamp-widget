#!/usr/bin/env python3
import json
import os
import selectors
import signal
import stat
import subprocess
import sys
import time

SYSTEM_BINDIRS = ("/usr/local/bin", "/usr/share/omarchy/bin", "/usr/bin", "/bin")
SYSTEM_PATH = ":".join(SYSTEM_BINDIRS)
DEFAULT_MAX_OUTPUT = 1024 * 1024
DEFAULT_MAX_LINE = 256 * 1024
READ_SIZE = 65536
_ACTIVE_PROCESS = None


def _terminate(signum, frame):
    process = _ACTIVE_PROCESS
    if process is not None:
        _kill_group(process)
    os._exit(128 + signum)


def _error(message):
    try:
        sys.stderr.write(str(message)[:512] + "\n")
        sys.stderr.flush()
    except OSError:
        pass


def _safe_text(value, limit=4096):
    if not isinstance(value, str) or not value or len(value) > limit:
        raise ValueError("invalid executable")
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError("invalid executable")
    return value


def _safe_arg(value):
    if not isinstance(value, str) or len(value) > 1024 * 1024:
        raise ValueError("invalid argument")
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError("invalid argument")
    return value


def _trusted_file(path, system=False):
    try:
        resolved = os.path.realpath(path)
        info = os.stat(resolved)
    except OSError:
        return None
    allowed_owner = 0 if system else (0, os.geteuid())
    if not stat.S_ISREG(info.st_mode) or info.st_uid not in allowed_owner:
        return None
    if stat.S_IMODE(info.st_mode) & 0o022:
        return None
    if not os.access(resolved, os.X_OK):
        return None
    return resolved


def resolve_executable(value):
    value = _safe_text(value)
    if os.path.isabs(value):
        return _trusted_file(value)
    if "/" in value:
        return None
    for directory in SYSTEM_BINDIRS:
        candidate = _trusted_file(os.path.join(directory, value), system=True)
        if candidate:
            return candidate
    return None


def _child_environment():
    env = {
        "PATH": SYSTEM_PATH,
        "LANG": "C",
        "LC_ALL": "C",
    }
    for name in ("HOME", "USER", "LOGNAME", "XDG_RUNTIME_DIR"):
        value = os.environ.get(name, "")
        if value and len(value) <= 4096 and "\x00" not in value and "\n" not in value and "\r" not in value:
            if name == "HOME" and not os.path.isabs(value):
                continue
            env[name] = value
    return env


def _child_command(command):
    if not isinstance(command, (list, tuple)) or not command or len(command) > 32:
        raise ValueError("invalid command")
    executable = resolve_executable(command[0])
    if not executable:
        raise ValueError("executable is not trusted")
    values = [executable]
    total = 0
    for value in command[1:]:
        value = _safe_arg(value)
        total += len(value)
        if total > 1024 * 1024:
            raise ValueError("command is too large")
        values.append(value)
    return values


def _spawn(command):
    try:
        return subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
            env=_child_environment(),
            bufsize=0,
        )
    except OSError as error:
        raise RuntimeError(str(error)) from error


def _kill_group(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except OSError:
        try:
            process.kill()
        except OSError:
            pass


def _read_run_output(process, maximum, timeout):
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    output = bytearray()
    deadline = time.monotonic() + max(1, min(120, timeout))
    status = 0
    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                status = 124
                _kill_group(process)
                process.wait()
                break
            for key, _ in selector.select(min(0.25, remaining)):
                chunk = os.read(key.fileobj.fileno(), min(READ_SIZE, maximum + 1 - len(output)))
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                output.extend(chunk)
                if len(output) > maximum:
                    status = 125
                    _kill_group(process)
                    process.wait()
                    break
            if status:
                break
    except Exception:
        status = 1
        _kill_group(process)
        try:
            process.wait(timeout=1)
        except (OSError, subprocess.TimeoutExpired):
            pass
    finally:
        selector.close()
        try:
            process.stdout.close()
        except OSError:
            pass
    if status:
        return status, bytes(output[:maximum])
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        _kill_group(process)
        process.wait()
    return process.returncode, bytes(output)


def run_once(command, maximum, timeout):
    global _ACTIVE_PROCESS
    child_command = _child_command(command)
    process = _spawn(child_command)
    _ACTIVE_PROCESS = process
    code, output = _read_run_output(process, maximum, timeout)
    _ACTIVE_PROCESS = None
    if output and not output.endswith(b"\n") and len(output) < maximum:
        output += b"\n"
    try:
        sys.stdout.buffer.write(output)
        sys.stdout.buffer.flush()
    except AttributeError:
        sys.stdout.write(output.decode("utf-8", "replace"))
        sys.stdout.flush()
    return code


def _write_line(value):
    data = value if isinstance(value, bytes) else str(value).encode("utf-8")
    sys.stdout.buffer.write(data + b"\n")
    sys.stdout.buffer.flush()


def stream_lines(command, maximum):
    global _ACTIVE_PROCESS
    child_command = _child_command(command)
    process = _spawn(child_command)
    _ACTIVE_PROCESS = process
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    pending = bytearray()
    deadline = time.monotonic() + 86400
    overflow = False
    eof = False
    try:
        while selector.get_map() and not overflow:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                overflow = True
                break
            for key, _ in selector.select(min(0.25, remaining)):
                chunk = os.read(key.fileobj.fileno(), min(READ_SIZE, maximum + 1 - len(pending)))
                if not chunk:
                    selector.unregister(key.fileobj)
                    eof = True
                    continue
                pending.extend(chunk)
                while True:
                    index = pending.find(b"\n")
                    if index < 0:
                        break
                    line = bytes(pending[:index]).rstrip(b"\r")
                    del pending[:index + 1]
                    try:
                        _write_line(line.decode("utf-8"))
                    except UnicodeDecodeError:
                        overflow = True
                        break
                if len(pending) > maximum:
                    overflow = True
                    break
            if eof and not selector.get_map():
                break
        if pending and not overflow:
            try:
                _write_line(bytes(pending).decode("utf-8"))
            except UnicodeDecodeError:
                overflow = True
    except Exception:
        overflow = True
    finally:
        selector.close()
        try:
            process.stdout.close()
        except OSError:
            pass
    if overflow:
        _kill_group(process)
        process.wait()
        _ACTIVE_PROCESS = None
        _write_line(json.dumps({"error": "output line too long"}, separators=(",", ":")))
        return 125
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        _kill_group(process)
        process.wait()
    _ACTIVE_PROCESS = None
    return process.returncode


def launch_terminal(command):
    child_command = _child_command(command)
    launcher = resolve_executable("omarchy-launch-terminal")
    if not launcher:
        raise ValueError("terminal executable is not trusted")
    try:
        process = subprocess.Popen(
            [launcher, child_command[0]],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
            env=_child_environment(),
        )
    except OSError as error:
        raise RuntimeError(str(error)) from error
    return 0 if process.pid > 0 else 1


def _parse_args(argv):
    if not argv or argv[0] not in ("run", "stream", "terminal"):
        raise ValueError("mode is required")
    mode = argv[0]
    maximum = DEFAULT_MAX_OUTPUT
    line_maximum = DEFAULT_MAX_LINE
    timeout = 30.0
    index = 1
    while index < len(argv) and argv[index] != "--":
        option = argv[index]
        if option in ("--max-output", "--max-line", "--timeout"):
            if index + 1 >= len(argv):
                raise ValueError("option value is required")
            value = argv[index + 1]
            index += 2
        elif option.startswith("--max-output="):
            value = option.split("=", 1)[1]
            option = "--max-output"
            index += 1
        elif option.startswith("--max-line="):
            value = option.split("=", 1)[1]
            option = "--max-line"
            index += 1
        elif option.startswith("--timeout="):
            value = option.split("=", 1)[1]
            option = "--timeout"
            index += 1
        else:
            raise ValueError("unknown option")
        try:
            if option == "--timeout":
                timeout = float(value)
            else:
                number = int(value)
                if option == "--max-output":
                    maximum = number
                else:
                    line_maximum = number
        except ValueError as error:
            raise ValueError("invalid option value") from error
    if index >= len(argv) or argv[index] != "--":
        raise ValueError("command separator is required")
    command = list(argv[index + 1:])
    if not command:
        raise ValueError("command is required")
    if maximum < 1 or maximum > 16 * 1024 * 1024:
        raise ValueError("invalid output limit")
    if line_maximum < 256 or line_maximum > 16 * 1024 * 1024:
        raise ValueError("invalid line limit")
    if timeout < 1 or timeout > 120:
        raise ValueError("invalid timeout")
    return type("Options", (), {
        "mode": mode,
        "max_output": maximum,
        "max_line": line_maximum,
        "timeout": timeout,
    })(), command


def main(argv=None):
    try:
        signal.signal(signal.SIGTERM, _terminate)
        signal.signal(signal.SIGINT, _terminate)
        args, command = _parse_args(list(sys.argv[1:] if argv is None else argv))
        if args.mode == "run":
            return run_once(command, args.max_output, args.timeout)
        if args.mode == "stream":
            return stream_lines(command, args.max_line)
        return launch_terminal(command)
    except (OSError, RuntimeError, ValueError) as error:
        _error(error)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
