import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import favorites_reader
import process_guard


class ProcessBoundaryTests(unittest.TestCase):
    def test_no_newline_output_is_capped_before_line_buffering(self):
        result = subprocess.run(
            [
                sys.executable,
                os.path.join(os.path.dirname(__file__), "..", "bounded_process.py"),
                "stream",
                "--max-line",
                "256",
                "--",
                sys.executable,
                "-c",
                "import sys; sys.stdout.write('x' * 1000)",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(result.returncode, 125)
        self.assertLess(len(result.stdout), 1000)
        self.assertEqual(json.loads(result.stdout.strip())["error"], "output line too long")

    def test_run_output_is_capped(self):
        result = subprocess.run(
            [
                sys.executable,
                os.path.join(os.path.dirname(__file__), "..", "bounded_process.py"),
                "run",
                "--max-output",
                "32",
                "--timeout",
                "5",
                "--",
                sys.executable,
                "-c",
                "import sys; sys.stdout.write('x' * 1000)",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertLessEqual(len(result.stdout), 32)

    def test_pid_file_is_bounded_and_path_checked(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, ".config", "cliamp", "cliamp.sock.pid")
            os.makedirs(os.path.dirname(path), mode=0o700)
            with open(path, "w", encoding="ascii") as handle:
                handle.write(str(os.getpid()))
            self.assertEqual(process_guard.read_pid(path), os.getpid())
            with open(path, "w", encoding="ascii") as handle:
                handle.write("1x")
            self.assertEqual(process_guard.read_pid(path), 0)
            self.assertEqual(process_guard.read_pid(os.path.join(directory, "other.pid")), 0)

    def test_favorites_reader_rejects_symlink_fifo_and_oversize(self):
        with tempfile.TemporaryDirectory() as directory:
            home = os.path.join(directory, "home")
            target_dir = os.path.join(home, ".config", "cliamp")
            os.makedirs(target_dir, mode=0o700)
            target = os.path.join(target_dir, "favorites.toml")
            with open(target, "w", encoding="utf-8") as handle:
                handle.write("[[entry]]\n")
            self.assertEqual(favorites_reader.read_file(home, target), b"[[entry]]\n")
            link = os.path.join(target_dir, "link.toml")
            os.symlink(target, link)
            with self.assertRaises(OSError):
                favorites_reader.read_file(home, link)
            os.unlink(target)
            os.mkfifo(target)
            with self.assertRaises(OSError):
                favorites_reader.read_file(home, target)
            os.unlink(target)
            with open(target, "wb") as handle:
                handle.write(b"x" * (favorites_reader.MAX_BYTES + 1))
            with self.assertRaises(OSError):
                favorites_reader.read_file(home, target)

    def test_process_identity_must_be_cliamp_daemon(self):
        self.assertIsNone(process_guard.verify_process(os.getpid(), "python3"))

    def test_stop_uses_pidfd_signal_only(self):
        read_fd, write_fd = os.pipe()
        try:
            with mock.patch.object(process_guard, "verify_process", return_value=(write_fd, (1, "/usr/bin/cliamp", ("cliamp", "--daemon")))), \
                 mock.patch.object(process_guard.signal, "pidfd_send_signal", create=True) as send, \
                 mock.patch.object(process_guard.os, "kill") as kill:
                self.assertEqual(process_guard.stop_process(os.getpid(), "cliamp"), 0)
                send.assert_called_once()
                kill.assert_not_called()
        finally:
            os.close(read_fd)


if __name__ == "__main__":
    unittest.main()
