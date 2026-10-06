"""Inspect the composited canvas pixels, including WebGPU's presented image."""
import io
import math
import time

from PIL import Image


def wait_pixels(page, rectangle, predicate, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        rect = page.evaluate(rectangle) if isinstance(rectangle, str) else rectangle
        backend = page.evaluate("guavaDebug.backend")
        # Copying a WebGPU canvas into another canvas after presentation can
        # read its expired texture. Screenshot the browser's displayed image.
        image = Image.open(io.BytesIO(page.locator("#gpu" if backend == "webgpu" else "#fallback").screenshot())).convert("RGBA")
        ratio = image.width / page.evaluate("guavaDebug.snapshot.width")
        x, y, width, height = rect
        pixels = image.crop((math.floor(x * ratio), math.floor(y * ratio),
                             math.ceil((x + width) * ratio), math.ceil((y + height) * ratio))).getdata()
        if predicate(pixels):
            return
        page.wait_for_timeout(50)
    raise AssertionError(f"Expected displayed canvas pixels in {rectangle}; backend={backend}, gpu={page.evaluate('guavaDebug.gpuInfo')}")
