import asyncio
import contextlib
import ipaddress
import logging
import os
import secrets
import subprocess
import urllib.parse
from pathlib import Path
from typing import Optional, Sequence, Set, Union

import websockets
from fastapi import Depends, FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from starlette.websockets import WebSocketState
from websockets.exceptions import ConnectionClosed

from .models import WifiRequest, WifiStatus, SystemStats
from .tasks import write_wifi_conf, clear_wifi_conf, run_switch, read_wifi_conf, read_system_stats


ALLOY_LOKI_TAIL_URL = os.environ.get(
    "ALLOY_LOKI_TAIL_URL",
    "ws://127.0.0.1:3100/loki/api/v1/tail",
)

logger = logging.getLogger(__name__)


def load_or_create_token(path: Path) -> str:
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        token = secrets.token_hex(32)
        path.write_text(token)
        return token
    return path.read_text().strip()


def build_allowed_origins(raw: Optional[str]) -> Set[str]:
    if not raw:
        return set()
    return {o.strip() for o in raw.split(",") if o.strip()}


def _is_trusted_host(host: str) -> bool:
    if not host:
        return False
    if host in {"127.0.0.1", "::1", "localhost"}:
        return True
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return False
    # Treat any RFC1918/4193/local addresses as trusted so the console works on LAN.
    return ip.is_loopback or ip.is_private or ip.is_link_local


def _build_loki_tail_url(
    query: Union[str, Sequence[str]],
    limit: Optional[str],
    start: Optional[str],
    delay_for: Optional[str],
) -> str:
    """
    Build Loki tail WS URL.

    query: LogQL stream selector(s), e.g. '{service="polyflow-webrtc.service"}'
           or list of selectors to OR together.
    """

    # Normalize selectors to a single query string.
    if isinstance(query, str):
        query_expr = query
    else:
        query_expr = " or ".join(query)

    params: dict[str, object] = {
        "query": query_expr,   # Tail expects the LogQL query under "query"
    }

    if limit:
        params["limit"] = limit
    if start:
        params["start"] = start
    if delay_for:
        params["delay_for"] = delay_for

    separator = "&" if urllib.parse.urlsplit(ALLOY_LOKI_TAIL_URL).query else "?"
    return (
        f"{ALLOY_LOKI_TAIL_URL}{separator}"
        f"{urllib.parse.urlencode(params, doseq=True)}"
    )


async def _require_websocket_auth(websocket: WebSocket, required_token: str) -> None:
    client_host = websocket.client.host if websocket.client else ""
    if _is_trusted_host(client_host):
        return
    header = websocket.headers.get("authorization", "")
    if not header.startswith("Bearer "):
        await websocket.close(code=1008, reason="missing bearer token")
        raise WebSocketDisconnect(code=1008)
    token = header.removeprefix("Bearer ").strip()
    if token != required_token:
        await websocket.close(code=1008, reason="invalid token")
        raise WebSocketDisconnect(code=1008)


async def _relay_alloy_to_client(upstream: websockets.WebSocketClientProtocol, websocket: WebSocket) -> None:
    async for message in upstream:
        if isinstance(message, (bytes, bytearray)):
            await websocket.send_bytes(message)
        else:
            await websocket.send_text(message)


async def _wait_for_client_disconnect(websocket: WebSocket) -> None:
    try:
        while True:
            message = await websocket.receive()
            if message.get("type") == "websocket.disconnect":
                break
    except WebSocketDisconnect:
        pass
    except RuntimeError:
        # Raised when the connection is closed elsewhere.
        pass


def require_auth(required_token: str):
    async def _auth(request: Request):
        # Allow unauthenticated health checks
        if request.url.path == "/health":
            return
        # Allow loopback/hotspot without token
        client_host = request.client.host if request.client else ""
        if _is_trusted_host(client_host):
            return
        header = request.headers.get("authorization", "")
        if not header.startswith("Bearer "):
            raise HTTPException(status_code=401, detail="missing bearer token")
        token = header.removeprefix("Bearer ").strip()
        if token != required_token:
            raise HTTPException(status_code=403, detail="invalid token")
    return _auth


def create_app() -> FastAPI:
    token_path = Path(os.environ.get("ROBOT_API_TOKEN_PATH", "/var/lib/polyflow/api_token"))
    token = load_or_create_token(token_path)
    allowed_origins = build_allowed_origins(os.environ.get("ROBOT_API_ALLOWED_ORIGINS"))

    app = FastAPI()

    if allowed_origins:
        app.add_middleware(
          CORSMiddleware,
          allow_origins=list(allowed_origins),
          allow_methods=["*"],
          allow_headers=["*"],
        )

    auth_dep = Depends(require_auth(token))

    @app.get("/health")
    def health():
        return {"status": "ok"}

    @app.get("/wifi", response_model=WifiStatus, dependencies=[auth_dep])
    def get_wifi():
        return WifiStatus(**read_wifi_conf())

    @app.post("/wifi", dependencies=[auth_dep])
    def set_wifi(body: WifiRequest):
        try:
            write_wifi_conf(body.ssid, body.psk)
            run_switch()
        except subprocess.CalledProcessError as exc:
            raise HTTPException(status_code=500, detail=f"wifi switch failed: {exc}")
        return {"status": "ok"}

    @app.post("/wifi/clear", dependencies=[auth_dep])
    def clear_wifi():
        try:
            clear_wifi_conf()
            run_switch()
        except subprocess.CalledProcessError as exc:
            raise HTTPException(status_code=500, detail=f"wifi switch failed: {exc}")
        return {"status": "ok"}

    @app.get("/stats", response_model=SystemStats, dependencies=[auth_dep])
    def get_stats():
        return SystemStats(**read_system_stats())

    @app.websocket("/logs/tail")
    async def tail_logs(websocket: WebSocket):
        query = websocket.query_params.get("query") or websocket.query_params.get("selector")
        if not query:
            await websocket.close(code=1002, reason="query parameter required")
            return

        limit = websocket.query_params.get("limit")
        start = websocket.query_params.get("start")
        delay_for = websocket.query_params.get("delay_for")

        try:
            await _require_websocket_auth(websocket, token)
        except WebSocketDisconnect:
            return

        await websocket.accept()
        upstream_url = _build_loki_tail_url(query, limit, start, delay_for)

        try:
            async with websockets.connect(upstream_url, ping_interval=20, ping_timeout=20) as alloy_ws:
                forward_task = asyncio.create_task(_relay_alloy_to_client(alloy_ws, websocket))
                disconnect_task = asyncio.create_task(_wait_for_client_disconnect(websocket))
                done, pending = await asyncio.wait(
                    [forward_task, disconnect_task],
                    return_when=asyncio.FIRST_COMPLETED,
                )
                for task in done:
                    with contextlib.suppress(Exception):
                        task.result()
                for task in pending:
                    task.cancel()
        except (ConnectionRefusedError, OSError) as exc:
            logger.error("Unable to connect to Grafana Alloy: %s", exc)
            await websocket.send_json({"type": "error", "message": "log provider unavailable"})
            await websocket.close(code=1011, reason="log provider unavailable")
            return
        except ConnectionClosed:
            # Upstream closed the connection; mirror it to the client.
            pass
        except Exception as exc:  # pragma: no cover - defensive
            logger.exception("Unexpected error relaying logs", exc_info=exc)
            if websocket.application_state == WebSocketState.CONNECTED:
                await websocket.send_json({"type": "error", "message": "internal log relay error"})
                await websocket.close(code=1011, reason="internal log relay error")
            return

        if websocket.application_state == WebSocketState.CONNECTED:
            await websocket.close(code=1000)

    return app


def main():
    import uvicorn
    uvicorn.run(
        create_app(),
        host="0.0.0.0",
        port=int(os.environ.get("ROBOT_API_PORT", "8082")),
    )


if __name__ == "__main__":
    main()
