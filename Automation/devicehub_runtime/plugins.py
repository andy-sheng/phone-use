"""Manifest-only discovery, compatible plugin loading and .dhplugin installation."""

import hashlib
import http.client
import importlib
import importlib.metadata
import json
import os
import re
import shutil
import stat
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

from . import API_VERSION, VERSION
from .sdk import validate_config

SCHEMA = "devicehub.plugin.v1"
CAPABILITIES = {"screenshot", "touch", "swipe", "launch", "portrait", "ocr"}
MAX_PACKAGE_BYTES = 256 * 1024 * 1024
MAX_PACKAGE_FILES = 10000
PACKAGE_EXTENSION = ".dhplugin"
DOWNLOAD_TIMEOUT = 120
SOCKET_TIMEOUT = 10
MAX_DOWNLOAD_REDIRECTS = 5
INSTALLED_ROOT = Path.home() / "Library/Application Support/DeviceHub/Plugins"


def version_tuple(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise ValueError(f"Unsupported version: {value}")
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (3 - len(parts))


def matches_version(actual, requirement):
    actual = version_tuple(actual)
    for clause in requirement.split(","):
        match = re.fullmatch(r"\s*(>=|<=|==|>|<)?\s*(\d+(?:\.\d+){0,2})\s*", clause)
        if not match:
            raise ValueError(f"Unsupported version constraint: {requirement}")
        operator, expected = match.group(1) or "==", version_tuple(match.group(2))
        if not {"==": actual == expected, ">=": actual >= expected, "<=": actual <= expected,
                ">": actual > expected, "<": actual < expected}[operator]:
            return False
    return True


def confined(root, relative):
    if not isinstance(relative, str) or not relative or Path(relative).is_absolute():
        raise ValueError("Plugin path must be relative")
    path = (root / relative).resolve()
    if not path.is_relative_to(root.resolve()):
        raise ValueError("Plugin path is outside its package")
    return path


def string_field(item, key, default=""):
    item.setdefault(key, default)
    if not isinstance(item[key], str):
        raise ValueError(f"{key} must be a string")


def normalize_task(task):
    for key in ("title", "subtitle", "description", "source", "author", "kind", "entry"):
        string_field(task, key, task.get("id", "") if key == "title" else "")
    for key in ("issues", "notes", "parameters", "phases"):
        task.setdefault(key, [])
        if not isinstance(task[key], list):
            raise ValueError(f"{key} must be an array")
    for key in ("issues", "notes"):
        if any(not isinstance(item, str) for item in task[key]):
            raise ValueError(f"{key} must contain strings")
    keys = []
    for item in task["parameters"]:
        if not isinstance(item, dict) or not isinstance(item.get("key"), str) or not item["key"]:
            raise ValueError("Invalid task parameter")
        keys.append(item["key"])
        string_field(item, "title", item["key"])
        string_field(item, "description")
        if "legacy_key" in item:
            string_field(item, "legacy_key")
        if item.get("type") not in {"integer", "boolean", "string", "choice"}:
            raise ValueError("Invalid parameter type")
        for key in ("min", "max"):
            if key in item and (not isinstance(item[key], int) or isinstance(item[key], bool)):
                raise ValueError(f"Parameter {key} must be an integer")
        if item["type"] == "choice" or "choices" in item:
            if not isinstance(item.get("choices"), list) or (item["type"] == "choice" and not item["choices"]):
                raise ValueError("Choice parameter needs choices")
            values = []
            for choice in item["choices"]:
                if not isinstance(choice, dict) or not isinstance(choice.get("value"), str):
                    raise ValueError("Invalid parameter choice")
                values.append(choice["value"])
                string_field(choice, "title", choice["value"])
            if len(values) != len(set(values)):
                raise ValueError("Duplicate parameter choice")
    if len(keys) != len(set(keys)):
        raise ValueError("Duplicate task parameter")
    validate_config(task["parameters"], {})
    for phase in task["phases"]:
        if not isinstance(phase, dict) or not isinstance(phase.get("id"), str):
            raise ValueError("Invalid task phase")
        string_field(phase, "title", phase["id"])
    return task


def read_manifest(root):
    root = Path(root).resolve()
    path = root / "plugin.json"
    if path.stat().st_size > 256 * 1024:
        raise ValueError("Plugin manifest is too large")
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if manifest.get("schema") != SCHEMA or manifest.get("api_version") != API_VERSION:
        raise ValueError("插件 SDK 版本不兼容")
    if not isinstance(manifest.get("id"), str) or not re.fullmatch(r"[a-z][a-z0-9-]{0,63}", manifest["id"]):
        raise ValueError("Invalid plugin ID")
    version_tuple(manifest.get("version"))
    if not isinstance(manifest.get("name"), str) or not manifest["name"]:
        raise ValueError("Missing plugin name")
    string_field(manifest, "description")
    entrypoint = manifest.get("entrypoint", "")
    if not re.fullmatch(r"[a-zA-Z_]\w*(?:\.[a-zA-Z_]\w*)*:[a-zA-Z_]\w*", entrypoint):
        raise ValueError("Invalid plugin entrypoint")
    module = entrypoint.split(":")[0]
    python = confined(root, manifest.get("python_path", "python"))
    module_path = confined(python, module.replace(".", "/"))
    if not module_path.with_suffix(".py").is_file() and not (module_path / "__init__.py").is_file():
        raise ValueError("Plugin entrypoint module is missing")
    for key in ("resources", "tasks", "task_types", "imports"):
        if not isinstance(manifest.get(key, []), list):
            raise ValueError(f"{key} must be an array")
    for resource in manifest.get("resources", []):
        if not confined(root, resource).is_dir():
            raise ValueError(f"Plugin resource directory is missing: {resource}")
    requirements = manifest.get("requires", {})
    if not isinstance(requirements, dict) or set(requirements) - {"runtime", "python", "maafw", "capabilities"}:
        raise ValueError("Invalid plugin requirements")
    if not isinstance(requirements.get("capabilities", []), list):
        raise ValueError("Capabilities must be an array")
    versions = {"runtime": VERSION, "python": ".".join(map(str, sys.version_info[:3]))}
    if "maafw" in requirements:
        try:
            versions["maafw"] = importlib.metadata.version("maafw")
        except importlib.metadata.PackageNotFoundError as error:
            raise ValueError("自动化运行环境缺少 MaaFramework，请完成运行环境准备或重新安装 phone-use。") from error
    for name, actual in versions.items():
        if name in requirements and not matches_version(actual, requirements[name]):
            raise ValueError(f"插件要求 {name} {requirements[name]}，当前为 {actual}")
    missing = set(requirements.get("capabilities", [])) - CAPABILITIES
    if missing:
        raise ValueError("设备运行时尚不支持：" + ", ".join(sorted(missing)))
    definitions = manifest.get("tasks", []) + manifest.get("task_types", [])
    seen = set()
    for task in definitions:
        if not isinstance(task, dict) or not isinstance(task.get("id"), str) or not task["id"] or task["id"] in seen:
            raise ValueError("Invalid or duplicate task ID")
        seen.add(task["id"])
        normalize_task(task)
    importer_ids, importer_kinds = set(), set()
    for importer in manifest.get("imports", []):
        if (not isinstance(importer, dict) or not isinstance(importer.get("id"), str) or
                not importer["id"] or importer.get("kind") not in {"file", "source"}):
            raise ValueError("Invalid import descriptor")
        if importer["id"] in importer_ids or importer["kind"] in importer_kinds:
            raise ValueError("SDK v1 supports one importer per kind")
        importer_ids.add(importer["id"])
        importer_kinds.add(importer["kind"])
        for key in ("title", "placeholder", "help_url", "help_title"):
            string_field(importer, key, importer["id"] if key == "title" else "")
        importer.setdefault("extensions", [])
        if not isinstance(importer["extensions"], list) or any(not isinstance(item, str) for item in importer["extensions"]):
            raise ValueError("Import extensions must be strings")
    return manifest


@dataclass
class PluginPackage:
    root: Path
    manifest: dict
    location: str = "external"

    @property
    def id(self):
        return self.manifest["id"]

    def task(self, task_id):
        for task in self.manifest.get("tasks", []) + self.manifest.get("task_types", []):
            if task["id"] == task_id:
                return task
        raise ValueError(f"插件不提供任务：{task_id}")

    def load(self):
        python = confined(self.root, self.manifest.get("python_path", "python"))
        name, factory = self.manifest["entrypoint"].split(":")
        # A selected plugin gets its own worker; no plugin code is imported by catalog.
        sys.path.insert(0, str(python))
        try:
            module = importlib.import_module(name)
            if not Path(module.__file__).resolve().is_relative_to(python):
                raise ValueError("Plugin module name conflicts with another package")
            return getattr(module, factory)()
        finally:
            sys.path.remove(str(python))

    def public(self):
        return {key: self.manifest.get(key, [] if key in {"imports", "tasks"} else "")
                for key in ("id", "name", "version", "description", "imports", "tasks")} | {"location": self.location}


def default_roots():
    return [INSTALLED_ROOT]


def discover(roots=None):
    packages, errors = {}, []
    for root in map(Path, roots if roots is not None else default_roots()):
        if not root.is_dir():
            continue
        files = [root / "plugin.json"] if (root / "plugin.json").is_file() else sorted(
            set(root.glob("*/plugin.json")) | set(root.glob("*/*/plugin.json")))
        current, versions_seen, ambiguous = {}, set(), set()
        for file in files:
            if any(part.startswith(".") for part in file.relative_to(root).parts):
                continue
            try:
                manifest = read_manifest(file.parent)
                location = "installed" if file.resolve().is_relative_to(INSTALLED_ROOT.resolve()) else "external"
                plugin = PluginPackage(file.parent.resolve(), manifest, location)
                identity = (plugin.id, version_tuple(manifest["version"]))
                if identity in versions_seen:
                    ambiguous.add(plugin.id)
                    current.pop(plugin.id, None)
                    raise ValueError("Duplicate plugin ID and version in the same search root")
                versions_seen.add(identity)
                if plugin.id in ambiguous:
                    continue
                previous = current.get(plugin.id)
                if previous is None or version_tuple(manifest["version"]) > version_tuple(previous.manifest["version"]):
                    current[plugin.id] = plugin
            except Exception as error:
                errors.append(f"{file.parent.name}：{error}")
        packages.update(current)  # Later explicitly supplied roots take precedence.
    return packages, errors


def package_files(root):
    files = []
    total = 0
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        if "__pycache__" in relative.parts or path.suffix == ".pyc":
            continue
        if path.is_symlink():
            raise ValueError("插件包不能包含符号链接")
        if path.is_file():
            total += path.stat().st_size
            files.append((path, relative))
            if total > MAX_PACKAGE_BYTES or len(files) > MAX_PACKAGE_FILES:
                raise ValueError("插件包过大")
    return files


def tree_digest(root):
    digest = hashlib.sha256()
    for path, relative in package_files(root):
        digest.update(relative.as_posix().encode() + b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def validate_distribution(root):
    """A pinned-asset source tree is not an installable release until prepared."""
    manifest_path = root / "assets.json"
    if not manifest_path.is_file():
        return
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(manifest.get("files"), list):
        raise ValueError("Invalid pinned asset manifest")
    for item in manifest["files"]:
        target = confined(root / "resources", item["destination"])
        if not target.is_file():
            raise ValueError(f"插件资源尚未准备：{item['destination']}；请先准备资源再打包或安装")
        data = target.read_bytes()
        digest = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
        if digest != item["blob_sha"]:
            raise ValueError(f"插件资源校验失败：{item['destination']}；请重新准备资源")


def pack_plugin(root, output):
    root, output = Path(root).resolve(), Path(output).resolve()
    read_manifest(root)
    validate_distribution(root)
    if output.is_relative_to(root):
        raise ValueError("输出包不能位于插件目录内")
    files = package_files(root)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + ".part")
    try:
        with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED) as archive:
            for path, relative in files:
                archive.write(path, relative.as_posix())
        if temporary.stat().st_size > MAX_PACKAGE_BYTES:
            raise ValueError("插件包过大")
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)
    return {"path": str(output), "format": "dhplugin", "files": len(files),
            "sha256": hashlib.sha256(output.read_bytes()).hexdigest()}


def extract_package(source, destination):
    if source.is_dir():
        for path, relative in package_files(source):
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
        return
    if source.stat().st_size > MAX_PACKAGE_BYTES:
        raise ValueError("插件包过大")
    if not zipfile.is_zipfile(source):
        raise ValueError("不是有效的 phone-use 插件包，请选择 .dhplugin 或 ZIP 文件")
    with zipfile.ZipFile(source) as archive:
        entries = archive.infolist()
        if len(entries) > MAX_PACKAGE_FILES or sum(item.file_size for item in entries) > MAX_PACKAGE_BYTES:
            raise ValueError("插件包过大")
        seen = set()
        for item in entries:
            path = PurePosixPath(item.filename)
            mode = item.external_attr >> 16
            normalized = path.as_posix()
            if (path.is_absolute() or ".." in path.parts or "\\" in item.filename or
                    not path.parts or stat.S_ISLNK(mode) or normalized in seen):
                raise ValueError("插件包包含无效路径或符号链接")
            seen.add(normalized)
            target = confined(destination, path.as_posix())
            if item.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(item) as reader, target.open("wb") as writer:
                    shutil.copyfileobj(reader, writer)


def install_plugin(source, destination=None):
    source = Path(source).resolve()
    destination = Path(destination or INSTALLED_ROOT).resolve()
    if source.is_dir():
        if destination.is_relative_to(source):
            raise ValueError("安装目录不能位于插件源目录内")
        read_manifest(source)
        validate_distribution(source)
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".install-", dir=destination) as temporary:
        staged = Path(temporary) / "package"
        staged.mkdir()
        extract_package(source, staged)
        manifest = read_manifest(staged)
        validate_distribution(staged)
        plugin_id, version = manifest["id"], manifest["version"]
        target = confined(destination, f"{plugin_id}/{version}")
        if target.exists():
            if tree_digest(target) != tree_digest(staged):
                raise ValueError("此版本已安装且内容不同；请使用新的插件版本号")
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            os.replace(staged, target)
    return {"plugin_id": plugin_id, "version": version, "message": f"已安装 {manifest['name']} {version}"}


def validate_download_url(value):
    """Validate every hop without including a potentially signed URL in diagnostics."""
    if not isinstance(value, str) or any(ord(character) < 32 or character.isspace() for character in value):
        raise ValueError("请输入有效的 HTTP 或 HTTPS 插件下载地址")
    try:
        url = urllib.parse.urlsplit(value)
        # Accessing port validates malformed/out-of-range port syntax as well.
        port = url.port
        if (url.scheme not in {"http", "https"} or not url.hostname or
                url.username is not None or url.password is not None or "\\" in url.netloc):
            raise ValueError
        if port is not None and port == 0:
            raise ValueError
        # urllib expects an ASCII transport URL. Unicode paths must be percent encoded.
        value.encode("ascii")
    except (ValueError, UnicodeError):
        raise ValueError("请输入有效的 HTTP 或 HTTPS 插件下载地址，地址中不能包含用户名或密码") from None
    return urllib.parse.urlunsplit(url._replace(fragment=""))


class PackageRedirectHandler(urllib.request.HTTPRedirectHandler):
    def __init__(self, deadline):
        super().__init__()
        self.deadline = deadline
        self.redirects = 0

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        self.redirects += 1
        if self.redirects > MAX_DOWNLOAD_REDIRECTS:
            raise ValueError("插件下载地址重定向次数过多，请使用直接下载链接")
        if time.monotonic() >= self.deadline:
            raise TimeoutError
        target = validate_download_url(newurl)
        if urllib.parse.urlsplit(req.full_url).scheme == "https" and urllib.parse.urlsplit(target).scheme != "https":
            raise ValueError("插件下载地址不能从 HTTPS 重定向到 HTTP")
        return super().redirect_request(req, fp, code, msg, headers, target)


def download_package(url, target):
    url = validate_download_url(url.strip())
    deadline = time.monotonic() + DOWNLOAD_TIMEOUT
    opener = urllib.request.build_opener(PackageRedirectHandler(deadline))
    request = urllib.request.Request(url, headers={
        "User-Agent": f"phone-use/{VERSION}",
        "Accept": "application/vnd.devicehub.plugin+zip, application/zip, application/octet-stream",
        "Accept-Encoding": "identity",
    })
    try:
        with opener.open(request, timeout=SOCKET_TIMEOUT) as response:
            validate_download_url(response.geturl())
            if response.status != 200:
                raise ValueError(f"插件下载失败（HTTP {response.status}），请使用插件包的直接下载链接")
            length = response.headers.get("Content-Length")
            if length is not None:
                try:
                    length = int(length)
                except ValueError:
                    raise ValueError("插件下载响应的文件大小无效") from None
                if length < 0:
                    raise ValueError("插件下载响应的文件大小无效")
                if length > MAX_PACKAGE_BYTES:
                    raise ValueError("插件包过大，下载文件不能超过 256 MiB")
            total = 0
            with Path(target).open("wb") as output:
                while True:
                    if time.monotonic() >= deadline:
                        raise TimeoutError
                    # read1 performs at most one buffered/socket read, so a slow sender
                    # cannot defer the total deadline check until a full chunk arrives.
                    chunk = response.read1(64 * 1024)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > MAX_PACKAGE_BYTES:
                        raise ValueError("插件包过大，下载文件不能超过 256 MiB")
                    output.write(chunk)
            if time.monotonic() >= deadline:
                raise TimeoutError
            if length is not None and total != length:
                raise ValueError("插件下载不完整，请重新下载")
    except urllib.error.HTTPError as error:
        raise ValueError(f"插件下载失败（HTTP {error.code}），请检查下载链接") from None
    except (TimeoutError, urllib.error.URLError, OSError, http.client.HTTPException) as error:
        reason = error.reason if isinstance(error, urllib.error.URLError) else error
        if isinstance(reason, TimeoutError):
            raise ValueError("插件下载超时，请稍后重试") from None
        raise ValueError("无法下载插件，请检查网络和下载链接") from None


def install_plugin_url(url, destination=None):
    # A release endpoint need not have a filename extension. The downloaded bytes
    # must still satisfy precisely the same package contract as a local file.
    url = validate_download_url(url.strip())
    destination = Path(destination or INSTALLED_ROOT).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".download-", dir=destination) as temporary:
        package = Path(temporary) / ("package" + PACKAGE_EXTENSION)
        download_package(url, package)
        return install_plugin(package, destination)
