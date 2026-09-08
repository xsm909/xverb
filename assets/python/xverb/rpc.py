"""Minimal JSON-RPC 2.0 peer speaking newline-delimited JSON over stdio.

One JSON object per line. stdout carries protocol traffic only — anything a
plugin prints there will look like a malformed message to the host, so use
``Plugin.log`` (or stderr) instead.
"""

from __future__ import annotations

import json
import queue
import sys
import threading
from typing import Any, Callable, Dict, Optional

PARSE_ERROR = -32700
METHOD_NOT_FOUND = -32601
INTERNAL_ERROR = -32603


class RpcError(Exception):
    """Raised to return a structured error to the caller."""

    def __init__(self, message: str, code: int = INTERNAL_ERROR, data: Any = None):
        super().__init__(message)
        self.message = message
        self.code = code
        self.data = data


class _Pending:
    """One call waiting for its answer."""

    __slots__ = ("done", "value", "error")

    def __init__(self) -> None:
        self.done = threading.Event()
        self.value: Any = None
        self.error: Optional[RpcError] = None

    def settle(self, value: Any = None, error: Optional[RpcError] = None) -> None:
        self.value = value
        self.error = error
        self.done.set()

    def result(self) -> Any:
        self.done.wait()
        if self.error is not None:
            raise self.error
        return self.value


class RpcPeer:
    """Serves requests from the host and can call back into it.

    Requests are handled **one at a time**, on a worker of their own, so a
    plugin author still never has to think about two handlers running at once.
    The reason there is a worker at all is that the alternative — dispatching
    on the thread that reads stdin — makes it impossible for a handler to ask
    the host anything: it would be waiting for an answer that only its own
    thread could deliver.

    That separation is also what lets a plugin start a background thread of its
    own and go on talking to the host from it, which is what a view that scans
    something large needs: it answers at once and pushes the rest as it finds
    it. Calls from any thread are safe; writes are serialised.
    """

    def __init__(self, stdin=None, stdout=None):
        self._stdin = stdin or sys.stdin
        self._stdout = stdout or sys.stdout
        self._handlers: Dict[str, Callable[[dict], Any]] = {}
        self._next_id = 1
        self._running = False
        self._write_lock = threading.Lock()
        self._id_lock = threading.Lock()
        self._pending: Dict[Any, _Pending] = {}
        self._pending_lock = threading.Lock()
        self._work: "queue.Queue[Optional[dict]]" = queue.Queue()

    def register(self, method: str, handler: Callable[[dict], Any]) -> None:
        self._handlers[method] = handler

    def notify(self, method: str, params: Optional[dict] = None) -> None:
        """Sends a message the host will not answer. Safe from any thread."""
        self._write({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def call(self, method: str, params: Optional[dict] = None) -> Any:
        """Calls a host method and waits for its reply.

        Safe from inside a request handler and from a thread of your own. The
        one place it is not safe is a shutdown hook: the host is already on its
        way out and answers nothing more.
        """
        with self._id_lock:
            request_id = self._next_id
            self._next_id += 1

        waiting = _Pending()
        with self._pending_lock:
            self._pending[request_id] = waiting

        try:
            self._write(
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "method": method,
                    "params": params or {},
                }
            )
        except Exception:
            with self._pending_lock:
                self._pending.pop(request_id, None)
            raise

        try:
            return waiting.result()
        finally:
            with self._pending_lock:
                self._pending.pop(request_id, None)

    def stop(self) -> None:
        self._running = False

    def serve_forever(self) -> None:
        """Reads the host's messages until it stops sending them."""
        self._running = True
        worker = threading.Thread(target=self._serve_queue, daemon=True)
        worker.start()

        try:
            while self._running:
                message = self._read()
                if message is None:
                    break

                if "method" not in message:
                    self._settle(message)
                    continue

                # Shutdown is answered on the spot rather than queued behind
                # work that is about to be thrown away — the host waits three
                # seconds for it and then kills the process.
                if message.get("method") == "shutdown":
                    self._dispatch(message)
                    break

                self._work.put(message)
        finally:
            self._running = False
            self._work.put(None)
            self._fail_pending("Host closed the connection")

    # -- internals ---------------------------------------------------------

    def _serve_queue(self) -> None:
        while True:
            message = self._work.get()
            if message is None:
                return
            self._dispatch(message)

    def _settle(self, message: dict) -> None:
        with self._pending_lock:
            waiting = self._pending.get(message.get("id"))
        if waiting is None:
            # A reply to a call nobody is waiting for any more.
            return
        if "error" in message:
            failure = message["error"] or {}
            waiting.settle(
                error=RpcError(
                    failure.get("message", "Unknown host error"),
                    failure.get("code", INTERNAL_ERROR),
                )
            )
        else:
            waiting.settle(message.get("result"))

    def _fail_pending(self, reason: str) -> None:
        with self._pending_lock:
            waiting = list(self._pending.values())
            self._pending.clear()
        for pending in waiting:
            pending.settle(error=RpcError(reason))

    def _dispatch(self, message: dict) -> None:
        method = message.get("method")
        if method is None:
            return

        request_id = message.get("id")
        params = message.get("params") or {}
        handler = self._handlers.get(method)

        if handler is None:
            if request_id is not None:
                self._write_error(
                    request_id, METHOD_NOT_FOUND, 'Unknown method "%s"' % method
                )
            return

        try:
            result = handler(params)
        except RpcError as error:
            if request_id is not None:
                self._write_error(request_id, error.code, error.message, error.data)
            return
        except Exception as error:  # noqa: BLE001 - report anything to the host
            if request_id is not None:
                self._write_error(request_id, INTERNAL_ERROR, str(error))
            return

        if request_id is not None:
            self._write({"jsonrpc": "2.0", "id": request_id, "result": result})

    def _read(self) -> Optional[dict]:
        while True:
            line = self._stdin.readline()
            if not line:
                return None
            line = line.strip()
            if not line:
                continue
            try:
                return json.loads(line)
            except ValueError:
                continue

    def _write(self, message: dict) -> None:
        line = json.dumps(message)
        with self._write_lock:
            self._stdout.write(line + "\n")
            self._stdout.flush()

    def _write_error(self, request_id: Any, code: int, message: str, data=None) -> None:
        error = {"code": code, "message": message}
        if data is not None:
            error["data"] = data
        self._write({"jsonrpc": "2.0", "id": request_id, "error": error})
