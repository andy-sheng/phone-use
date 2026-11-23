"""Read-only app data for the selected Android user, using Android's run-as permission check."""

import os
import re
import shlex
import stat
from dataclasses import dataclass
from datetime import datetime, timezone

from pymobiledevice3.exceptions import AfcException

from devicehubd.protocol import RpcError
from devicehubd.sandbox_mounts import SandboxMounts

CHUNK_SIZE = 512 * 1024
PACKAGE = re.compile(r"[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)*")

# Pass paths as positional arguments, never as shell source. Pin the working
# directory before inspecting the leaf. pwd -P also detects symlinked ancestors.
DIRECTORY = r"""
root=$(pwd -P) || exit 1
cd -P "./$1" || exit 1
actual=$(pwd -P && printf '.') || exit 1
expected=$root
[ "$1" = . ] || expected="$root/$1"
[ "$actual" = "$(printf '%s\n.' "$expected")" ] || exit 1
"""
LIST = DIRECTORY + r"""
[ -r . ] && [ -x . ] || exit 1
for entry in ./* ./.[!.]* ./..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    metadata=$(stat -c '%f %s %Y' "$entry") || exit 1
    printf '%s\0%s\0' "${entry#./}" "$metadata"
done
"""
READ = DIRECTORY + r"""
file="./$2"
[ ! -L "$file" ] && [ -f "$file" ] || exit 1
exec 3< "$file" || exit 1
# Validate the open descriptor before returning bytes, including after a rename.
[ -f /proc/self/fd/3 ] || exit 1
opened=$(readlink /proc/self/fd/3 && printf '.') || exit 1
[ "$opened" = "$(printf '%s/%s\n.' "$expected" "$2")" ] || exit 1
tail -c "+$3" <&3 | head -c "$4"
"""
PACKAGES = r"""
packages=$(pm list packages --user "$1" --show-versioncode 2>/dev/null) ||
    packages=$(pm list packages --user "$1") || exit 1
user=$1
if [ "$user" = 0 ]; then set --; else set -- --user "$user"; fi
printf '%s\n' "$packages" | while read -r package version; do
    [ -n "$package" ] || continue
    case "$package" in package:*) ;; *) exit 1 ;; esac
    name=${package#package:}
    if run-as "$name" "$@" /system/bin/true 2>/dev/null; then access=yes; else access=no; fi
    printf '%s\t%s\t%s\n' "$name" "${version#versionCode:}" "$access"
done
"""


async def current_user(adb, serial):
    user = (await adb.command("-s", serial, "shell", "am", "get-current-user")).strip()
    if not re.fullmatch(r"[0-9]+", user):
        raise RpcError("notReady", "Cannot identify the current Android user")
    return user


async def apps(adb, serial):
    user = await current_user(adb, serial)
    command = shlex.join(["/system/bin/sh", "-c", PACKAGES, "packages", user])
    output = await adb.command("-s", serial, "shell", "-T", command, timeout=90)
    result = []
    for row in output.splitlines():
        package, version, access = row.split("\t")
        result.append({"bundleIdentifier": package, "name": package, "version": version or None,
                       "containerAccessible": access == "yes"})
    return sorted(result, key=lambda app: app["bundleIdentifier"])


def relative(path):
    if not isinstance(path, str) or path.startswith("/") or "\0" in path or ".." in path.split("/"):
        raise RpcError("invalidParams", "Expected a container-relative path without traversal")
    return "/".join(p for p in path.split("/") if p not in ("", ".")) or "."


def metadata(raw):
    mode, size, modified = raw.split()
    return os.stat_result((int(mode, 16), 0, 0, 1, 0, 0, int(size), 0, int(modified), 0))


@dataclass
class ReadHandle:
    path: str
    offset: int = 0


class AndroidSandbox:
    """One package and Android user for the lifetime of a Finder volume."""

    def __init__(self, adb, serial, package, user):
        if not isinstance(package, str) or not PACKAGE.fullmatch(package):
            raise RpcError("invalidParams", "An Android package name is required")
        self.adb, self.serial, self.package, self.user = adb, serial, package, user

    async def _run(self, script, *args):
        user_args = [] if self.user == "0" else ["--user", self.user]
        command = shlex.join(["run-as", self.package, *user_args, "/system/bin/sh", "-c",
                              script, "sandbox", *args])
        # An already mounted Finder volume stays bound to the original profile.
        command = f'[ "$(am get-current-user)" = {shlex.quote(self.user)} ] && exec ' + command
        try:
            return await self.adb.command_bytes("-s", self.serial, "shell", "-T", command, timeout=30)
        except ConnectionError as error:
            raise RpcError("sandboxUnavailable", f"Cannot read {self.package}: {error}") from error

    async def entries(self, path):
        fields = (await self._run(LIST, relative(path))).split(b"\0")
        if fields.pop() or len(fields) % 2:
            raise RpcError("invalidResponse", "Incomplete Android directory listing")
        result = {}
        for name, raw in zip(fields[::2], fields[1::2]):
            try:
                result[name.decode()] = metadata(raw)
            except UnicodeDecodeError:
                # DAV and the JSON file API can represent only Unicode filenames.
                continue
        return result

    async def files(self, path):
        path = relative(path)
        result = []
        for name, item in (await self.entries(path)).items():
            if stat.S_ISREG(item.st_mode):
                kind = "file"
            elif stat.S_ISDIR(item.st_mode):
                kind = "directory"
            elif stat.S_ISLNK(item.st_mode):
                kind = "symbolicLink"
            else:
                continue
            result.append({"name": name, "path": name if path == "." else f"{path}/{name}", "kind": kind,
                           "size": item.st_size, "modified": datetime.fromtimestamp(item.st_mtime, timezone.utc).isoformat()})
        return sorted(result, key=lambda row: (row["kind"] != "directory", row["name"].casefold()))

    async def read(self, path, offset, size):
        if type(offset) is not int or offset < 0 or type(size) is not int or not 0 < size <= CHUNK_SIZE:
            raise RpcError("invalidParams", "Invalid Android file read range")
        path = relative(path)
        parent, _, name = path.rpartition("/")
        if name == ".":
            raise RpcError("invalidParams", "Select a regular file")
        return await self._run(READ, parent or ".", name, str(offset + 1), str(size))

    # The read-only DAV provider uses this small filesystem interface for metadata
    # and range reads. A handle carries its offset, not a running shell process.
    async def os_stat(self, path):
        path = relative(path.removeprefix("/"))
        parent, _, name = path.rpartition("/")
        try:
            return metadata(await self._run(DIRECTORY + '\nstat -c "%f %s %Y" "./$2"', parent or ".", name))
        except RpcError as error:
            raise AfcException(str(error), None, path) from error

    async def listdir(self, path):
        return list(await self.entries(path.removeprefix("/")))

    async def fopen(self, path, mode):
        if mode != "r":
            raise PermissionError("Read-only volume")
        return ReadHandle(relative(path.removeprefix("/")))

    async def fseek(self, handle, offset, whence):
        if whence != os.SEEK_SET or offset < 0:
            raise ValueError("Expected absolute read offset")
        handle.offset = offset

    async def fread(self, handle, size):
        data = bytearray()
        while len(data) < size:
            count = min(CHUNK_SIZE, size - len(data))
            part = await self.read(handle.path, handle.offset, count)
            data.extend(part)
            handle.offset += len(part)
            if len(part) < count:
                break
        return bytes(data)

    async def fclose(self, handle):
        pass

    async def aclose(self):
        pass

class AndroidMounts(SandboxMounts):
    def __init__(self, adb, serial, user):
        super().__init__(None)
        self.adb, self.serial, self.user = adb, serial, user

    async def open_container(self, package):
        return AndroidSandbox(self.adb, self.serial, package, self.user)
