#!/usr/bin/python3
import os
import re
import signal
import stat
import sys

PID_RE = re.compile(r"^[1-9][0-9]{0,9}$")
SYSTEM_BINDIRS = ("/usr/local/bin", "/usr/share/omarchy/bin", "/usr/bin", "/bin")


def _error(message):
    try:
        sys.stderr.write(str(message)[:256] + "\n")
        sys.stderr.flush()
    except OSError:
        pass


def _open_directory(path):
    value = os.path.abspath(os.fspath(path))
    if not os.path.isabs(value) or "\x00" in value:
        raise OSError("invalid directory")
    flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    current = os.open("/", flags)
    try:
        for component in value.split(os.sep)[1:]:
            if not component or component in (".", ".."):
                raise OSError("invalid directory")
            next_fd = os.open(component, flags, dir_fd=current)
            info = os.fstat(next_fd)
            mode = stat.S_IMODE(info.st_mode)
            if (not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, os.geteuid())
                    or (mode & 0o022 and not (info.st_uid == 0 and mode & 0o1000))):
                os.close(next_fd)
                raise OSError("unsafe directory")
            os.close(current)
            current = next_fd
        return current
    except Exception:
        os.close(current)
        raise


def _safe_path(value):
    if not isinstance(value, str) or not value or len(value) > 4096:
        return None
    if not os.path.isabs(value) or any(ord(char) < 32 or ord(char) == 127 for char in value):
        return None
    target = os.path.abspath(value)
    parts = target.split(os.sep)
    if len(parts) < 4 or parts[-3] != ".config" or parts[-2] != "cliamp" or parts[-1] != "cliamp.sock.pid":
        return None
    if any(part in ("", ".", "..") for part in parts[1:-1]) or os.path.realpath(target) != target:
        return None
    try:
        parent = _open_directory(os.path.dirname(target))
    except OSError:
        return None
    try:
        info = os.fstat(parent)
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o022:
            return None
    finally:
        os.close(parent)
    return target


def read_pid(path):
    target = _safe_path(path)
    if target is None:
        return 0
    parent = None
    fd = None
    try:
        parent = _open_directory(os.path.dirname(target))
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_CLOEXEC", 0)
        fd = os.open(os.path.basename(target), flags, dir_fd=parent)
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                or info.st_nlink != 1 or info.st_size > 64
                or stat.S_IMODE(info.st_mode) & 0o022):
            return 0
        raw = bytearray()
        while len(raw) <= 64:
            chunk = os.read(fd, min(64, 65 - len(raw)))
            if not chunk:
                break
            raw.extend(chunk)
        if len(raw) > 64:
            return 0
        value = bytes(raw).decode("ascii", "strict").strip()
    except (OSError, UnicodeError):
        return 0
    finally:
        if fd is not None:
            os.close(fd)
        if parent is not None:
            os.close(parent)
    if not PID_RE.fullmatch(value):
        return 0
    pid = int(value)
    return pid if 1 < pid <= 2147483647 else 0


def _proc_start_time(pid):
    try:
        with open("/proc/{0}/stat".format(pid), "r", encoding="ascii") as handle:
            raw = handle.read(8192)
    except (OSError, UnicodeError):
        return 0
    end = raw.rfind(")")
    if end < 0:
        return 0
    fields = raw[end + 2:].split()
    if len(fields) <= 19:
        return 0
    try:
        return int(fields[19])
    except ValueError:
        return 0


def _proc_cmdline(pid):
    try:
        with open("/proc/{0}/cmdline".format(pid), "rb") as handle:
            raw = handle.read(16384)
    except OSError:
        return []
    if not raw or len(raw) >= 16384:
        return []
    return [part.decode("utf-8", "replace") for part in raw.rstrip(b"\0").split(b"\0") if part]


def _proc_exe(pid):
    try:
        return os.path.realpath(os.readlink("/proc/{0}/exe".format(pid)))
    except OSError:
        return ""


def _trusted_file(path):
    try:
        resolved = os.path.realpath(path)
        info = os.stat(resolved)
    except OSError:
        return None
    if (not stat.S_ISREG(info.st_mode) or info.st_uid not in (0, os.geteuid())
            or stat.S_IMODE(info.st_mode) & 0o022 or not os.access(resolved, os.X_OK)):
        return None
    return resolved


def _expected_executable(expected):
    if not isinstance(expected, str) or not expected or len(expected) > 4096:
        return None
    if any(ord(char) < 32 or ord(char) == 127 for char in expected):
        return None
    if os.path.isabs(expected):
        return _trusted_file(expected)
    if "/" in expected:
        return None
    for directory in SYSTEM_BINDIRS:
        candidate = _trusted_file(os.path.join(directory, expected))
        if candidate:
            return candidate
    return None


def verify_process(pid, expected):
    if not isinstance(pid, int) or pid <= 1 or pid > 2147483647:
        return None
    expected_path = _expected_executable(expected)
    if not expected_path:
        return None
    try:
        pidfd = os.pidfd_open(pid, 0)
    except (AttributeError, OSError):
        return None
    try:
        start = _proc_start_time(pid)
        command = _proc_cmdline(pid)
        executable = _proc_exe(pid)
        start_after = _proc_start_time(pid)
        if not start or start != start_after or not command or not executable:
            return None
        if "--daemon" not in command[1:] or len(command) > 64:
            return None
        if executable != expected_path:
            return None
        try:
            process_info = os.stat("/proc/{0}".format(pid))
            executable_info = os.stat(executable)
        except OSError:
            return None
        if process_info.st_uid not in (0, os.geteuid()):
            return None
        if (not stat.S_ISREG(executable_info.st_mode)
                or executable_info.st_uid not in (0, os.geteuid())
                or stat.S_IMODE(executable_info.st_mode) & 0o022):
            return None
        return pidfd, (start, executable, tuple(command))
    except Exception:
        try:
            os.close(pidfd)
        except OSError:
            pass
        return None


def stop_process(pid, expected):
    verified = verify_process(pid, expected)
    if verified is None:
        return 1
    pidfd, identity = verified
    try:
        if not hasattr(signal, "pidfd_send_signal"):
            return 2
        signal.pidfd_send_signal(pidfd, signal.SIGTERM)
    except (ProcessLookupError, OSError):
        return 1
    finally:
        try:
            os.close(pidfd)
        except OSError:
            pass
    return 0


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 3 or args[0] not in ("read", "check", "stop"):
        return 2
    pid = read_pid(args[1])
    if not pid:
        return 1
    if args[0] == "read":
        sys.stdout.write(str(pid) + "\n")
        return 0
    if args[0] == "check":
        verified = verify_process(pid, args[2])
        if verified is None:
            return 1
        os.close(verified[0])
        return 0
    return stop_process(pid, args[2])


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        _error(error)
        raise SystemExit(1)
