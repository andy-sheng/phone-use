"""Image IO only; recognition stays inside MaaFramework's native OpenCV runtime."""

from io import BytesIO
from pathlib import Path

import numpy as np
from PIL import Image

def decode_png(data: bytes):
    with Image.open(BytesIO(data)) as image:
        return np.ascontiguousarray(np.asarray(image.convert("RGB"))[:, :, ::-1])


def encode_png(image) -> bytes:
    buffer = BytesIO()
    Image.fromarray(image[:, :, ::-1]).save(buffer, format="PNG")
    return buffer.getvalue()


def save_png(path: Path, image):
    path.write_bytes(encode_png(image))
