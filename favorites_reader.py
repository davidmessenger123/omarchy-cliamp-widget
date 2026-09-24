#!/usr/bin/python3
import errno
import os
import stat
import sys

MAX_BYTES = 256 * 1024


def _error(code, message):
    try:
        sys.stderr.write(str(message)[:256] + "\n")
        sys.stderr.flush()
    except OSError:
        pass
    return code


def _open_directory(path):
    value = os.path.abspath(os.fspath(path))
    if not os.path.isabs(value) or "\x00" in value:
        raise OSError(errno.EINVAL, "invalid directory")
    flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    current = os.open("/", flags)
    try:
        for component in value.split(os.sep)[1:]:
            if not component or component in (".", ".."):
                raise OSError(errno.EINVAL, "invalid directory")
            next_fd = os.open(component, flags, dir_fd=current)
            info = os.fstat(next_fd)
            if not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, os.geteuid()):
                os.close(next_fd)
                raise OSError(errno.EPERM, "unsafe directory")
            mode = stat.S_IMODE(info.st_mode)
            if mode & 0o022 and not (info.st_uid == 0 and mode & 0o1000):
                os.close(next_fd)
                raise OSError(errno.EPERM, "writable directory")
            os.close(current)
            current = next_fd
        return current
    except Exception:
        os.close(current)
        raise


def _same_file(before, after):
    return (before.st_dev == after.st_dev and before.st_ino == after.st_ino
            and before.st_size == after.st_size
            and getattr(before, "st_mtime_ns", int(before.st_mtime * 1000000000))
            == getattr(after, "st_mtime_ns", int(after.st_mtime * 1000000000)))


def read_file(home, path):
    base = os.path.abspath(os.fspath(home))
    target = os.path.abspath(os.fspath(path))
    expected = os.path.abspath(os.path.join(base, ".config", "cliamp", "favorites.toml"))
    if (not os.path.isabs(base) or len(base) > 4096 or "\x00" in base
            or target != expected or os.path.basename(target) != "favorites.toml"):
        raise OSError(errno.EINVAL, "invalid favorites path")
    parent = _open_directory(os.path.dirname(target))
    fd = None
    try:
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_CLOEXEC", 0)
        try:
            fd = os.open(os.path.basename(target), flags, dir_fd=parent)
        except FileNotFoundError:
            raise
        before = os.fstat(fd)
        mode = stat.S_IMODE(before.st_mode)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid()
                or before.st_nlink != 1 or mode & 0o022 or before.st_size > MAX_BYTES):
            raise OSError(errno.EPERM, "unsafe favorites file")
        chunks = []
        size = 0
        while size < before.st_size:
            chunk = os.read(fd, min(65536, before.st_size - size))
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
        if size != before.st_size or not _same_file(before, os.fstat(fd)):
            raise OSError(errno.EAGAIN, "favorites file changed")
        return b"".join(chunks)
    finally:
        if fd is not None:
            os.close(fd)
        os.close(parent)


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 2:
        return _error(2, "usage")
    try:
        data = read_file(args[0], args[1])
    except FileNotFoundError:
        return _error(3, "favorites file is missing")
    except (OSError, ValueError) as error:
        return _error(4, error)
    try:
        view = memoryview(data)
        while view:
            count = os.write(1, view)
            if count <= 0:
                return _error(5, "write failed")
            view = view[count:]
    except OSError as error:
        return _error(5, error)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
