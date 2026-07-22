from pathlib import Path

import numpy as np
import pytest

from app.services.video_encoder import BrowserVideoEncoder, VideoEncodingError


class FakeWriter:
    def __init__(self):
        self.values = []
        self.closed = False

    def send(self, value):
        self.values.append(value)

    def close(self):
        self.closed = True


def make_encoder(tmp_path, *, width=32, height=24):
    writer = FakeWriter()
    factory_calls = []

    def writer_factory(path, size, **options):
        factory_calls.append((path, size, options))
        return writer

    encoder = BrowserVideoEncoder(
        output_path=tmp_path / "annotated.mp4",
        width=width,
        height=height,
        fps=25.0,
        writer_factory=writer_factory,
    )
    return encoder, writer, factory_calls


def test_encoder_streams_rgb_frames_and_returns_non_empty_output(tmp_path):
    encoder, writer, factory_calls = make_encoder(tmp_path)
    frame = np.zeros((24, 32, 3), dtype=np.uint8)
    frame[:, :, 0] = 255

    encoder.open()
    encoder.write(frame)
    encoder.output_path.write_bytes(b"mp4")
    result = encoder.close()

    assert factory_calls[0][0] == str(tmp_path / "annotated.mp4")
    assert factory_calls[0][1] == (32, 24)
    options = factory_calls[0][2]
    assert options["codec"] == "libx264"
    assert options["pix_fmt_out"] == "yuv420p"
    assert options["output_params"] == [
        "-movflags",
        "+faststart",
        "-preset",
        "veryfast",
    ]
    assert "audio_path" not in options
    assert "audio_codec" not in options
    assert writer.values[0] is None
    assert writer.values[1][0, 0].tolist() == [0, 0, 255]
    assert writer.closed is True
    assert result == tmp_path / "annotated.mp4"


def test_encoder_pads_odd_dimensions_without_scaling_source_pixels(tmp_path):
    encoder, writer, factory_calls = make_encoder(tmp_path, width=5, height=3)
    frame = np.full((3, 5, 3), (10, 20, 30), dtype=np.uint8)

    encoder.open()
    encoder.write(frame)

    assert factory_calls[0][1] == (6, 4)
    rgb = writer.values[1]
    assert rgb.shape == (4, 6, 3)
    assert rgb[0, 0].tolist() == [30, 20, 10]
    assert rgb[2, 4].tolist() == [30, 20, 10]
    assert rgb[3, 5].tolist() == [0, 0, 0]


def test_encoder_rejects_changed_frame_dimensions(tmp_path):
    encoder, _writer, _factory_calls = make_encoder(tmp_path)
    encoder.open()

    with pytest.raises(VideoEncodingError, match="dimensions"):
        encoder.write(np.zeros((12, 16, 3), dtype=np.uint8))

    encoder.abort()


def test_encoder_translates_writer_start_failure_and_removes_partial_output(
    tmp_path,
):
    output = tmp_path / "annotated.mp4"
    output.write_bytes(b"partial")

    def broken_writer(*_args, **_kwargs):
        raise RuntimeError("ffmpeg missing")

    encoder = BrowserVideoEncoder(
        output_path=output,
        width=32,
        height=24,
        fps=25.0,
        writer_factory=broken_writer,
    )

    with pytest.raises(VideoEncodingError, match="start"):
        encoder.open()

    assert not output.exists()


def test_encoder_rejects_empty_output_and_abort_removes_partial_file(tmp_path):
    encoder, writer, _factory_calls = make_encoder(tmp_path)
    encoder.open()

    with pytest.raises(VideoEncodingError, match="did not create"):
        encoder.close()

    encoder.output_path.write_bytes(b"partial")
    encoder.abort()

    assert writer.closed is True
    assert not encoder.output_path.exists()

