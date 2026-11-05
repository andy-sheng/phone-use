import argparse
import json
import sys
from contextlib import redirect_stdout
from pathlib import Path

from .plugins import discover, install_plugin, pack_plugin
from .tasks import import_task, refresh_library, write_manifest


def parser():
    root = Path(__file__).resolve().parents[2]
    result = argparse.ArgumentParser(description="DeviceHub plugin runtime")
    commands = result.add_subparsers(dest="command", required=True)
    for name in ("catalog", "import", "refresh-library", "run", "probe", "install", "pack"):
        command = commands.add_parser(name)
        command.add_argument("--plugin-root", type=Path, action="append")
        if name == "import":
            command.add_argument("--plugin", required=True)
            source = command.add_mutually_exclusive_group(required=True)
            source.add_argument("--source")
            source.add_argument("--file", type=Path)
            command.add_argument("--output", required=True, type=Path)
        elif name == "refresh-library":
            command.add_argument("--library", type=Path, required=True)
        elif name in {"run", "probe"}:
            if name == "run":
                command.add_argument("--plugin", required=True)
                task = command.add_mutually_exclusive_group(required=True)
                task.add_argument("--task")
                task.add_argument("--task-file", type=Path)
                command.add_argument("--config", default="{}")
            command.add_argument("--device")
            command.add_argument("--bridge", type=Path, default=root / ".build/debug/devicehub")
            command.add_argument("--assets", type=Path, default=root / ".build/maa-core")
            command.add_argument("--output", type=Path, default=root / ".build/automation/run")
            command.add_argument("--watch-stdin", action="store_true")
        elif name == "install":
            command.add_argument("--package", type=Path, required=True)
            command.add_argument("--destination", type=Path)
        elif name == "pack":
            command.add_argument("--plugin", type=Path, required=True)
            command.add_argument("--output", type=Path, required=True)
    return result


def main(argv=None):
    args = parser().parse_args(argv)
    output = sys.stdout
    with redirect_stdout(sys.stderr):
        return dispatch(args, output)


def dispatch(args, output):
    try:
        if args.command == "install":
            result = install_plugin(args.package, args.destination)
        elif args.command == "pack":
            result = pack_plugin(args.plugin, args.output)
        else:
            packages, errors = discover(args.plugin_root)
            if args.command == "catalog":
                result = {"plugins": [package.public() for package in packages.values()], "errors": errors}
            elif args.command == "import":
                result = import_task(packages, args.plugin, source=args.source, file=args.file)
                write_manifest(args.output, result)
                result = {key: value for key, value in result.items() if key != "document"}
            elif args.command == "refresh-library":
                result = refresh_library(args.library, packages)
            else:
                from .runner import run
                return run(args, packages, output_stream=output)
        print(json.dumps(result, ensure_ascii=False), file=output)
        return 0
    except Exception as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=output)
        return 1


if __name__ == "__main__":
    sys.exit(main())
