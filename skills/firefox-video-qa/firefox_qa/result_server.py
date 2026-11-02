from __future__ import annotations

import hmac
import os
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import TracebackType
from typing import ClassVar, Final, Self, final, override

from .page_result import ResultError, parse_page_result_bytes

DEFAULT_MAX_BODY: Final = 1_048_576


@final
class _ServerState:
    __slots__: ClassVar[tuple[str, ...]] = (
        "lock",
        "max_body",
        "mode",
        "received",
        "result_path",
        "root",
        "scenario_id",
        "token",
    )
    root: Path
    result_path: Path
    token: str
    scenario_id: str
    mode: str
    max_body: int
    lock: threading.Lock
    received: threading.Event

    def __init__(
        self,
        root: Path,
        result_path: Path,
        token: str,
        scenario_id: str,
        mode: str,
        max_body: int,
    ) -> None:
        self.root = root
        self.result_path = result_path
        self.token = token
        self.scenario_id = scenario_id
        self.mode = mode
        self.max_body = max_body
        self.lock = threading.Lock()
        self.received = threading.Event()


@final
class _ResultHttpServer(ThreadingHTTPServer):
    state: _ServerState

    def __init__(self, state: _ServerState) -> None:
        self.state = state
        super().__init__(("127.0.0.1", 0), _Handler)


@final
class _Handler(BaseHTTPRequestHandler):
    def _state(self) -> _ServerState:
        if not isinstance(self.server, _ResultHttpServer):
            raise RuntimeError
        return self.server.state

    @override
    def log_message(self, format: str, *_args: str) -> None:
        _ = format

    def do_GET(self) -> None:
        relative = self.path.split("?", 1)[0].lstrip("/")
        if relative not in {"video-qa.html", "telemetry.js", "media"}:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        path = self._state().root / relative
        if not path.is_file() or path.is_symlink():
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        content_type = "text/html" if relative.endswith(".html") else "application/javascript"
        if relative == "media":
            content_type = "application/octet-stream"
        body = path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        _ = self.wfile.write(body)

    def do_POST(self) -> None:
        state = self._state()
        if self.path != f"/result/{state.token}" or not hmac.compare_digest(
            self.path.rsplit("/", 1)[-1], state.token
        ):
            self.send_error(HTTPStatus.FORBIDDEN)
            return
        if self.headers.get_content_type() != "application/json":
            self.send_error(HTTPStatus.UNSUPPORTED_MEDIA_TYPE)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_error(HTTPStatus.BAD_REQUEST)
            return
        if length <= 0 or length > state.max_body:
            self.send_error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
            return
        payload = self.rfile.read(length)
        try:
            result = parse_page_result_bytes(payload)
        except ResultError:
            self.send_error(HTTPStatus.BAD_REQUEST)
            return
        if (
            not hmac.compare_digest(result.run_token, state.token)
            or result.scenario_id != state.scenario_id
            or result.mode.value != state.mode
        ):
            self.send_error(HTTPStatus.FORBIDDEN)
            return
        with state.lock:
            try:
                descriptor = os.open(state.result_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            except FileExistsError:
                self.send_error(HTTPStatus.CONFLICT)
                return
            with os.fdopen(descriptor, "wb") as handle:
                _ = handle.write(payload + b"\n")
                handle.flush()
                os.fsync(handle.fileno())
            state.received.set()
        self.send_response(HTTPStatus.NO_CONTENT)
        self.end_headers()


@final
class ResultServer:
    _server: _ResultHttpServer
    _thread: threading.Thread

    def __init__(
        self,
        root: Path,
        result_path: Path,
        token: str,
        scenario_id: str,
        mode: str,
        max_body: int = DEFAULT_MAX_BODY,
    ) -> None:
        state = _ServerState(root, result_path, token, scenario_id, mode, max_body)
        self._server = _ResultHttpServer(state)
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)

    @property
    def port(self) -> int:
        return int(self._server.server_port)

    def __enter__(self) -> Self:
        self._thread.start()
        return self

    def wait_result(self, timeout: float) -> bool:
        return self._server.state.received.wait(timeout)

    def __exit__(
        self,
        _exception_type: type[BaseException] | None,
        _exception: BaseException | None,
        _traceback: TracebackType | None,
    ) -> None:
        self._server.shutdown()
        self._server.server_close()
        self._thread.join()
