# Full-Timeline Video Detection and Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Detect traffic signs across an entire uploaded video, publish an annotated live preview while processing, and return a browser-playable annotated MP4.

**Architecture:** Add a BGR-ndarray detector path and a focused FFmpeg encoder adapter, then rewrite the video worker around a full-timeline frame loop. The worker publishes atomic preview JPEGs and terminal media URLs through the existing polling payload; the React result component switches from live preview to an HTML video player after finalization.

**Tech Stack:** Python 3.10, FastAPI, OpenCV, Ultralytics 8.3, imageio-ffmpeg 0.6.0, SQLAlchemy, React 18, Zustand, pytest, Vitest, Playwright/Chromium.

---

## File Map

- Create backend/app/services/video_encoder.py for browser-compatible H.264 output.
- Create backend/tests/test_video_encoder.py for the encoder boundary.
- Modify backend/app/services/yolo_detector.py for ndarray video inference.
- Modify backend/app/services/video_detection_service.py for scheduling, preview, annotation, encoding, and status.
- Modify backend/app/config/settings.py and backend/.env.local.example for GPU-first defaults.
- Modify backend/app/api/detection.py to accept zero as an unlimited inference budget.
- Modify backend/requirements-core.txt to pin the bundled FFmpeg runtime.
- Modify backend/tests/test_yolo_detector.py, test_video_detection_service.py, and test_detection_api.py.
- Modify frontend/src/components/VideoDetectionResult.jsx for preview, finalization, playback, and download.
- Modify frontend API, store, and component tests for the expanded payload.
- Modify README.md and docs/windows-setup.md for the finished workflow.

### Task 1: Full-Timeline Inference Schedule and Configuration

**Files:**
- Modify: backend/app/config/settings.py
- Modify: backend/app/api/detection.py
- Modify: backend/.env.local.example
- Modify: backend/app/services/video_detection_service.py
- Test: backend/tests/test_video_detection_service.py
- Test: backend/tests/test_detection_api.py

- [ ] **Step 1: Write failing schedule and option tests**

Add these schedule cases:

~~~python
from app.services.video_detection_service import build_inference_schedule


def test_inference_schedule_covers_full_timeline_when_budget_is_limited():
    schedule = build_inference_schedule(
        3394,
        sample_rate=1,
        max_frames=50,
    )

    assert len(schedule) == 50
    assert schedule[0] == 0
    assert schedule[-1] == 3393
    assert all(left < right for left, right in zip(schedule, schedule[1:]))


def test_zero_budget_and_unit_stride_select_every_frame():
    assert build_inference_schedule(6, sample_rate=1, max_frames=0) == (
        0, 1, 2, 3, 4, 5,
    )


def test_explicit_stride_still_includes_final_frame():
    assert build_inference_schedule(8, sample_rate=3, max_frames=0) == (
        0, 3, 6, 7,
    )
~~~

Extend API tests so max_frames=0 is accepted and max_frames=-1 is rejected.

- [ ] **Step 2: Run tests and verify the old code fails**

~~~powershell
backend\.venv\Scripts\python.exe -m pytest backend/tests/test_video_detection_service.py backend/tests/test_detection_api.py -q
~~~

Expected: FAIL because the schedule helper is missing and zero is rejected.

- [ ] **Step 3: Implement the deterministic schedule**

~~~python
def build_inference_schedule(
    total_frames: int,
    *,
    sample_rate: int,
    max_frames: int,
) -> tuple[int, ...]:
    if total_frames <= 0:
        return ()
    if sample_rate < 1 or max_frames < 0:
        raise ValueError("sample_rate must be positive and max_frames non-negative")

    candidates = list(range(0, total_frames, sample_rate))
    if candidates[-1] != total_frames - 1:
        candidates.append(total_frames - 1)
    if max_frames == 0 or len(candidates) <= max_frames:
        return tuple(candidates)
    if max_frames == 1:
        return (total_frames - 1,)

    last = len(candidates) - 1
    positions = [
        round(index * last / (max_frames - 1))
        for index in range(max_frames)
    ]
    return tuple(candidates[position] for position in positions)
~~~

Use these settings:

~~~python
VIDEO_FRAME_SAMPLE_RATE: int = Field(default=1, ge=1)
VIDEO_MAX_FRAMES: int = Field(default=0, ge=0)
VIDEO_PREVIEW_INTERVAL_FRAMES: int = Field(default=10, ge=1)
VIDEO_KEY_FRAME_INTERVAL_SECONDS: float = Field(default=1.0, ge=0.0)
VIDEO_MAX_KEY_FRAMES: int = Field(default=100, ge=1, le=1000)
VIDEO_BOX_PERSISTENCE_FRAMES: int = Field(default=3, ge=0, le=30)
VIDEO_ANNOTATION_FONT_PATH: str = ""
~~~

Allow 0 <= resolved_max <= 100000 in the API and mirror the settings in the local environment template.

- [ ] **Step 4: Run focused tests**

Run the Step 2 command again. Expected: PASS.

- [ ] **Step 5: Commit Task 1**

~~~powershell
git add backend/app/config/settings.py backend/app/api/detection.py backend/.env.local.example backend/app/services/video_detection_service.py backend/tests/test_video_detection_service.py backend/tests/test_detection_api.py
git commit -m "fix: schedule video inference across full timeline"
~~~

### Task 2: Video-Native YOLO Frame Inference

**Files:**
- Modify: backend/app/services/yolo_detector.py
- Test: backend/tests/test_yolo_detector.py

- [ ] **Step 1: Write the failing ndarray inference tests**

~~~python
def test_video_frame_prediction_passes_bgr_array_directly_to_model(tmp_path):
    model_path = tmp_path / "best.pt"
    model_path.write_bytes(b"checkpoint")
    model = FakeModel()
    detector = LocalYoloDetector(
        model_path=model_path,
        device="auto",
        model_factory=lambda _path: model,
        cuda_available=lambda: True,
    )
    frame = np.zeros((24, 32, 3), dtype=np.uint8)

    prediction = detector.predict_video_frame(
        frame,
        confidence=0.5,
        iou=0.45,
        image_size=1280,
    )

    assert model.calls[0]["source"] is frame
    assert model.calls[0]["device"] == "0"
    assert prediction.width == 32
    assert prediction.height == 24
    assert prediction.inference_time_ms == 12.5
    assert prediction.detections[0].class_name == "pl60"
    assert not hasattr(prediction, "annotated_jpeg")
~~~

Also assert that a non-ndarray and a non-three-channel array fail before model loading.

- [ ] **Step 2: Run detector tests and verify failure**

~~~powershell
backend\.venv\Scripts\python.exe -m pytest backend/tests/test_yolo_detector.py -q
~~~

Expected: FAIL because the method and result type are missing.

- [ ] **Step 3: Implement the focused result type and method**

~~~python
@dataclass(frozen=True)
class VideoFramePrediction:
    width: int
    height: int
    inference_time_ms: float
    detections: tuple[DetectedObject, ...]


def predict_video_frame(
    self,
    frame: np.ndarray,
    *,
    confidence: float | None = None,
    iou: float | None = None,
    image_size: int | None = None,
    device: str | None = None,
) -> VideoFramePrediction:
    if not isinstance(frame, np.ndarray) or frame.ndim != 3 or frame.shape[2] != 3:
        raise InvalidImageError(
            "Video frame must be a BGR image with three channels"
        )
    resolved_device = self._resolve_requested_device(device)
    with self._lock:
        model = self._get_model_locked()
        try:
            results = model.predict(
                source=frame,
                conf=self.default_confidence if confidence is None else confidence,
                iou=self.default_iou if iou is None else iou,
                imgsz=self.default_image_size if image_size is None else image_size,
                device=resolved_device,
                verbose=False,
            )
        except Exception as exc:
            raise ModelUnavailableError(f"YOLO video inference failed: {exc}") from exc
        if not results:
            raise ModelUnavailableError(
                "YOLO inference returned no video-frame result"
            )
        result = results[0]
        height, width = getattr(result, "orig_shape", frame.shape[:2])
        return VideoFramePrediction(
            width=int(width),
            height=int(height),
            inference_time_ms=float(result.speed.get("inference", 0.0)),
            detections=self._convert_detections(result),
        )
~~~

Reuse existing device validation and canonical TT100K conversion.

- [ ] **Step 4: Run detector and camera regression tests**

~~~powershell
backend\.venv\Scripts\python.exe -m pytest backend/tests/test_yolo_detector.py backend/tests/test_camera_detection_service.py -q
~~~

Expected: PASS.

- [ ] **Step 5: Commit Task 2**

~~~powershell
git add backend/app/services/yolo_detector.py backend/tests/test_yolo_detector.py
git commit -m "perf: add ndarray video inference path"
~~~

### Task 3: Browser-Compatible Video Encoder

**Files:**
- Create: backend/app/services/video_encoder.py
- Create: backend/tests/test_video_encoder.py
- Modify: backend/requirements-core.txt

- [ ] **Step 1: Pin and install imageio-ffmpeg**

Add imageio-ffmpeg==0.6.0, then run:

~~~powershell
backend\.venv\Scripts\python.exe -m pip install imageio-ffmpeg==0.6.0
~~~

Expected: imageio_ffmpeg.get_ffmpeg_exe() returns an existing bundled executable.

- [ ] **Step 2: Write failing encoder contract tests**

Use a fake writer generator to prove startup, BGR-to-RGB conversion, odd-dimension
padding without scaling, shape validation, close validation, and abort cleanup. Assert
that the writer options contain neither audio_path nor audio_codec because annotated
outputs are intentionally silent.

~~~python
def test_encoder_streams_rgb_frames_and_returns_non_empty_output(tmp_path):
    calls = []
    writer = FakeWriter(calls)
    output = tmp_path / "annotated.mp4"
    encoder = BrowserVideoEncoder(
        output_path=output,
        width=32,
        height=24,
        fps=25.0,
        writer_factory=lambda *args, **kwargs: writer,
    )
    frame = np.zeros((24, 32, 3), dtype=np.uint8)
    frame[:, :, 0] = 255

    encoder.open()
    encoder.write(frame)
    output.write_bytes(b"mp4")
    result = encoder.close()

    assert calls[0] is None
    assert calls[1][0, 0].tolist() == [0, 0, 255]
    assert result == output
~~~

- [ ] **Step 3: Run encoder tests and verify failure**

~~~powershell
backend\.venv\Scripts\python.exe -m pytest backend/tests/test_video_encoder.py -q
~~~

Expected: FAIL because the module is missing.

- [ ] **Step 4: Implement the encoder boundary**

The public interface is:

~~~python
class VideoEncodingError(RuntimeError):
    pass


class BrowserVideoEncoder:
    def __init__(
        self,
        *,
        output_path: Path,
        width: int,
        height: int,
        fps: float,
        writer_factory=imageio_ffmpeg.write_frames,
    ):
        self.output_path = output_path
        self.width = width
        self.height = height
        self.output_width = width + width % 2
        self.output_height = height + height % 2
        self.fps = fps
        self.writer_factory = writer_factory
        self._writer = None

    def open(self) -> None:
        self.output_path.parent.mkdir(parents=True, exist_ok=True)
        options = {
            "fps": self.fps,
            "codec": "libx264",
            "pix_fmt_in": "rgb24",
            "pix_fmt_out": "yuv420p",
            "quality": 7,
            "macro_block_size": 2,
            "ffmpeg_log_level": "error",
            "output_params": [
                "-movflags", "+faststart", "-preset", "veryfast"
            ],
        }
        self._writer = self.writer_factory(
            str(self.output_path),
            (self.output_width, self.output_height),
            **options,
        )
        self._writer.send(None)

    def write(self, frame: np.ndarray) -> None:
        if frame.shape != (self.height, self.width, 3):
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
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        self._writer.send(np.ascontiguousarray(rgb))

    def close(self) -> Path:
        if self._writer is not None:
            self._writer.close()
            self._writer = None
        if not self.output_path.is_file() or self.output_path.stat().st_size == 0:
            raise VideoEncodingError("FFmpeg did not create a video")
        return self.output_path

    def abort(self) -> None:
        if self._writer is not None:
            self._writer.close()
            self._writer = None
        self.output_path.unlink(missing_ok=True)
~~~

Convert BGR with cv2.cvtColor, send a contiguous array, and translate writer failures
into VideoEncodingError. Do not pass source audio to the writer. close must require a
non-empty output. abort must close the generator and remove partial output.

- [ ] **Step 5: Run encoder tests and executable smoke check**

~~~powershell
backend\.venv\Scripts\python.exe -m pytest backend/tests/test_video_encoder.py -q
backend\.venv\Scripts\python.exe -c "from imageio_ffmpeg import get_ffmpeg_exe; from pathlib import Path; print(Path(get_ffmpeg_exe()).is_file())"
~~~

Expected: tests PASS and the smoke check prints True.

- [ ] **Step 6: Commit Task 3**

~~~powershell
git add backend/app/services/video_encoder.py backend/tests/test_video_encoder.py backend/requirements-core.txt
git commit -m "feat: add bundled H264 video encoder"
~~~

### Task 4: Full-Timeline Worker and Media Status

**Files:**
- Modify: backend/app/services/video_detection_service.py
- Test: backend/tests/test_video_detection_service.py
- Test: backend/tests/test_detection_api.py

- [ ] **Step 1: Write failing worker contract tests**

Use fake capture, detector, and encoder collaborators:

~~~python
def test_worker_encodes_every_frame_with_limited_inference_budget(service):
    service._process(
        task_id=7,
        filename="road.mp4",
        source_path=service.temp_dir / "7" / "source.mp4",
        confidence=0.5,
        iou=0.45,
        image_size=1280,
        sample_rate=1,
        max_frames=3,
    )

    assert service.capture.read_count == 11
    assert service.detector.frame_indexes == [0, 4, 9]
    assert service.encoder.frames_written == 10
    status = service.progress.get(7)
    assert status["status"] == "completed"
    assert status["processed_frames"] == 10
    assert status["inference_frames"] == 3
    assert status["annotated_video_url"].endswith("_annotated.mp4")
~~~

Add tests for atomic preview URL/version updates, bounded detection-only key frames, Chinese display labels, short persistence on skipped frames, encoder failure cleanup, and legacy terminal status loading.

- [ ] **Step 2: Run service tests and verify failure**

~~~powershell
backend\.venv\Scripts\python.exe -m pytest backend/tests/test_video_detection_service.py backend/tests/test_detection_api.py -q
~~~

Expected: FAIL because the old loop stops after the inference count and has no encoder or preview fields.

- [ ] **Step 3: Add focused helpers**

Add these private boundaries:

~~~python
@dataclass(frozen=True)
class VideoOutputPaths:
    task_dir: Path
    preview_path: Path
    video_path: Path


def _output_paths(self, task_id: int, filename: str) -> VideoOutputPaths:
    task_dir = self.output_dir / str(task_id)
    stem = re.sub(r"[^A-Za-z0-9._-]", "_", Path(filename).stem) or "video"
    return VideoOutputPaths(
        task_dir=task_dir,
        preview_path=task_dir / "preview.jpg",
        video_path=task_dir / f"{stem}_annotated.mp4",
    )


def _publish_preview(
    self,
    paths: VideoOutputPaths,
    frame: np.ndarray,
    frame_index: int,
) -> tuple[str, int]:
    encoded, jpeg = cv2.imencode(".jpg", frame)
    if not encoded:
        raise VideoProcessingError("Unable to encode video preview")
    temporary = paths.preview_path.with_suffix(".tmp.jpg")
    temporary.write_bytes(jpeg.tobytes())
    temporary.replace(paths.preview_path)
    return self._public_upload_url(paths.preview_path), frame_index


def _public_upload_url(self, path: Path) -> str:
    relative = path.resolve().relative_to(self.output_dir.resolve())
    return "/uploads/detections/" + relative.as_posix()


def _load_annotation_font(self):
    windows_dir = Path(os.environ.get("WINDIR", "C:/Windows"))
    configured = settings.VIDEO_ANNOTATION_FONT_PATH.strip()
    candidates = ([Path(configured)] if configured else []) + [
        windows_dir / "Fonts" / "msyh.ttc",
        windows_dir / "Fonts" / "simhei.ttf",
    ]
    for candidate in candidates:
        if candidate.is_file():
            return ImageFont.truetype(str(candidate), size=22)
    return ImageFont.load_default()


def _draw_utf8_label(
    self,
    canvas: np.ndarray,
    label: str,
    x: int,
    y: int,
) -> np.ndarray:
    image = Image.fromarray(cv2.cvtColor(canvas, cv2.COLOR_BGR2RGB))
    draw = ImageDraw.Draw(image)
    left, top, right, bottom = draw.textbbox(
        (0, 0), label, font=self._annotation_font
    )
    text_height = bottom - top
    text_width = right - left
    text_top = max(0, y - text_height - 8)
    draw.rectangle(
        (x, text_top, x + text_width + 8, text_top + text_height + 8),
        fill=(0, 210, 40),
    )
    draw.text(
        (x + 4, text_top + 4),
        label,
        font=self._annotation_font,
        fill=(0, 0, 0),
    )
    return cv2.cvtColor(np.asarray(image), cv2.COLOR_RGB2BGR)


def _annotate_frame(self, frame: np.ndarray, detections) -> np.ndarray:
    canvas = frame.copy()
    for detection in detections:
        x1, y1, x2, y2 = (round(value) for value in detection.bbox)
        cv2.rectangle(canvas, (x1, y1), (x2, y2), (0, 210, 40), 2)
        display_name = tt100k_label_zh(detection.class_name) or detection.class_name
        label = f"{display_name} ({detection.class_name}) {detection.confidence:.0%}"
        canvas = self._draw_utf8_label(canvas, label, x1, y1)
    return canvas


def _should_save_key_frame(self, timestamp: float, key_frames: list[dict]) -> bool:
    if len(key_frames) >= settings.VIDEO_MAX_KEY_FRAMES:
        return False
    if not key_frames:
        return True
    return timestamp - key_frames[-1]["timestamp"] >= (
        settings.VIDEO_KEY_FRAME_INTERVAL_SECONDS
    )

Initialize self._annotation_font = self._load_annotation_font() in the service
constructor after configuration paths are assigned.
~~~

_publish_preview writes preview.tmp.jpg and atomically replaces preview.jpg. It returns /uploads/detections/{task_id}/preview.jpg and frame_index.

- [ ] **Step 4: Rewrite the complete-timeline loop**

Use this control flow:

~~~python
schedule = set(build_inference_schedule(
    total_frames,
    sample_rate=sample_rate,
    max_frames=max_frames,
))
encoder.open()
while True:
    readable, frame = capture.read()
    if not readable:
        break
    processed_frames += 1

    if frame_index in schedule:
        prediction = self.detector.predict_video_frame(
            frame,
            confidence=confidence,
            iou=iou,
            image_size=image_size,
            device=self.detector.selected_device,
        )
        inference_frames += 1
        active_detections = prediction.detections
        persistence_remaining = settings.VIDEO_BOX_PERSISTENCE_FRAMES
        # Persist records and bounded key frames only for non-empty detections.
    elif persistence_remaining > 0:
        persistence_remaining -= 1
    else:
        active_detections = ()

    annotated = self._annotate_frame(frame, active_detections)
    encoder.write(annotated)
    if (
        frame_index % settings.VIDEO_PREVIEW_INTERVAL_FRAMES == 0
        or active_detections
    ):
        preview_url, preview_version = self._publish_preview(
            paths, annotated, frame_index
        )
    self._update_running_progress(
        task_id=task_id,
        processed_frames=processed_frames,
        inference_frames=inference_frames,
        total_frames=total_frames,
        detected_frames=detected_frames,
        total_objects=total_objects,
        total_inference_time=total_inference_time,
        key_frames=key_frames,
        preview_frame_url=preview_url,
        preview_version=preview_version,
    )
    frame_index += 1

self.progress.update(task_id, stage="finalizing", progress=96)
final_path = encoder.close()
~~~

Detection progress occupies 1-95. Completion is reported only after a non-empty MP4 exists.

Initial and terminal payloads include:

~~~python
{
    "stage": "pending",
    "preview_frame_url": None,
    "preview_version": 0,
    "inference_frames": 0,
    "sampled_frames": 0,
    "detected_frames": 0,
    "annotated_video_url": None,
    "download_url": None,
}
~~~

sampled_frames remains an alias for inference_frames.

- [ ] **Step 5: Run backend video regression tests**

~~~powershell
backend\.venv\Scripts\python.exe -m pytest backend/tests/test_video_detection_service.py backend/tests/test_detection_api.py backend/tests/test_yolo_detector.py backend/tests/test_video_encoder.py -q
~~~

Expected: PASS.

- [ ] **Step 6: Commit Task 4**

~~~powershell
git add backend/app/services/video_detection_service.py backend/tests/test_video_detection_service.py backend/tests/test_detection_api.py
git commit -m "feat: produce full annotated video with live preview"
~~~

### Task 5: Live Preview and Completed Player

**Files:**
- Modify: frontend/src/components/VideoDetectionResult.jsx
- Modify: frontend/src/api/detection.js
- Test: frontend/tests/components/VideoDetectionResult.test.js
- Test: frontend/tests/api/detection.test.js
- Test: frontend/tests/store/videoDetection.test.js

- [ ] **Step 1: Write failing UI state tests**

~~~javascript
it('renders a cache-busted live preview while detecting', () => {
  const html = renderToStaticMarkup(createElement(VideoDetectionResult, {
    data: {
      status: 'processing',
      stage: 'detecting',
      progress: 42,
      preview_frame_url: '/uploads/detections/19/preview.jpg',
      preview_version: 210,
      processed_frames: 211,
      inference_frames: 211,
      key_frames: [],
    },
  }))

  expect(html).toContain('/uploads/detections/19/preview.jpg?v=210')
  expect(html).toContain('实时检测画面')
})

it('renders finalization without a completed player', () => {
  const html = renderToStaticMarkup(createElement(VideoDetectionResult, {
    data: {
      status: 'processing',
      stage: 'finalizing',
      progress: 96,
      key_frames: [],
    },
  }))
  expect(html).toContain('正在生成可播放视频')
  expect(html).not.toContain('<video')
})

it('renders completed playback and download', () => {
  const html = renderToStaticMarkup(createElement(VideoDetectionResult, {
    data: {
      status: 'completed',
      annotated_video_url: '/uploads/detections/20/road_annotated.mp4',
      download_url: '/uploads/detections/20/road_annotated.mp4',
      key_frames: [],
    },
  }))
  expect(html).toContain('<video')
  expect(html).toContain('controls=""')
  expect(html).toContain('download=""')
})
~~~

Retain a legacy completed-task test without a media URL.

- [ ] **Step 2: Run focused frontend tests and verify failure**

~~~powershell
D:\Project1-main1\.runtime\node\npm.cmd run test:run -- tests/components/VideoDetectionResult.test.js tests/api/detection.test.js tests/store/videoDetection.test.js
~~~

Expected: FAIL because the component has no preview or player.

- [ ] **Step 3: Implement the visual states**

~~~javascript
function versionedPreviewUrl(url, version) {
  if (!url) return null
  const separator = url.includes('?') ? '&' : '?'
  return url + separator + 'v=' + encodeURIComponent(version || 0)
}

const previewUrl = versionedPreviewUrl(
  data?.preview_frame_url,
  data?.preview_version,
)
const isFinalizing =
  data?.status === 'processing' && data?.stage === 'finalizing'
const videoUrl =
  data?.status === 'completed' ? data?.annotated_video_url : null
~~~

Render a fixed aspect-video region. Processing shows the preview image or a loading placeholder. Completion shows:

~~~jsx
<video
  className="aspect-video w-full bg-black object-contain"
  src={videoUrl}
  controls
  playsInline
  preload="metadata"
/>
~~~

Use the Lucide Download icon for the download link. Keep the key-frame gallery and display inference_frames with sampled_frames fallback. Keep all visible Chinese strings valid UTF-8.

- [ ] **Step 4: Run tests and focused lint**

~~~powershell
D:\Project1-main1\.runtime\node\npm.cmd run test:run -- tests/components/VideoDetectionResult.test.js tests/api/detection.test.js tests/store/videoDetection.test.js
D:\Project1-main1\.runtime\node\npx.cmd eslint src/components/VideoDetectionResult.jsx src/api/detection.js
~~~

Expected: PASS.

- [ ] **Step 5: Commit Task 5**

~~~powershell
git add frontend/src/components/VideoDetectionResult.jsx frontend/src/api/detection.js frontend/tests/components/VideoDetectionResult.test.js frontend/tests/api/detection.test.js frontend/tests/store/videoDetection.test.js
git commit -m "feat: show live video preview and annotated playback"
~~~

### Task 6: Documentation and Real Acceptance

**Files:**
- Modify: README.md
- Modify: docs/windows-setup.md
- Modify: implementation and tests only when verification exposes a concrete defect

- [ ] **Step 1: Document the completed workflow**

Explain asynchronous full-timeline processing, GPU every-frame defaults, zero as unlimited inference, bundled FFmpeg, live preview, final MP4, and output locations.

- [ ] **Step 2: Run complete automated verification**

~~~powershell
backend\.venv\Scripts\python.exe -m pytest backend/tests -q
backend\.venv\Scripts\python.exe -m pip check
D:\Project1-main1\.runtime\node\npm.cmd run lint
D:\Project1-main1\.runtime\node\npm.cmd run test:run
D:\Project1-main1\.runtime\node\npm.cmd run build
~~~

Expected: every command exits zero.

- [ ] **Step 3: Run the supplied video with the real GPU model**

Start local services with the configured 42-class model and upload C:\Users\Administrator\Pictures\示例视频.mp4. Poll to completion and save diagnostics under .runtime/diagnostics.

Verify:

~~~text
processed_frames = 3394, or the decoder-confirmed readable count
status = completed
stage = completed
at least one detection has class_name = w57 and display_name = 注意行人
the w57 timestamp is near 133 seconds
preview_frame_url and annotated_video_url return HTTP 200
annotated MP4 duration is approximately 135.76 seconds
video codec is H.264 and pixel format is yuv420p
~~~

- [ ] **Step 4: Verify browser playback with Playwright**

At 1440x900 and 390x844:

1. Open the local app and authenticate.
2. Upload the sample or open its completed result.
3. Capture processing and completed screenshots.
4. Assert preview natural dimensions are non-zero.
5. Assert video loadedmetadata, duration above 130 seconds, seek near 133 seconds, and non-zero videoWidth/videoHeight.
6. Assert progress, player controls, and download action do not overlap.

- [ ] **Step 5: Review and commit documentation or verification fixes**

~~~powershell
git diff --check
git status --short
git add README.md docs/windows-setup.md
git commit -m "docs: explain full video detection workflow"
~~~

- [ ] **Step 6: Review and integrate**

Use superpowers:requesting-code-review, resolve high-confidence findings, rerun Task 6 verification, then use superpowers:finishing-a-development-branch to merge codex/video-detection-playback into feature/tt100k-training without touching unrelated untracked files.
