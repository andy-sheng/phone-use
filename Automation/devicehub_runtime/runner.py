"""Host-owned lifecycle for one plugin task and one physical-device controller."""

import fcntl
import hashlib
import json
import os
import signal
import sys
import tempfile
import threading
import time
import traceback
from pathlib import Path

from .sdk import PreparedTask, RuntimeContext, validate_config
from .tasks import inspect_task, read_document


class DeviceLease:
    def __init__(self, udid, directory=None):
        if not udid:
            raise ValueError("设备没有返回唯一标识")
        directory = Path(directory or Path(tempfile.gettempdir()) / f"devicehub-{os.getuid()}")
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        path = directory / (hashlib.sha256(udid.encode()).hexdigest() + ".lock")
        fd = os.open(path, os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
        self.file = os.fdopen(fd, "a")
        try:
            fcntl.flock(self.file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.file.close()
            raise RuntimeError("此设备已有自动任务运行，请先停止另一个任务") from None

    def close(self):
        self.file.close()


def preflight(args, packages):
    """Validate task and current plugin settings before a device connection is created."""
    if args.command == "probe":
        return None, None, None, {}
    package = packages.get(args.plugin)
    if package is None:
        raise ValueError(f"任务插件未安装或不兼容：{args.plugin}")
    if args.task_file:
        metadata = inspect_task(package, read_document(args.task_file))
        task_id = metadata["task_id"]
        if metadata["issues"]:
            raise ValueError("任务需要适配：" + "；".join(metadata["issues"][:5]))
        document = metadata["document"]
    else:
        task_id = args.task
        if task_id not in {task["id"] for task in package.manifest.get("tasks", [])}:
            raise ValueError("该任务需要先导入任务文件")
        document = None
    definition = package.task(task_id)
    config = validate_config(definition.get("parameters", []), json.loads(args.config))
    return package, task_id, document, config


def execute(args, packages, emit, stop, bridge_factory=None):
    from maa.context import ContextEventSink
    from maa.define import LoggingLevelEnum
    from maa.event_sink import NotificationType
    from maa.library import Library
    from maa.pipeline import JOCR
    from maa.resource import Resource
    from maa.tasker import Tasker

    from .controller import Bridge, DeviceController
    from .images import save_png

    package, task_id, document, config = preflight(args, packages)
    for name in ("det.onnx", "rec.onnx", "keys.txt"):
        if not (args.assets / "model/ocr" / name).is_file():
            raise FileNotFoundError("共享 OCR 资源未准备，请重新安装应用或运行 scripts/setup-automation.sh")
    if bridge_factory is None and not args.bridge.is_file():
        raise FileNotFoundError("找不到 DeviceHub 设备桥接程序")
    Tasker.set_stdout_level(LoggingLevelEnum.Off)
    Tasker.set_log_dir(args.output)
    Tasker.set_save_on_error(True)
    bridge = tasker = lease = None
    try:
        resource = Resource()
        if not resource.post_bundle(args.assets).wait().succeeded:
            raise RuntimeError("共享 OCR 资源加载失败")
        prepared = None
        if package:
            context = RuntimeContext(resource, stop, emit, package.root, args.assets, args.output)
            prepared = package.load().prepare(context, task_id, document, config)
            if not isinstance(prepared, PreparedTask) or not prepared.entry or prepared.timeout <= 0:
                raise ValueError("插件返回了无效的任务定义")
            for bundle in prepared.bundles:
                if not Path(bundle).resolve().is_relative_to(package.root):
                    raise ValueError("插件资源超出安装目录")
                if not resource.post_bundle(bundle).wait().succeeded:
                    raise RuntimeError("插件资源加载失败")
            if prepared.pipeline and not resource.override_pipeline(prepared.pipeline):
                raise ValueError("插件流程不符合 MaaFramework 协议")
        if stop.is_set():
            raise InterruptedError("任务已停止")
        emit("progress", message="正在连接设备", framework=Library.version(), phase="connecting")
        bridge = (bridge_factory or Bridge)(args.bridge, args.device)
        controller = DeviceController(bridge, emit)
        if not controller.post_connection().wait().succeeded:
            raise RuntimeError(controller.last_error or "设备连接失败")
        lease = DeviceLease(controller.info["udid"])
        emit("progress", message=f"{controller.info.get('name', '设备')} 已连接", phase="connecting", phase_status="completed")
        controller.set_screenshot_target_short_side(720)
        tasker = Tasker()
        if not tasker.bind(resource, controller) or not tasker.inited:
            raise RuntimeError("MaaFramework 初始化失败")
        if args.command == "probe":
            image = controller.post_screencap().wait().get()
            if image is None:
                raise RuntimeError(controller.last_error or "截图失败")
            path = (args.output / "screen.png").resolve()
            save_png(path, image)
            task = tasker.post_recognition("OCR", JOCR(roi=[0, 0, 0, 0]), image).wait().get()
            detail = task.nodes[0].recognition if task and task.nodes else None
            if detail is None:
                raise RuntimeError("OCR 识别未返回结果")
            words = [{"text": item.text, "box": list(item.box), "score": item.score} for item in detail.all_results]
            (args.output / "ocr.json").write_text(json.dumps(words, ensure_ascii=False, indent=2))
            if stop.is_set():
                raise InterruptedError("任务已停止")
            emit("result", status="probe_complete", message="已读取设备画面并完成 OCR，未发送触摸操作",
                 native_size=[controller.info["width"], controller.info["height"]],
                 recognition_size=[image.shape[1], image.shape[0]], words=len(words), screenshot=str(path))
            return 0

        class Progress(ContextEventSink):
            def on_node_pipeline_node(self, context, noti_type, detail):
                if noti_type == NotificationType.Succeeded:
                    emit("progress", message=f"已完成节点：{detail.name}")

        progress = Progress()
        tasker.add_context_sink(progress)
        initial_phase = next((phase["id"] for phase in package.task(task_id)["phases"]
                              if phase["id"] != "connecting"), "executing")
        emit("progress", message=f"正在执行：{prepared.entry}", phase=initial_phase)
        if stop.is_set():
            raise InterruptedError("任务已停止")
        job = tasker.post_task(prepared.entry)
        started = time.monotonic()
        stop_sent = False
        timed_out = False
        while not job.done:
            deadline = prepared.deadline() if prepared.deadline else 0
            overdue = time.monotonic() > (deadline + 30 if deadline else started + prepared.timeout + 10)
            if (stop.is_set() or overdue) and not stop_sent:
                timed_out = overdue and not stop.is_set()
                stop.set()
                tasker.post_stop()
                stop_sent = True
            time.sleep(0.1)
        result = prepared.result(job.succeeded) if prepared.result else {
            "status": "completed" if job.succeeded else "failed",
            "message": "流程已完成，请查看画面确认结果" if job.succeeded else "流程执行失败，请查看日志",
        }
        if timed_out:
            result.update(status="failed", message="任务运行超时，已停止后续操作")
        elif stop.is_set():
            result.update(status="cancelled", message="任务已停止")
        if result.get("status") not in {"completed", "cancelled", "failed"}:
            raise ValueError("插件返回了无效的结果状态")
        screenshot = None
        if not stop.is_set():
            image = controller.post_screencap().wait().get()
            if image is not None:
                screenshot = str((args.output / "final.png").resolve())
                save_png(Path(screenshot), image)
        emit("result", **result, screenshot=screenshot)
        return 0 if result["status"] == "completed" else 1
    finally:
        if tasker and tasker.running:
            stop.set()
            tasker.post_stop().wait()
        if bridge:
            bridge.close()
        if lease:
            lease.close()


def run(args, packages, output_stream=None):
    args.output.mkdir(parents=True, exist_ok=True)
    output_lock = threading.Lock()
    event_file = (args.output / "events.jsonl").open("w", encoding="utf-8")

    def emit(event, **data):
        line = json.dumps({"event": event, "time": time.time(), **data}, ensure_ascii=False)
        with output_lock:
            print(line, flush=True, file=output_stream or sys.stdout)
            event_file.write(line + "\n")
            event_file.flush()

    stop = threading.Event()
    finished = threading.Event()
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, lambda *_: stop.set())
    if args.watch_stdin:
        def watch_parent():
            sys.stdin.buffer.read()
            stop.set()
        threading.Thread(target=watch_parent, daemon=True).start()
    def enforce_stop():
        stop.wait()
        if not finished.wait(8):
            # A custom callback can ignore cooperative cancellation or hang in native code.
            # Exiting this worker closes its private bridge pipe; the bridge releases touch on EOF.
            # Do not write to pipes here: the parent may be gone or a plugin may hold
            # an output lock. The app observes worker exit and reports the final failure.
            os._exit(1)
    threading.Thread(target=enforce_stop, daemon=True).start()
    try:
        return execute(args, packages, emit, stop)
    except Exception as error:
        traceback.print_exc(file=sys.stderr)
        emit("result", status="cancelled" if stop.is_set() else "failed", message=str(error))
        return 1
    finally:
        finished.set()
        event_file.close()
