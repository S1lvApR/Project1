from pathlib import Path
from typing import Callable

import cv2
import imageio_ffmpeg
import numpy as np


class VideoEncodingError(RuntimeError):
    pass


class BrowserVideoEncoder:
    """Stream BGR frames into a silent browser-compatible H.264 MP4."""

    def __init__(
        self,
        *,
        output_path: str | Path,
        width: int,
        height: int,
        fps: float,
        writer_factory: Callable = imageio_ffmpeg.write_frames,
    ):
        if width <= 0 or height <= 0 or fps <= 0:
            raise ValueError("Video dimensions and FPS must be positive")
        self.output_path = Path(output_path)
        self.width = int(width)
        self.height = int(height)
        self.output_width = self.width + self.width % 2
        self.output_height = self.height + self.height % 2
        self.fps = float(fps)
        self.writer_factory = writer_factory
        self._writer = None

    def open(self) -> None:
        if self._writer is not None:
            raise VideoEncodingError("Video encoder is already open")
        self.output_path.parent.mkdir(parents=True, exist_ok=True)
        self.output_path.unlink(missing_ok=True)
        try:
            self._writer = self.writer_factory(
                str(self.output_path),
                (self.output_width, self.output_height),
                fps=self.fps,
                codec="libx264",
                pix_fmt_in="rgb24",
                pix_fmt_out="yuv420p",
                quality=7,
                macro_block_size=2,
                ffmpeg_log_level="error",
                output_params=[
                    "-movflags",
                    "+faststart",
                    "-preset",
                    "veryfast",
                ],
            )
            self._writer.send(None)
        except Exception as exc:
            self._writer = None
            self.output_path.unlink(missing_ok=True)
            raise VideoEncodingError(
                f"Unable to start H.264 video encoder: {exc}"
            ) from exc

    def write(self, frame: np.ndarray) -> None:
        if self._writer is None:
            raise VideoEncodingError("Video encoder is not open")
        if (
            not isinstance(frame, np.ndarray)
            or frame.shape != (self.height, self.width, 3)
        ):
            raise VideoEncodingError("Video frame dimensions changed")
        if self.output_width != self.width or self.output_height != self.height:
            frame = cv2.copyMakeBorder(
                frame,
                0,
                self.output_height - self.height,
                0,
                self.output_width - self.width,
                cv2.BORDER_CONSTANT,
                value=(0, 0, 0),
            )
        rgb = np.ascontiguousarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
        try:
            self._writer.send(rgb)
        except Exception as exc:
            raise VideoEncodingError(
                f"Unable to encode video frame: {exc}"
            ) from exc

    def close(self) -> Path:
        if self._writer is None:
            raise VideoEncodingError("Video encoder is not open")
        writer = self._writer
        self._writer = None
        try:
            writer.close()
        except Exception as exc:
            self.output_path.unlink(missing_ok=True)
            raise VideoEncodingError(
                f"Unable to finalize H.264 video: {exc}"
            ) from exc
        if not self.output_path.is_file() or self.output_path.stat().st_size == 0:
            self.output_path.unlink(missing_ok=True)
            raise VideoEncodingError("FFmpeg did not create a video")
        return self.output_path

    def abort(self) -> None:
        writer = self._writer
        self._writer = None
        if writer is not None:
            try:
                writer.close()
            except Exception:
                pass
        self.output_path.unlink(missing_ok=True)

