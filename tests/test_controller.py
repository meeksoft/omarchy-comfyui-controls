import base64
import hashlib
import json
import importlib.util
import importlib.machinery
import os
import re
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
    def run_status(self, port):
        result = subprocess.run(
            ["python3", str(CONTROLLER), "status", "--host", "127.0.0.1", "--port", str(port)],
            check=True, text=True, capture_output=True,
        )
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

    def test_reports_offline(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
        listener.close()
        self.assertEqual("offline", self.run_status(port)["state"])

    def test_reports_stopped_managed_server_as_crashed(self):
        controller = load_controller()
        with patch.object(controller, "health", return_value=None), \
             patch.object(controller, "port_open", return_value=False), \
             patch.object(controller, "load_state", return_value={"unit": "omarchy-comfyui-test.service"}), \
             patch.object(controller, "owned", return_value=False), \
             patch.object(controller, "log_summary", return_value=[]), \
             patch.object(controller, "journal_summary", return_value=[{"level": "error", "message": "stopped"}]):
            value = controller.status("127.0.0.1", 8188)
        self.assertEqual("crashed", value["state"])
        self.assertEqual("stopped", value["logEvents"][0]["message"])

    def test_does_not_launch_again_while_managed_server_starts(self):
        controller = load_controller()
        args = type("Args", (), {
            "host": "127.0.0.1", "port": 8188, "root": "", "python": "", "log_path": "", "start_timeout": 0,
        })()
        starting = {"ok": True, "state": "offline", "healthy": False, "owned": True,
                    "running": 0, "pending": 0}
        with patch.object(controller, "lock", return_value=nullcontext()), \
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
