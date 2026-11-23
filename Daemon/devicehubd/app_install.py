"""Install a local package on a device using its existing transport."""

from pathlib import Path
from uuid import uuid4

from pymobiledevice3.services.afc import AfcService
from pymobiledevice3.services.installation_proxy import InstallationProxyService

from devicehubd.protocol import RpcError


def package_file(value: object, suffix: str) -> Path:
    if isinstance(value, str) and "\0" not in value:
        path = Path(value)
        if path.is_absolute() and path.suffix.lower() == suffix and path.is_file():
            return path
    raise RpcError("invalidParams", f"Choose a local {suffix} file using its absolute path")


async def install_ipa(rsd, path: Path) -> None:
    # Stream large packages and keep concurrent transfers' staging files independent.
    directory = "/PublicStaging"
    staged = f"{directory}/{uuid4()}.ipa"
    async with AfcService(rsd) as afc, InstallationProxyService(rsd) as installer:
        if not await afc.exists(directory):
            await afc.makedirs(directory)
        try:
            await afc.push(str(path), staged, progress_bar=False)
            await installer.send_package("Install", {}, None, staged)
        finally:
            await afc.rm_single(staged, force=True)


async def install_apk(android, serial: str, path: Path) -> None:
    try:
        output = await android.command("-s", serial, "install", "-r", str(path), timeout=600)
    except TimeoutError as error:
        raise RpcError("installTimeout", "ADB timed out. Check the device for the installed app.") from error
    if "Success" not in output.splitlines():
        raise RpcError("installFailed", output.strip() or "ADB did not confirm installation")
