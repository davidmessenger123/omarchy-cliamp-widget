import json
import os
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import bounded_process
import favorites_reader
import process_guard


class ExecutableResolutionTests(unittest.TestCase):
    def test_bare_name_resolves_through_system_bindirs(self):
        candidates = ["true", "env", "sh", "ls"]
        resolved = None
        for name in candidates:
            resolved = bounded_process.resolve_executable(name)
            if resolved:
                break
        if not resolved:
            self.skipTest("no trusted system binary available to resolve")
        result = subprocess.run(
            [
                sys.executable,
                os.path.join(os.path.dirname(__file__), "..", "bounded_process.py"),
                "run",
                "--timeout",
                "5",
                "--",
                resolved,
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_system_bindir_candidate_must_be_root_owned(self):
        with tempfile.TemporaryDirectory() as directory:
            candidate = os.path.join(directory, "cliamp")
            with open(candidate, "w", encoding="ascii") as handle:
                handle.write("#!/bin/sh\nexit 0\n")
            os.chmod(candidate, 0o755)
            with mock.patch.object(bounded_process, "SYSTEM_BINDIRS", (directory,)):
                self.assertIsNone(bounded_process.resolve_executable("cliamp"))

    def test_system_bindir_candidate_accepts_root_owner(self):
        with tempfile.TemporaryDirectory() as directory:
            candidate = os.path.join(directory, "cliamp")
            with open(candidate, "w", encoding="ascii") as handle:
                handle.write("#!/bin/sh\nexit 0\n")
            os.chmod(candidate, 0o755)
            real = os.stat(candidate)

            class RootOwned:
                st_mode = real.st_mode
                st_uid = 0

            with mock.patch.object(bounded_process, "SYSTEM_BINDIRS", (directory,)), \
                 mock.patch.object(bounded_process.os, "stat", return_value=RootOwned()):
                self.assertEqual(
                    bounded_process.resolve_executable("cliamp"),
                    os.path.realpath(candidate),
                )

    def test_embedded_slash_in_name_is_refused(self):
        self.assertIsNone(bounded_process.resolve_executable("bin/cliamp"))
        self.assertIsNone(bounded_process.resolve_executable("./cliamp"))


class SessionEnvironmentTests(unittest.TestCase):
    def _socket(self, directory, name, mtime):
        path = os.path.join(directory, name)
        handle = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            handle.bind(path)
        finally:
            handle.close()
        os.utime(path, (mtime, mtime))
        return path

    def test_display_vars_reach_terminal_but_not_the_ipc_child(self):
        environ = {
            "PATH": "/usr/bin",
            "HOME": "/home/tester",
            "XDG_RUNTIME_DIR": "/run/user/1000",
            "WAYLAND_DISPLAY": "wayland-7",
            "HYPRLAND_INSTANCE_SIGNATURE": "sig",
            "OMARCHY_PATH": "/usr/share/omarchy",
        }
        with mock.patch.dict(bounded_process.os.environ, environ, clear=True):
            child = bounded_process._child_environment()
            session = bounded_process._session_environment()
        for name in ("WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "OMARCHY_PATH"):
            self.assertNotIn(name, child)
            self.assertEqual(session[name], environ[name])

    def test_wayland_display_recovered_from_runtime_dir(self):
        with tempfile.TemporaryDirectory() as directory:
            self._socket(directory, "wayland-2", 1000)
            self._socket(directory, "wayland-5", 5000)
            self.assertEqual(bounded_process._newest_wayland_socket(directory), "wayland-5")
            with open(os.path.join(directory, "wayland-9"), "w", encoding="ascii") as handle:
                handle.write("")
            os.utime(os.path.join(directory, "wayland-9"), (9000, 9000))
            self.assertEqual(bounded_process._newest_wayland_socket(directory), "wayland-5")

    def test_wayland_display_recovered_when_unset(self):
        with tempfile.TemporaryDirectory() as directory:
            self._socket(directory, "wayland-3", 1000)
            environ = {"PATH": "/usr/bin", "HOME": "/home/tester", "XDG_RUNTIME_DIR": directory}
            with mock.patch.dict(bounded_process.os.environ, environ, clear=True):
                self.assertEqual(bounded_process._session_environment()["WAYLAND_DISPLAY"], "wayland-3")

    def test_launch_terminal_passes_the_session_environment(self):
        environ = {
            "PATH": "/usr/bin",
            "HOME": "/home/tester",
            "XDG_RUNTIME_DIR": "/run/user/1000",
            "WAYLAND_DISPLAY": "wayland-4",
        }

        def resolve(value):
            return "/usr/bin/" + value

        with mock.patch.dict(bounded_process.os.environ, environ, clear=True), \
             mock.patch.object(bounded_process, "resolve_executable", side_effect=resolve), \
             mock.patch.object(bounded_process.subprocess, "Popen") as popen:
            popen.return_value.pid = 4321
            self.assertEqual(bounded_process.launch_terminal(["cliamp"]), 0)
        env = popen.call_args.kwargs["env"]
        self.assertEqual(
            popen.call_args.args[0],
            ["/usr/bin/omarchy-launch-terminal", "/usr/bin/cliamp"],
        )
        self.assertEqual(env["WAYLAND_DISPLAY"], "wayland-4")


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


class StderrForwardingTests(unittest.TestCase):
    BRIDGE = os.path.join(os.path.dirname(__file__), "..", "bounded_process.py")

    def _script(self, body):
        handle = tempfile.NamedTemporaryFile("w", suffix=".py", delete=False)
        handle.write(body)
        handle.close()
        self.addCleanup(os.unlink, handle.name)
        return handle.name

    def _run(self, mode, script, extra=()):
        return subprocess.run(
            [sys.executable, self.BRIDGE, mode, "--timeout", "15", *extra, "--",
             sys.executable, script],
            capture_output=True,
            text=True,
            timeout=30,
        )

    def test_child_stderr_reaches_the_bridge_stderr(self):
        script = self._script(
            "import sys\n"
            "sys.stderr.write('complaint-one\\n')\n"
            "sys.stdout.write('{\\\"ok\\\":1}\\n')\n"
        )
        result = self._run("run", script)
        self.assertEqual(result.returncode, 0)
        self.assertIn("complaint-one", result.stderr)
        self.assertNotIn("complaint-one", result.stdout)
        self.assertEqual(result.stdout.strip(), '{"ok":1}')

    def test_stderr_is_capped_and_never_deadlocks_the_child(self):
        script = self._script(
            "import sys\n"
            "for i in range(200000):\n"
            "    sys.stderr.write('x' * 100 + '\\n')\n"
            "sys.stderr.write('Z' * 200000)\n"
            "sys.stdout.write('done\\n')\n"
        )
        result = self._run("stream", script)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "done")
        self.assertLessEqual(len(result.stderr), bounded_process.MAX_STDERR_TOTAL)
        longest = max((len(line) for line in result.stderr.splitlines()), default=0)
        self.assertLessEqual(longest, bounded_process.MAX_STDERR_LINE)

    def test_stream_and_run_both_forward(self):
        script = self._script("import sys\nsys.stderr.write('via-stderr\\n')\n")
        for mode in ("stream", "run"):
            with self.subTest(mode=mode):
                result = self._run(mode, script)
                self.assertEqual(result.returncode, 0)
                self.assertIn("via-stderr", result.stderr)


if __name__ == "__main__":
    unittest.main()
