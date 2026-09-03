import json
import importlib.util
import importlib.machinery
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
