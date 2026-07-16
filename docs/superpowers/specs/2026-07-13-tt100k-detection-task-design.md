# TT100K Local Model Detection Task Design

## Context

The repository contains a completed Ultralytics detection run at
`training/runs/tt100k_yolo11n_gpu/weights/best.pt`. The checkpoint loads as a
YOLO detection model and exposes 45 TT100K traffic-sign classes. The current
`sign-analyzer` API does not use this checkpoint: it calls an external service
when configured and otherwise returns hard-coded mock detections.

The application already has authenticated traffic-sign upload controls and ORM
models for detection scenes, model versions, detection tasks, and detection
results. The first implementation should connect these pieces without adding
WSL, Docker, Redis, Celery, PostgreSQL, or MinIO requirements.

## Goals

- Use the trained `best.pt` checkpoint for real local traffic-sign inference.
- Support the existing single-image and batch upload entry points.
- Persist the model registry entry, detection task, aggregate statistics, and
  each detected object in the existing ORM tables.
- Return class code, confidence, bounding box, image dimensions, inference
  time, and an annotated image URL.
- Allow an authenticated user to list their tasks and retrieve task details.
- Preserve the existing frontend response envelope while adding task metadata
  and annotated output.
- Prefer the NVIDIA GPU on this Windows machine and fall back to CPU only when
  CUDA is unavailable.

## Non-Goals

- Training or modifying the checkpoint.
- Detecting traffic lights; the trained checkpoint contains traffic-sign
  classes only, so `traffic_lights` remains an empty list.
- Asynchronous workers, distributed queues, live video, or camera inference.
- Reproducing PostgreSQL/MinIO behavior in local mode.
- Translating every TT100K category code into a Chinese road-sign name in this
  phase. The model's canonical class code remains authoritative.

## Runtime Configuration

Add explicit settings with project-relative defaults:

- `YOLO_MODEL_PATH=../training/runs/tt100k_yolo11n_gpu/weights/best.pt`
- `YOLO_DEVICE=auto`
- `YOLO_CONFIDENCE=0.25`
- `YOLO_IOU=0.45`
- `YOLO_IMAGE_SIZE=640`
- `YOLO_MAX_BATCH_IMAGES=20`
- `YOLO_MAX_IMAGE_BYTES=10485760`

Relative model paths are resolved against the backend directory, independent
of the shell's current directory. With `YOLO_DEVICE=auto`, the detector uses
CUDA device `0` when `torch.cuda.is_available()` is true and otherwise uses
CPU. An explicit `cpu` forces CPU; an explicit CUDA device fails clearly when
CUDA is unavailable. The service fails with a clear model-path error instead
of silently switching back to mock responses.

## Architecture

### Local YOLO Detector

A focused detector service owns checkpoint loading and prediction. It loads the
Ultralytics model lazily, caches one instance, and serializes calls with a lock
because a shared Ultralytics model is not assumed to be thread-safe. The model
is never loaded at Python module import time, keeping tests and management tools
lightweight.

The detector accepts decoded image bytes and inference parameters. It resolves
the runtime device once, records the selected device in its metadata, and
returns a
framework-neutral result containing image dimensions, timing, detections, and
annotated JPEG bytes. Ultralytics objects do not cross the service boundary.

### Detection Task Service

An orchestration service owns database state and output files. On first use it
ensures that these records exist:

- scene: `tt100k_traffic_signs`
- model version: `tt100k-yolo11n-v1`, pointing to the configured checkpoint

For each request it creates a `DetectionTask` in `processing` state, runs all
images through the detector, stores annotated images under
`backend/uploads/detections/<task-id>/`, writes one `DetectionResult` per
detected object, and finalizes aggregate counts and timing.

The task is committed before inference so a model or image failure can be
recorded as `failed`. A batch can retain successful image results while
reporting individual image errors; such a task completes with an error summary
in `error_message`.

### API Compatibility

The existing endpoints remain the frontend integration boundary:

- `POST /api/sign-analyzer/analyze`
- `POST /api/sign-analyzer/batch`

Both endpoints use the local task service. The response keeps `success`,
`message`, `data.time`, `traffic_signs`, `traffic_lights`, and batch totals.
Additional fields include `task_id`, model information, source filename,
annotated image URL, dimensions, and inference time.

Task history is exposed through:

- `GET /api/sign-analyzer/tasks`
- `GET /api/sign-analyzer/tasks/{task_id}`

Queries are always scoped to the authenticated user. Accessing another user's
task returns 404 rather than revealing its existence.

### Frontend

The existing chat trigger and upload controls remain unchanged. The store keeps
the human-readable summary used for persisted chat messages and also attaches
the structured response to the live assistant message. `ChatArea` renders a
compact result gallery with annotated images, class codes, confidence values,
and per-image errors. A page reload still has the persisted text summary; task
history restoration is handled by the task API and can be added to a dedicated
history view later.

## Data Flow

1. The authenticated user selects one or more images, a folder, or a ZIP file.
2. The API validates count, extension, decoded image content, and byte limits.
3. ZIP entries are bounded by entry count and total uncompressed image bytes.
4. The API creates one detection task for the request.
5. The detector runs each image with the task's confidence, IoU, and image-size
   settings.
6. Annotated JPEGs are written to local static storage.
7. Object rows and task totals are committed.
8. The API returns the compatibility envelope plus task and annotated results.
9. The frontend displays the structured results and persists a text summary in
   the conversation.

## Error Handling

- A missing or incompatible checkpoint returns a 503-style model-unavailable
  error and records a failed task when task creation has already occurred.
- CUDA initialization failure is logged with the selected device; `auto` falls
  back to CPU, while an explicit CUDA device returns a clear 503-style error.
- Unsupported, oversized, corrupt, or empty uploads return a 400 response.
- One corrupt image in a valid batch produces a per-image failure while valid
  images continue.
- File names are reduced to safe base names before writing annotated output.
- Temporary files are not required for inference; byte streams are decoded in
  memory.
- Logs include task IDs and model paths but never uploaded image bytes or JWTs.

## Testing

- Settings tests cover path resolution and inference defaults.
- Detector unit tests use a fake Ultralytics result to verify bbox, confidence,
  class, dimensions, timing, and annotated image conversion.
- Task-service tests use a fake detector and SQLite to verify registry creation,
  status transitions, aggregate fields, ownership, result rows, and output URLs.
- API tests verify authentication, validation, compatibility fields, task list,
  and task detail ownership.
- Frontend tests verify result formatting and structured rendering.
- A final smoke test runs one TT100K validation image through the real
  `best.pt`, confirms that no mock result is returned, checks persisted task
  rows, and verifies that the annotated URL is accessible.

## Rollout Boundary

This phase is complete when the real checkpoint can be exercised end to end
from the existing upload flow and the resulting task can be retrieved from the
database. Async execution, a dedicated task-history page, live video, model
upload management, and full TT100K label translation are follow-up increments.
