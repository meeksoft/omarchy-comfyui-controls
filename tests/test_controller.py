import base64
import hashlib
import json
import importlib.util
import importlib.machinery
import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest
from contextlib import nullcontext
from unittest.mock import patch


CONTROLLER = Path(__file__).parents[1] / "bin" / "comfyui-control"


def load_controller():
    loader = importlib.machinery.SourceFileLoader("comfyui_control", str(CONTROLLER))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class ComfyHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/system_stats":
            self.reply({"system": {"comfyui_version": "test"}, "devices": []})
        elif self.path == "/queue":
            self.reply({"queue_running": [], "queue_pending": [[1]]})
        elif self.path.startswith("/history"):
            self.reply({"prompt": {"outputs": {"node": {"images": [
                {"filename": "result.png", "subfolder": "", "type": "output"}
            ]}}}})
        else:
            self.send_error(404)

    def reply(self, value):
        body = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


class SlowComfyHandler(ComfyHandler):
    """Answers /system_stats slower than the first status probe but in time for the retry."""

    def do_GET(self):
        if self.path == "/system_stats":
            time.sleep(2.0)
            self.reply({"system": {"comfyui_version": "test"}, "devices": []})
        elif self.path == "/queue":
            self.reply({"queue_running": [], "queue_pending": []})
        elif self.path.startswith("/history"):
            self.reply({})
        else:
            self.send_error(404)


class JobsApiHandler(ComfyHandler):
    """Serves the /api/jobs endpoint and a /queue carrying node details."""

    def do_GET(self):
        if self.path.startswith("/api/jobs"):
            self.reply({"jobs": [
                {"id": "aaaaaaaa-1111-1111-1111-111111111111", "status": "in_progress",
                 "priority": 7, "create_time": 1000, "execution_start_time": 2000},
                {"id": "bbbbbbbb-2222-2222-2222-222222222222", "status": "pending",
                 "priority": 8, "create_time": 1500},
            ], "pagination": {}})
        elif self.path == "/queue":
            self.reply({"queue_running": [[7, "aaaaaaaa-1111-1111-1111-111111111111",
                                           {"n1": {}, "n2": {}}, {}, ["o1", "o2"]]],
                        "queue_pending": []})
        else:
            ComfyHandler.do_GET(self)


class QuietHTTPServer(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        pass


WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class FakeComfySocket:
    """Minimal /ws endpoint that stays silent, then pings before sending any events."""

    def __init__(self, idle_before_ping=0.0):
        self.listener = socket.create_server(("127.0.0.1", 0))
        self.pongs = []
        self.idle_before_ping = idle_before_ping

    @property
    def port(self):
        return self.listener.getsockname()[1]

    def serve(self):
        connection, _ = self.listener.accept()
        with connection:
            connection.settimeout(10)
            request = bytearray()
            while b"\r\n\r\n" not in request:
                request.extend(connection.recv(4096))
            key = re.search(rb"Sec-WebSocket-Key: (\S+)", bytes(request)).group(1)
            accept = base64.b64encode(hashlib.sha1(key + WEBSOCKET_GUID.encode()).digest())
            connection.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                               b"Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
            time.sleep(self.idle_before_ping)
            connection.sendall(b"\x89\x04ping")
            header = self.receive(connection, 2)
            if header[0] & 0x0F == 0x0A:
                self.pongs.append(self.receive(connection, header[1] & 0x7F))
            payload = json.dumps({"type": "status", "data": {"status": {"exec_info": {"queue_remaining": 1}}}}).encode()
            connection.sendall(bytes((0x81, len(payload))) + payload)
            connection.sendall(b"\x88\x00")
        self.listener.close()

    @staticmethod
    def receive(connection, count):
        result = bytearray()
        while len(result) < count:
            part = connection.recv(count - len(result))
            if not part:
                raise ConnectionError("client closed")
            result.extend(part)
        return bytes(result)


class ControllerTests(unittest.TestCase):
    def run_status(self, port, extra=None):
        command = ["python3", str(CONTROLLER), "status", "--host", "127.0.0.1", "--port", str(port)]
        command.extend(extra or [])
        result = subprocess.run(command, check=True, text=True, capture_output=True)
        return json.loads(result.stdout)

    def test_reports_comfyui_queue_and_preview(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), ComfyHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            value = self.run_status(server.server_port)
            self.assertEqual("queued", value["state"])
            self.assertEqual(1, value["pending"])
            self.assertEqual("test", value["version"])
            self.assertIn("/view?", value["previewUrl"])
            self.assertEqual("result.png", value["outputs"][0]["filename"])
            self.assertEqual("image", value["outputs"][0]["mediaKind"])
        finally:
            server.shutdown()
            server.server_close()

    def test_reports_foreign_listener(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        try:
            self.assertEqual("foreign-port", self.run_status(listener.getsockname()[1])["state"])
        finally:
            listener.close()

    def test_jobs_api_enriches_running_job(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), JobsApiHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            value = self.run_status(server.server_port)
            self.assertEqual("generating", value["state"])
            self.assertEqual(1, value["running"])
            self.assertEqual(1, value["pending"])
            job = value["jobs"][0]
            self.assertEqual("running", job["state"])
            self.assertEqual(2, job["nodeCount"])
            self.assertEqual(2, job["outputNodeCount"])
            self.assertEqual(2000, job["startedAt"])
            self.assertEqual("aaaaaaaa", job["promptId"][:8])
            self.assertEqual(1, value["jobs"][1]["position"])
        finally:
            server.shutdown()
            server.server_close()

    def test_light_status_reports_queue_without_payload(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), ComfyHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            value = self.run_status(server.server_port, ["--light"])
            self.assertEqual("queued", value["state"])
            self.assertTrue(value["healthy"])
            self.assertEqual(1, value["pending"])
            self.assertEqual("test", value["version"])
            for key in ("jobs", "outputs", "previewUrl", "recentEvents", "logEvents"):
                self.assertNotIn(key, value)
        finally:
            server.shutdown()
            server.server_close()

    def test_light_status_marks_occupied_and_skips_log_summaries(self):
        controller = load_controller()
        with tempfile.TemporaryDirectory() as base, \
             patch.dict(controller.os.environ, {"XDG_STATE_HOME": base}), \
             patch.object(controller, "health", return_value=None), \
             patch.object(controller, "port_open", return_value=True), \
             patch.object(controller, "owned", return_value=True), \
             patch.object(controller, "log_summary", return_value=[]) as logs, \
             patch.object(controller, "journal_summary", return_value=[]) as journal:
            value = controller.status("127.0.0.1", 8188, "", True)
        logs.assert_not_called()
        journal.assert_not_called()
        self.assertEqual("starting", value["state"])
        self.assertFalse(value["healthy"])
        self.assertTrue(value["occupied"])
        self.assertTrue(value["owned"])
        self.assertNotIn("logEvents", value)

    def test_parse_progress_uses_last_tqdm_chunk(self):
        controller = load_controller()
        text = " 25%|##| 10/40 [00:02<00:06, 5.00it/s]\r 50%|##| 20/40 [00:03<00:04, 5.00it/s]"
        self.assertEqual({"value": 20, "max": 40, "etaSeconds": 4}, controller.parse_progress(text))

    def test_parse_progress_derives_eta_from_rate_without_estimate(self):
        controller = load_controller()
        self.assertEqual(145, controller.parse_progress("  3%|   | 1/30 [00:05, 5.00s/it]")["etaSeconds"])

    def test_parse_progress_matches_unicode_bar_chunks(self):
        controller = load_controller()
        text = " 92%|████████████████████████████████████████| 37/40 [11:17<00:55, 18.52s/it]"
        self.assertEqual({"value": 37, "max": 40, "etaSeconds": 55}, controller.parse_progress(text))

    def test_parse_progress_accepts_unknown_rate_bars(self):
        controller = load_controller()
        text = "  0%|          | 0/40 [00:00<?, ?it/s]"
        self.assertEqual({"value": 0, "max": 40, "etaSeconds": -1}, controller.parse_progress(text))

    def test_log_progress_reads_fresh_file_and_ignores_stale(self):
        controller = load_controller()
        with tempfile.TemporaryDirectory() as base:
            with patch.dict(controller.os.environ, {"XDG_STATE_HOME": base}):
                log = controller.server_log_path("127.0.0.1", 8188)
                log.parent.mkdir(parents=True, exist_ok=True)
                log.write_text(" 50%|##| 20/40 [00:03<00:04, 5.00it/s]\n")
                self.assertEqual(20, controller.log_progress("127.0.0.1", 8188)["value"])
                stale = time.time() - 300
                os.utime(log, (stale, stale))
                self.assertIsNone(controller.log_progress("127.0.0.1", 8188))

    def test_reports_offline(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
        listener.close()
        self.assertEqual("offline", self.run_status(port)["state"])

    def test_reports_stopped_managed_server_as_crashed(self):
        controller = load_controller()
        # Isolated for the same reason as the clean-stop case: stale_unit can
        # unlink the real state file for this host and port.
        with tempfile.TemporaryDirectory() as base, \
             patch.dict(controller.os.environ, {"XDG_STATE_HOME": base}), \
             patch.object(controller, "health", return_value=None), \
             patch.object(controller, "port_open", return_value=False), \
             patch.object(controller, "load_state", return_value={"unit": "omarchy-comfyui-test.service", "boot": "boot-1"}), \
             patch.object(controller, "unit_result", return_value="exit-code"), \
             patch.object(controller, "current_boot", return_value="boot-1"), \
             patch.object(controller, "owned", return_value=False), \
             patch.object(controller, "log_summary", return_value=[]), \
             patch.object(controller, "journal_summary", return_value=[{"level": "error", "message": "stopped"}]):
            value = controller.status("127.0.0.1", 8188)
        self.assertEqual("crashed", value["state"])
        self.assertEqual("stopped", value["logEvents"][0]["message"])

    def test_rebooted_server_reads_offline_and_clears_state(self):
        controller = load_controller()
        with tempfile.TemporaryDirectory() as base:
            with patch.dict(controller.os.environ, {"XDG_STATE_HOME": base}):
                controller.save_state("127.0.0.1", 8189, "omarchy-comfyui-old.service")
                with patch.object(controller, "health", return_value=None), \
                     patch.object(controller, "port_open", return_value=False), \
                     patch.object(controller, "current_boot", return_value="boot-2"), \
                     patch.object(controller, "owned", return_value=False), \
                     patch.object(controller, "log_summary", return_value=[]), \
                     patch.object(controller, "journal_summary", return_value=[]):
                    value = controller.status("127.0.0.1", 8189)
                self.assertEqual("offline", value["state"])
                self.assertFalse(controller.state_path("127.0.0.1", 8189).exists())

    def test_running_unit_keeps_its_ownership_record(self):
        """Regression: systemd reports Result=success for a service that is
        still running, so classifying on Result alone cleared the state file
        of a server seconds after starting it — and the panel gates Stop on
        that record, so Stop never appeared for a server it had started."""
        controller = load_controller()
        with tempfile.TemporaryDirectory() as base:
            with patch.dict(controller.os.environ, {"XDG_STATE_HOME": base}):
                controller.save_state("127.0.0.1", 8190, "omarchy-comfyui-live.service")
                with patch.object(controller, "unit_active", return_value=True), \
                     patch.object(controller, "unit_result", return_value="success"), \
                     patch.object(controller, "current_boot", return_value=controller.current_boot()):
                    self.assertIsNone(controller.stale_unit("127.0.0.1", 8190))
                    self.assertTrue(controller.state_path("127.0.0.1", 8190).exists())
                    self.assertTrue(controller.owned("127.0.0.1", 8190))

    def test_stops_a_server_it_did_not_start(self):
        """An unowned but healthy loopback server is stopped by signalling the
        process holding its port, rather than refused."""
        controller = load_controller()
        with tempfile.TemporaryDirectory() as base:
            with patch.dict(controller.os.environ, {"XDG_STATE_HOME": base}):
                with patch.object(controller, "health", return_value={"version": "0.34"}), \
                     patch.object(controller, "listener_pid", return_value=4321) as resolved, \
                     patch.object(controller, "terminate", return_value=True) as killed:
                    value = controller.stop("127.0.0.1", 8188)
                resolved.assert_called_once_with("127.0.0.1", 8188)
                killed.assert_called_once_with(4321)
        self.assertTrue(value["ok"])
        self.assertEqual("offline", value["state"])

    def test_refuses_to_stop_a_port_that_is_not_comfyui(self):
        controller = load_controller()
        with tempfile.TemporaryDirectory() as base:
            with patch.dict(controller.os.environ, {"XDG_STATE_HOME": base}):
                with patch.object(controller, "health", return_value=None), \
                     patch.object(controller, "terminate") as killed:
                    value = controller.stop("127.0.0.1", 8188)
                killed.assert_not_called()
        self.assertFalse(value["ok"])
        self.assertEqual("unowned", value["state"])

    def test_refuses_to_stop_a_remote_server(self):
        controller = load_controller()
        with tempfile.TemporaryDirectory() as base:
            with patch.dict(controller.os.environ, {"XDG_STATE_HOME": base}):
                with patch.object(controller, "terminate") as killed:
                    value = controller.stop("192.168.1.50", 8188)
                killed.assert_not_called()
        self.assertFalse(value["ok"])
        self.assertEqual("unowned", value["state"])

    def test_cleanly_stopped_server_reads_offline(self):
        controller = load_controller()
        # Redirect XDG_STATE_HOME: stale_unit unlinks the state file for this
        # host and port, and the default 127.0.0.1:8188 is the one a real
        # install uses, so an unredirected run deletes the user's own
        # ownership record and silently un-owns their running server.
        with tempfile.TemporaryDirectory() as base, \
             patch.dict(controller.os.environ, {"XDG_STATE_HOME": base}), \
             patch.object(controller, "health", return_value=None), \
             patch.object(controller, "port_open", return_value=False), \
             patch.object(controller, "load_state", return_value={"unit": "omarchy-comfyui-test.service", "boot": "boot-1"}), \
             patch.object(controller, "unit_result", return_value="success"), \
             patch.object(controller, "current_boot", return_value="boot-1"), \
             patch.object(controller, "owned", return_value=False), \
             patch.object(controller, "log_summary", return_value=[]), \
             patch.object(controller, "journal_summary", return_value=[]):
            value = controller.status("127.0.0.1", 8188)
        self.assertEqual("offline", value["state"])

    def test_save_state_records_boot_id(self):
        controller = load_controller()
        with tempfile.TemporaryDirectory() as base:
            with patch.dict(controller.os.environ, {"XDG_STATE_HOME": base}), \
                 patch.object(controller, "current_boot", return_value="boot-42"):
                controller.save_state("127.0.0.1", 8187, "omarchy-comfyui-x.service")
                self.assertEqual("boot-42", controller.load_state("127.0.0.1", 8187)["boot"])

    def test_python_for_keeps_venv_entrypoint_not_symlink_target(self):
        controller = load_controller()
        with tempfile.TemporaryDirectory() as base:
            root = Path(base) / "comfyui"
            root.mkdir()
            bin_dir = Path(base) / "venv" / "bin"
            bin_dir.mkdir(parents=True)
            venv_python = bin_dir / "python"
            venv_python.symlink_to(Path(sys.executable))
            self.assertEqual(venv_python, controller.python_for(root, ""))
            self.assertNotEqual(Path(sys.executable), controller.python_for(root, ""))

    def test_python_for_prefers_configured_interpreter(self):
        controller = load_controller()
        with tempfile.TemporaryDirectory() as base:
            root = Path(base) / "comfyui"
            root.mkdir()
            wrapper = Path(base) / "wrapper-python"
            wrapper.write_text("#!/bin/sh\nexec python3 \"$@\"\n")
            wrapper.chmod(0o755)
            self.assertEqual(wrapper, controller.python_for(root, str(wrapper)))

    def test_does_not_launch_again_while_managed_server_starts(self):
        controller = load_controller()
        args = type("Args", (), {
            "host": "127.0.0.1", "port": 8188, "root": "", "python": "", "log_path": "", "start_timeout": 0,
        })()
        starting = {"ok": True, "state": "offline", "healthy": False, "owned": True,
                    "running": 0, "pending": 0}
        with tempfile.TemporaryDirectory() as base, \
             patch.dict(controller.os.environ, {"XDG_STATE_HOME": base}), \
             patch.object(controller, "lock", return_value=nullcontext()), \
             patch.object(controller, "status", return_value=starting), \
             patch.object(controller.subprocess, "run") as run:
            result = controller.start(args)
        self.assertEqual("starting", result["state"])
        run.assert_not_called()

    def test_slow_server_is_not_reported_as_foreign_port(self):
        server = QuietHTTPServer(("127.0.0.1", 0), SlowComfyHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            self.assertEqual("idle", self.run_status(server.server_port)["state"])
        finally:
            server.shutdown()
            server.server_close()

    def test_runtime_dir_places_locks_in_plugin_subdirectory(self):
        controller = load_controller()
        with tempfile.TemporaryDirectory() as base:
            with patch.dict(controller.os.environ, {"XDG_RUNTIME_DIR": base}):
                self.assertEqual(Path(base) / "comfyui-control", controller.data_dir(True))

    def test_runtime_dir_falls_back_to_private_tmp_subdirectory(self):
        controller = load_controller()
        with patch.dict(controller.os.environ, {}, clear=True):
            expected = Path(f"/tmp/comfyui-control-{os.getuid()}") / "comfyui-control"
            self.assertEqual(expected, controller.data_dir(True))

    def test_watch_answers_pings_after_idle_silence(self):
        fake = FakeComfySocket(idle_before_ping=5.5)
        thread = threading.Thread(target=fake.serve, daemon=True)
        thread.start()
        try:
            result = subprocess.run(
                ["python3", str(CONTROLLER), "watch", "--host", "127.0.0.1", "--port", str(fake.port)],
                text=True, capture_output=True, timeout=20,
            )
        finally:
            thread.join(timeout=5)
        self.assertEqual(0, result.returncode)
        self.assertEqual([b"ping"], fake.pongs)
        self.assertIn('"type":"status"', result.stdout)

    def test_log_summary_strips_terminal_noise_and_duplicates(self):
        controller = load_controller()
        with tempfile.NamedTemporaryFile("w", encoding="utf-8") as log:
            log.write("\x1b[31m[ERROR] failed node\x1b[0m\n")
            log.write("\x1b[31m[ERROR] failed node\x1b[0m\n")
            log.write("50%|#####| 20/40 [00:03<00:03]\n")
            log.write("[INFO] Prompt executed in 3.2 seconds\n")
            log.flush()
            events = controller.log_summary(log.name)
        self.assertEqual(2, len(events))
        self.assertFalse(any("\x1b" in event["message"] for event in events))
        self.assertFalse(any("20/40" in event["message"] for event in events))


if __name__ == "__main__":
    unittest.main()
