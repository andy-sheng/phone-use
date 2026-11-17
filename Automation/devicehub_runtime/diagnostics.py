"""Bounded bridge request metadata; never log parameters, replies, images or credentials."""
import json
import logging
import os
import sys
import time
from logging.handlers import RotatingFileHandler
from pathlib import Path


class BridgeTrace:
    def __init__(self):
        self.handler = None
        directory = os.environ.get("DEVICEHUB_RUN_LOG_DIR")
        if directory:
            try:
                path = Path(directory) / "bridge.jsonl"
                path.parent.mkdir(parents=True, exist_ok=True)
                self.handler = RotatingFileHandler(path, maxBytes=2 * 1024 * 1024,
                                                   backupCount=1, encoding="utf-8")
                os.chmod(path, 0o600)
            except OSError as error:
                print(f"Bridge diagnostic log unavailable: {error}", file=sys.stderr)

    def record(self, event, **fields):
        if self.handler is None:
            return
        data = {"event": event, "time": time.time(), "pid": os.getpid(),
                "run": os.environ.get("DEVICEHUB_RUN_ID", ""), **fields}
        record = logging.LogRecord("bridge", logging.INFO, "", 0,
                                   json.dumps(data, ensure_ascii=False), (), None)
        self.handler.handle(record)

    def close(self):
        if self.handler:
            self.handler.close()
            self.handler = None
