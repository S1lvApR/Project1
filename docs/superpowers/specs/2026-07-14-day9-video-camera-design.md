# Day 9 Video and Camera Detection Design

## Scope

Implement the Day 9 workflow described in the repository tutorial for the current React + FastAPI application:

- asynchronous local video detection with progress polling and annotated key frames;
- a standalone camera detection page using a WebSocket;
- explicit auto, GPU, and CPU modes;
- chat upload and result rendering for videos;
- a small detection-agent adapter for video tasks.

The existing image workflow remains compatible. It continues to use the current `DetectionTaskService`, TT100K label mapping, classifier routing, local SQLite mode, and local `/uploads` static files.

## Local Windows Adaptation

The tutorial assumes Redis, MinIO, and ffmpeg. This project is also required to run without WSL or Docker, so the local implementation uses:

- SQLite `DetectionTask` rows for task ownership and final statistics;
- a process-local, thread-safe progress registry for live polling state;
- local files under `backend/uploads/videos` for temporary input and under the existing detection output directory for annotated key frames;
- OpenCV `VideoCapture` for supported files, with no mandatory transcoding step.

Redis and MinIO remain untouched for production profiles. The feature must not import or connect to either service in local mode.

## Backend Design

### Video service

Add `VideoDetectionService` with a bounded `ThreadPoolExecutor`. Submission creates a normal `DetectionTask` with `task_type="video"`, stores the upload in a task-specific temporary directory, and returns immediately. A worker:

1. opens the video and validates frame count, fps, dimensions, and duration;
2. samples every `VIDEO_FRAME_SAMPLE_RATE` source frames, capped by `VIDEO_MAX_FRAMES`;
3. runs the detector in realtime mode, which bypasses SAHI and uses the already-loaded Ultralytics model;
4. saves only successful sampled annotated frames;
5. persists each detection as a `DetectionResult` with the source filename and frame index encoded in `image_path`;
6. updates task totals and the live progress record after every sampled frame;
7. marks the task completed or failed and removes the temporary source file.

The progress payload includes status, percent, processed frames, sampled frames, total frames, fps, duration, dimensions, object count, average inference time, device, key frames, and error. Key-frame payloads use the same detection item shape as image results and include an absolute frame number and timestamp.

### Detector realtime path

Add a `predict_realtime` method to `LocalYoloDetector`. It uses the ordinary YOLO prediction path even when the normal image path has SAHI enabled. The method shares the process-local model and lock, keeps the selected GPU device, and returns the existing `ImagePrediction` contract. Add a lightweight warmup method for camera configuration.

### HTTP API

Add `backend/app/api/detection.py` and register it in `backend/main.py`:

- `POST /api/detection/video`: authenticated multipart upload, 50 MB limit, supported video extension check, confidence/IoU/image-size validation, returns the task id and initial progress;
- `GET /api/detection/video/status/{task_id}`: authenticated and user-scoped progress/result polling;
- `WS /api/detection/camera`: token query parameter authentication, first message must be JSON config, then sequential base64 JPEG frames and JSON responses.

The WebSocket intentionally processes one frame per receive and sends one response before reading the next frame. This is response-driven backpressure and prevents CPU or GPU queues from growing without bound. Camera mode selects the requested device, uses lower resolution for CPU, returns annotated JPEG data, detections, device, inference time, and rolling FPS, and closes resources on disconnect.

### Agent adapter

Add `backend/app/agent/detection_agent.py` with a dependency-light `detect_video_file` function that submits a local video through `VideoDetectionService`. The API calls this adapter so the video operation has a stable tool boundary without introducing a new agent framework or requiring an LLM connection.

## Frontend Design

- Add `frontend/src/api/detection.js` for authenticated video upload, status polling, and camera WebSocket URL construction.
- Extend the Zustand store with `detectVideo`, which adds a user upload message, creates a progress message, polls until completion, and replaces it with a result message without blocking unrelated chat state.
- Add a video upload control to the traffic-sign upload card and render `VideoDetectionResult` with progress, metadata, class counts, annotated key frames, and errors.
- Add `/camera` and a `CameraDetection` page. The page owns `getUserMedia`, canvas rendering, WebSocket lifecycle, mode selection, confidence, start/stop controls, connection state, FPS, inference time, and current detections.
- Add a camera navigation control and enable WebSocket proxying in Vite.

The UI follows the current dark operational style, uses existing Lucide icons, and remains usable on narrow screens. The camera loop sends the next canvas frame only after the prior response arrives.

## Failure and Security Rules

- Reject unauthenticated or cross-user task status requests.
- Reject unsupported formats and files larger than 50 MB before scheduling work.
- Never trust client-supplied filenames or paths.
- Convert worker exceptions into a failed task and a readable status payload.
- Do not expose raw filesystem paths in API responses.
- Always release `VideoCapture`, WebSocket camera state, temporary files, and executor futures.

## Verification

Backend tests cover upload validation, task ownership, progress transitions, frame sampling, cleanup, realtime detector routing, and WebSocket protocol behavior with fake detector/video collaborators. Frontend tests cover API request shape, result rendering, video upload state, camera client behavior, and route importability. The final audit runs both suites, builds the frontend, checks the health endpoint, and performs a real local sample-video inference when the configured checkpoint is available.
