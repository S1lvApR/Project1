# Full-Timeline Video Detection and Playback Design

## Goal

Improve the existing asynchronous video workflow so that it detects traffic signs
throughout the complete source video and presents useful visual output while the task
is running and after it completes.

The implementation must satisfy both user-visible requirements:

1. A sign near the end of a video must not be missed because processing stopped after
   an early frame limit.
2. The UI must show a continuously refreshed annotated preview during processing and
   a browser-playable annotated video after processing.

The supplied acceptance video is
`C:/Users/Administrator/Pictures/示例视频.mp4`. It has 3,394 frames at 25 FPS and
contains a detectable `w57` (注意行人) sign near 133 seconds.

## Confirmed Interaction

The video result has two visual states:

- While the task is processing, it shows the latest available annotated frame in a
  stable 16:9 preview area. The preview refreshes through the existing status polling
  loop and remains visible alongside progress and current detection summaries.
- After the task completes, the preview is replaced by an HTML video player with
  controls. The user can play, seek, pause, enter fullscreen, and download the complete
  annotated MP4. Detected key frames remain available below the player.

This is asynchronous processing, not a promise that inference finishes at source-video
playback speed. "Live preview" means that the user sees the worker's current annotated
output as processing advances.

## Root Cause

The current worker samples every fifth frame but stops as soon as it has sampled 50
frames. For the supplied video this reads only source frames 0 through 245, or about
9.8 seconds of a 135.8-second video. The sign near 133 seconds can never reach the
model.

The current worker also converts every sampled OpenCV frame to JPEG, decodes it through
the still-image detector, plots it, and encodes it again. A 200-frame diagnostic showed
about 11 ms of model inference per frame on the GPU but only 0.48 frames per second of
end-to-end throughput. The still-image wrapper, plotting, and repeated image conversion
are therefore the main video-processing bottlenecks.

Finally, the backend saves isolated JPEG key frames only. It never creates an annotated
video URL, so the frontend has no playable result to render.

## Architecture

### Video-native detector path

`LocalYoloDetector` gains a video-frame method that accepts an OpenCV BGR ndarray and
returns dimensions, inference time, and the existing `DetectedObject` records. It calls
the already-loaded Ultralytics model directly and does not perform JPEG or Pillow
round-trips. It shares the existing model lock, device selection, class normalization,
and confidence/IoU/image-size settings.

The video path uses whole-frame YOLO inference at the configured high input resolution.
SAHI remains available for still images but is not used for every video frame because
its per-frame cost is unsuitable for the default video workflow.

GPU is the preferred profile. With no explicit sampling override, GPU processing runs
inference on every source frame. CPU mode may use a configured stride and briefly retain
the last detections between inference frames so that output boxes remain visible instead
of flashing for one frame. Retained detections expire at the next inference result or
after the configured short persistence window; this is display stabilization, not a
claim of object identity tracking.

### Full-timeline processor

`VideoDetectionService` continues to own task admission, persistence, and the background
worker, but its frame loop changes as follows:

1. Open and validate the source video.
2. Select inference indices over the complete timeline.
3. Read every source frame in order until end of stream.
4. Run video-native inference when the frame is selected.
5. Draw current boxes, Chinese sign meanings, class codes, and confidence values onto a
   copy of the frame.
6. Write every annotated or unmodified source frame to the output encoder.
7. Periodically publish the latest annotated frame as the live preview.
8. Save bounded, detection-bearing key frames and database records.
9. Finalize the MP4 and expose its URL only after encoding succeeds.

`max_frames` is retained for API compatibility but becomes an inference budget, not a
source-video cutoff. A positive limit lower than the source frame count produces evenly
distributed inference indices from the start through the end of the video. A value of
zero means no inference cap. Regardless of this budget, all readable source frames are
written to the annotated output video.

`sample_rate` remains an explicit minimum inference stride. The default becomes one for
the GPU-first local profile. If both `sample_rate` and `max_frames` constrain inference,
the service uses the larger effective stride while ensuring the final portion of the
timeline is represented.

Key frames are no longer saved for empty inference results. They are limited to useful
detection events, with a time-based deduplication interval and an overall cap so a sign
visible across many adjacent frames does not create hundreds of gallery entries.

### Browser-compatible encoder

The backend uses a repository-pinned FFmpeg runtime supplied by a Python package rather
than requiring a system FFmpeg installation, WSL, Docker, or Microsoft Store access.
The encoder receives raw BGR frames and produces H.264 video with `yuv420p` pixel format
and fast-start metadata. The annotated output intentionally contains no audio track.
The completed output is stored under the existing task-specific uploads directory and
served through `/uploads`.

Encoding is isolated behind a small interface so unit tests can use a fake encoder.
Subprocess stderr is written to a task-specific diagnostic file to avoid pipe deadlocks
and to preserve actionable failure details without exposing local paths to API clients.

### Live preview publication

The worker writes the preview JPEG to a temporary sibling and atomically replaces the
published file. This prevents status polling from loading a partially written image.
The progress payload contains:

- `stage`: `pending`, `detecting`, `finalizing`, `completed`, or `failed`;
- `preview_frame_url` and `preview_version`;
- `processed_frames`, `inference_frames`, and retained `sampled_frames` compatibility;
- `detected_frames`, `total_objects`, and timing/device metadata;
- `annotated_video_url` and `download_url` after successful finalization.

`preview_version` changes whenever the preview file changes. The frontend appends it as
a query parameter to bypass browser caching. Preview writes are rate-limited by frame
interval so they do not become another per-frame JPEG bottleneck.

## Frontend

`VideoDetectionResult` keeps its current status header, progress bar, metadata, class
counts, and key-frame gallery. It adds:

- a fixed-aspect live image region during `pending`, `detecting`, and `finalizing`;
- a clear placeholder before the first preview is available;
- an HTML `<video controls playsInline preload="metadata">` player after completion;
- an icon-and-text download command for the annotated MP4;
- stage-specific text so final encoding is not mistaken for a stalled detector.

The existing one-second polling loop is sufficient. The result message continues to be
updated in place, so no parallel message stream or WebSocket protocol is introduced.
Camera detection remains unchanged.

## Data and Compatibility

No database migration is required. Existing `DetectionTask` and `DetectionResult` rows
remain the durable task and detection records. New live and media fields are carried in
the video status payload and persisted in the existing terminal status JSON.

Existing clients that only read `status`, `progress`, `sampled_frames`, and `key_frames`
continue to work. Existing completed tasks without `annotated_video_url` continue to
render their key-frame gallery.

The output keeps source width, height, FPS, frame order, and duration within normal
codec tolerance. Odd source dimensions are padded or normalized for `yuv420p` without
distorting the visible frame.

## Failure Handling and Cleanup

- Invalid metadata, unreadable frames before any output, detector failures, encoder
  startup failures, broken encoder pipes, and mux failures mark the task failed with a
  readable public error.
- Partial MP4 files, temporary preview files, encoder intermediates, and source uploads
  are removed after failure. The final annotated video and key frames persist after
  success.
- `VideoCapture`, database sessions, encoder processes, file handles, task admission
  slots, and temporary directories are released in `finally` paths.
- A task is not reported completed until FFmpeg exits successfully and the final MP4 is
  non-empty.
- The status endpoint remains authenticated and user-scoped. API responses expose URLs,
  never local filesystem paths or raw FFmpeg command lines.

## Verification

Backend tests must prove:

- a low inference budget does not stop source reading or output encoding early;
- inference indices cover the complete timeline, including its final segment;
- ndarray frames reach the video detector without JPEG conversion;
- GPU defaults select every-frame inference;
- preview publication is atomic and updates its version;
- detection-bearing key frames are bounded and empty frames are omitted;
- successful finalization returns playable/downloadable media URLs;
- encoder and detector failures persist a failed task and clean partial artifacts;
- old terminal status payloads remain readable.

Frontend tests must prove:

- processing tasks render and refresh the live preview;
- finalizing has a distinct state;
- completed tasks render a video player and download command;
- older completed tasks without a video URL still render key frames;
- Chinese display labels and confidence values remain visible.

End-to-end verification uses the supplied example video and the configured 42-class
checkpoint. It must demonstrate all of the following:

1. Processing reaches the final source frame instead of stopping near ten seconds.
2. At least one `w57` / `注意行人` detection is recorded near 133 seconds.
3. The live preview URL changes while the task is running and serves non-empty JPEGs.
4. The completed MP4 has the expected duration and H.264/yuv420p media properties.
5. Chromium can load the completed video, seek near the detected timestamp, and display
   a non-blank annotated frame with no incoherent UI overlap at desktop and mobile
   widths.

## Completion Criteria

The work is complete only when the automated suites pass and the supplied video proves
full-timeline detection, live annotated progress, and browser playback of the completed
annotated video on the local Windows environment.
