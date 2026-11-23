"""Read-only Finder volumes backed by the device worker's existing RSD connection."""

import asyncio
import contextlib
import logging
from pathlib import Path
import secrets
import tempfile
from typing import Any

from pymobiledevice3.services.house_arrest import HouseArrestService

from devicehubd import identity
from devicehubd.protocol import RpcError


class ReadOnlyDAV:
    """Unguessable per-mount URL; no device write methods or unbounded directory trees."""

    def __init__(self, app: Any, token: str):
        self.app = app
        self.prefix = "/" + token

    async def __call__(self, scope, receive, send):
        headers = dict(scope.get("headers", []))
        status = None
        if scope.get("path") != self.prefix and not scope.get("path", "").startswith(self.prefix + "/"):
            status = 404
        elif scope.get("method") not in {"OPTIONS", "PROPFIND", "GET", "HEAD"}:
            status = 403
        elif ".." in scope.get("path", "").split("/") or "\0" in scope.get("path", ""):
            status = 400
        elif scope.get("method") == "PROPFIND" and headers.get(b"depth", b"infinity") not in {b"0", b"1"}:
            status = 403
        if status:
            response_headers = [(b"content-length", b"0")]
            await send({"type": "http.response.start", "status": status, "headers": response_headers})
            await send({"type": "http.response.body", "body": b""})
            return
        await self.app(scope, receive, send)


async def serve(afc: Any, token: str):
    # Lazy loading keeps WebDAV dependencies out of ordinary device discovery/startup.
    import uvicorn
    from pymobiledevice3.services.webdav import (
        AfcDavProvider, DAVApp, DAVPath, PrefixProviderInfo, WebDavServer,
        generate_config_from_dict, reinit_global_config,
    )
    # Disabling ASGIWebDAV's logging config does not disable its request logger.
    # Keep mount URL capabilities and sandbox filenames out of application logs.
    logging.getLogger("asgi_webdav.server").disabled = True
    config = generate_config_from_dict({
        "account_mapping": [{"username": "anonymous", "password": "", "permissions": ["+"]}],
        "anonymous": {"enable": True, "allow_missing_auth_header": True,
                      "user": {"username": "anonymous", "password": "", "permissions": ["+"]}},
        "provider_mapping": [], "logging": {"enable": False},
    })
    reinit_global_config(config)
    app = DAVApp(config)
    class ContainerProvider(AfcDavProvider):
        def _afc_path(self, path):
            # The upstream provider receives both provider-relative paths (stat/get)
            # and full DAV paths (enumerating children); strip only our mount prefix.
            parts = list(path.parts)
            if parts and parts[0] == token:
                parts.pop(0)
            return "/" + "/".join(parts)

    prefix = DAVPath("/" + token)
    provider = ContainerProvider(afc=afc, root="/", config=config, prefix=prefix, read_only=True)
    app.web_dav.prefix_provider_mapping = [PrefixProviderInfo(
        prefix=prefix, prefix_weight=1, provider=provider, home_dir=False,
        read_only=True, ignore_property_extra=True)]

    class ManagedServer(uvicorn.Server):
        def capture_signals(self):
            return contextlib.nullcontext()  # Worker lifecycle owns signals and shutdown.

    server = ManagedServer(uvicorn.Config(ReadOnlyDAV(app, token), host="127.0.0.1", port=0,
                                         log_level="critical", access_log=False, lifespan="off"))
    task = asyncio.create_task(server.serve(), name="sandbox-webdav")
    try:
        async with asyncio.timeout(5):
            while not server.started:
                if task.done():
                    await task
                    raise RuntimeError("WebDAV server did not start")
                await asyncio.sleep(0.02)
        port = server.servers[0].sockets[0].getsockname()[1]
        return WebDavServer(server, task, "127.0.0.1", port)
    except BaseException:
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
        raise


async def command(*args: str, timeout: float = 15) -> int:
    process = await asyncio.create_subprocess_exec(*args, stdin=asyncio.subprocess.DEVNULL,
                                                 stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
    try:
        return await asyncio.wait_for(process.wait(), timeout)
    except BaseException:
        with contextlib.suppress(ProcessLookupError):
            process.kill()
        await process.wait()
        raise


async def is_mounted(path: str | Path) -> bool:
    # Read the mount table, not the volume itself: stat can hang after device loss
    # or issue synchronous HTTP back to this event loop.
    process = await asyncio.create_subprocess_exec("/sbin/mount", stdout=asyncio.subprocess.PIPE,
                                                 stderr=asyncio.subprocess.DEVNULL)
    try:
        output, _ = await asyncio.wait_for(process.communicate(), 3)
        return any(f" on {path} (" in line for line in output.decode().splitlines())
    except BaseException:
        with contextlib.suppress(ProcessLookupError):
            process.kill()
        await process.wait()
        raise


class SandboxMounts:
    def __init__(self, rsd: Any, root: Path | None = None):
        self.rsd = rsd
        self.root = root or identity.home() / "Mounts"
        self.mounts: dict[str, dict[str, Any]] = {}
        self.lock = asyncio.Lock()
        self.closed = False
        self.watcher: asyncio.Task | None = None
        self.pending: set[asyncio.Task] = set()

    async def open_container(self, bundle_id):
        return await HouseArrestService.create(self.rsd, bundle_id)

    def snapshot(self):
        return [{key: item[key] for key in ("id", "bundleID", "path")} for item in self.mounts.values()]

    async def mount(self, bundle_id: str, label: str) -> dict[str, Any]:
        task = asyncio.current_task()
        self.pending.add(task)
        try:
            return await self._mount(bundle_id, label)
        finally:
            self.pending.discard(task)

    async def _mount(self, bundle_id: str, label: str) -> dict[str, Any]:
        if not isinstance(bundle_id, str) or not bundle_id or "\0" in bundle_id:
            raise RpcError("invalidParams", "An app bundle identifier is required")
        if not isinstance(label, str) or not label.strip() or len(label) > 160 or any(c in label for c in "\0/:"):
            raise RpcError("invalidParams", "Invalid volume name")
        async with self.lock:
            if self.closed:
                raise RpcError("disconnected", "The device file service is closed")
            for token, item in list(self.mounts.items()):
                if item["bundleID"] == bundle_id:
                    if await is_mounted(item["path"]):
                        return {key: item[key] for key in ("id", "bundleID", "path")}
                    await self._dispose(item)
                    self.mounts.pop(token)
            afc = server = mount_path = None
            try:
                async with asyncio.timeout(35):
                    afc = await self.open_container(bundle_id)
                    await afc.listdir("/")  # Verify container access before starting any local listener.
                    secret = secrets.token_urlsafe(32)
                    server = await serve(afc, secret)
                    self.root.mkdir(parents=True, exist_ok=True)
                    # The mount table reports physical paths (e.g. /private/var for /var).
                    # Resolve the parent before mounting; stat on a live DAV volume can block.
                    mount_path = Path(tempfile.mkdtemp(prefix="sandbox-", dir=self.root.resolve()))
                    url = f"http://127.0.0.1:{server.port}/{secret}/"
                    status = await command("/sbin/mount_webdav", "-S", "-o", "rdonly,nobrowse", "-v", label, url, str(mount_path))
                    if status != 0 or not await is_mounted(mount_path):
                        raise RpcError("mountFailed", "Finder could not mount the sandbox WebDAV volume")
                if self.closed:
                    raise RpcError("disconnected", "The device file service is closed")
                token = secrets.token_hex(16)
                self.mounts[token] = {"id": token, "bundleID": bundle_id, "path": str(mount_path), "afc": afc, "server": server}
                if self.watcher is None:
                    self.watcher = asyncio.create_task(self._watch(), name="sandbox-mount-watch")
                return {key: self.mounts[token][key] for key in ("id", "bundleID", "path")}
            except BaseException:
                await self._dispose({"path": str(mount_path) if mount_path else None, "server": server, "afc": afc}, force=True)
                raise

    async def unmount(self, token: str):
        if not isinstance(token, str) or not token:
            raise RpcError("invalidParams", "A mount identifier is required")
        async with self.lock:
            item = self.mounts.get(token)
            if item is None:
                return
            if await is_mounted(item["path"]):
                if await command("/sbin/umount", item["path"], timeout=5) != 0:
                    raise RpcError("volumeBusy", "The Finder volume is busy. Close open files and eject it again.")
            await self._dispose(item)
            self.mounts.pop(token)

    async def _watch(self):
        try:
            while not self.closed:
                await asyncio.sleep(2)
                async with self.lock:
                    for token, item in list(self.mounts.items()):
                        if not await is_mounted(item["path"]):
                            await self._dispose(item)
                            self.mounts.pop(token)
        except asyncio.CancelledError:
            pass

    async def close(self):
        self.closed = True
        pending = list(self.pending)
        for task in pending:
            task.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
        if self.watcher:
            self.watcher.cancel()
            await asyncio.gather(self.watcher, return_exceptions=True)
        async with self.lock:
            items, self.mounts = list(self.mounts.values()), {}
            await asyncio.gather(*(self._dispose(item, force=True) for item in items), return_exceptions=True)

    @staticmethod
    async def _dispose(item, force=False):
        path = item.get("path")
        if path and await is_mounted(path):
            with contextlib.suppress(Exception):
                await command("/sbin/umount", *(["-f"] if force else []), path, timeout=3)
        if item.get("server"):
            with contextlib.suppress(Exception):
                await asyncio.wait_for(item["server"].stop(), 2)
        if item.get("afc"):
            with contextlib.suppress(Exception):
                await asyncio.wait_for(item["afc"].aclose(), 2)
        if path:
            with contextlib.suppress(OSError):
                Path(path).rmdir()
