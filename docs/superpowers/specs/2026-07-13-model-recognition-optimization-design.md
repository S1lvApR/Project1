# Traffic-Sign Recognition Model Optimization Design

## Context

The application currently uses a 45-class TT100K YOLO11n detector trained on
full street-view scenes. The reported examples in `Test/` are 12,630 cropped
GTSRB classification images, not TT100K street scenes. Direct experiments with
the current checkpoint produced no boxes for `Test/00000.png` and
`Test/00006.png`, even at very low confidence thresholds and larger inference
sizes. The current run also has weak validation metrics (approximately 0.08
recall and 0.044 mAP50).

Two data-integrity issues were found in the existing TT100K preparation:

- TT100K's official `other` split is the validation set, but the converter
  treats it as unknown and randomly distributes it across train, validation,
  and test.
- The 45-class vocabulary is selected from counts over all annotations. The
  vocabulary must be fixed independently of validation and test data.

The current local TT100K annotation archive contains 6,103 `train`, 7,641
`other`, and 3,067 `test` records. The six-image difference from the current
Ultralytics documentation (6,105 / 7,641 / 3,071) is a property of the local
source archive and must be reported, not hidden by generated splits.

The `Test/GT-final_test.csv` file is empty. Ground truth from the verified
GTSRB archive (MD5 `fe31e9c9270bbcd7b84b7f21a9d9d9e5`) establishes these
regression labels:

- `Test/00000.png`: class 16, `Vehicles over 3.5 metric tons prohibited`
- `Test/00006.png`: class 18, `General caution`

## Goals

- Correctly recognize cropped GTSRB traffic-sign images, including both user
  examples.
- Improve TT100K street-scene detection with a correctly prepared dataset and
  a fresh GPU training run.
- Keep the existing authenticated upload, task persistence, annotated image,
  and frontend result flows.
- Route compact sign crops to classification and street scenes to detection.
- Measure quality on held-out data and promote a new checkpoint only when it
  beats the recorded baseline.
- Prefer CUDA device `0` on this machine while preserving CPU fallback.

## Non-Goals

- Treating the GTSRB test images as training data.
- Making one detector handle both cropped classification samples and full road
  scenes through confidence-threshold changes.
- Supporting video or live cameras in this increment.
- Merging TT100K and GTSRB class IDs into one artificial taxonomy. Each model
  retains its source dataset's canonical classes and supplies a display label.
- Training all 221 sparse TT100K categories in this optimization pass.

## Approaches Considered

### 1. Lower the detector threshold or pad crop images

This is rejected. Experiments down to near-zero confidence produced either no
boxes or unrelated low-confidence classes. It would increase false positives
without solving the task mismatch.

### 2. Retrain only the TT100K detector

This fixes street-scene quality and dataset leakage but does not make a
detection model reliable on GTSRB crops. It cannot satisfy the supplied-image
acceptance criteria.

### 3. Dual detector and classifier pipeline (selected)

A corrected TT100K detector handles full scenes, while a GTSRB classifier
handles compact single-sign crops. Both use the existing local GPU runtime and
feed one compatible API result shape. This directly matches both input
distributions and allows each model to be evaluated on the correct benchmark.

## Dataset Design

### TT100K Detection Dataset

The converter must map source folders exactly:

- `train` -> `train`
- `other` -> `val`
- `val` or `valid` -> `val`
- `test` -> `test`

Unknown folders may use generated ratios only when no official split name is
present. The standard 45-class TT100K vocabulary currently exposed by the API
is frozen in a canonical list, rather than recomputed from validation or test
annotations. Conversion writes to a new versioned output directory so the
existing dataset and checkpoint remain available for rollback.

The generated dataset validator checks:

- image/label stem parity for every split;
- no image identity overlap between train, validation, and test;
- class IDs within `0..44`;
- normalized boxes within `0..1` with positive width and height;
- expected local-source split counts and a report of missing source images;
- non-empty label and object counts per class and split.

### GTSRB Classification Dataset

The 187,490,228-byte `GTSRB-Training_fixed.zip` archive is acquired through
the `torchvision.datasets.GTSRB` source URL and verified with torchvision's MD5
`513f3c79a4c5141765e10e952eaa2478`.

The official training archive is split into train and validation sets by
physical sign track, stratified within each of the 43 classes. Images from one
track must never cross the train/validation boundary. The prepared Ultralytics
classification layout is:

```text
training/datasets/gtsrb_cls/
  train/00..42/
  val/00..42/
```

Project `Test/` remains a read-only held-out test set. Its zero-byte CSV is
replaced only from the checksum-verified official ground-truth archive; none of
its images may be copied into train or validation.

## Model Training

### GTSRB Classifier

- Start from an Ultralytics pretrained classification checkpoint compatible
  with the installed package, preferring `yolo11n-cls.pt`.
- Train all 43 classes on CUDA device `0` with deterministic seeds.
- Start with `imgsz=128`, `batch=128`, and 50 epochs; lower batch size only on
  a measured CUDA out-of-memory failure.
- Preserve aspect-ratio variation through the library's resize/crop pipeline
  and use moderate brightness, rotation, perspective, and scale augmentation.
- Select `best.pt` by validation top-1 accuracy.
- Evaluate once on all 12,630 project `Test/` images after training.

### TT100K Detector

- Start a fresh run from a pretrained YOLO11n detector; do not resume the
  contaminated-split checkpoint.
- Train the fixed 45-class dataset on CUDA device `0` for up to 100 epochs,
  starting at `imgsz=1280`, `batch=4`, as recommended for small TT100K signs.
- Record a baseline by evaluating the old checkpoint on the corrected
  validation split before training.
- Use early stopping and retain `best.pt` by validation mAP50-95.
- Promote the new checkpoint only if recall and mAP50-95 do not regress and at
  least one improves by 10% relative to the corrected-split baseline.

## Runtime Architecture

### Classifier Service

A lazy, locked `LocalSignClassifier` mirrors the existing detector boundary.
It decodes image bytes, runs the classification checkpoint, and returns a
framework-neutral result with class ID, canonical class name, display label,
confidence, dimensions, timing, and annotated JPEG bytes. Ultralytics objects
do not cross the service boundary.

### Recognition Router

The API accepts an optional `mode` value:

- `auto` (default)
- `detect`
- `classify`

In `auto`, an image whose longest side is at most 512 pixels is treated as a
compact crop and classified. Larger images use the TT100K detector. The chosen
mode is returned as `recognition_mode`. Explicit mode remains available for
unusual high-resolution crops or small street scenes.

Classification returns one `traffic_signs` item using the full image as its
bounding box. This preserves task/result persistence and frontend rendering
without pretending that the classifier localized an object. The item includes
`result_type: classification`; detector results use
`result_type: detection`.

### Model Registry and Rollback

Detector and classifier checkpoints are registered as distinct model versions.
Configuration contains separate paths and image sizes. The current TT100K
checkpoint remains untouched until the corrected model passes its promotion
gate. Failure to load one model affects only requests routed to that model and
returns a clear model-unavailable error.

## API and Frontend Compatibility

The existing `/api/sign-analyzer/analyze` and `/batch` endpoints remain the
integration boundary. New response fields are additive:

- `recognition_mode`
- `result_type`
- model family and dataset
- canonical class name and human-readable display label

The frontend shows the display label, confidence, selected mode, model device,
and annotated image. Existing TT100K class codes remain available for stored
history and API consumers.

## Testing

Implementation follows red-green-refactor:

- Converter tests prove `other -> val` and official splits are never randomly
  redistributed.
- Dataset tests prove no split overlap and track-grouped GTSRB validation.
- Classifier unit tests cover lazy loading, CUDA selection, top-1 conversion,
  annotation, corrupt images, and missing checkpoints.
- Router tests cover automatic compact/scene routing and explicit overrides.
- Task/API tests prove both model types persist and preserve response
  compatibility.
- Frontend tests cover classification and detection labels without layout
  regressions.
- Real checkpoint regression requires correct predictions for class 16 on
  `00000.png` and class 18 on `00006.png`.
- Full GTSRB evaluation reports top-1 accuracy, per-class recall, and a
  confusion matrix over all 12,630 images.
- Corrected TT100K evaluation records precision, recall, mAP50, and mAP50-95
  against the old and new checkpoints on the same validation split.

## Acceptance Criteria

- `Test/00000.png` is recognized as GTSRB class 16.
- `Test/00006.png` is recognized as GTSRB class 18.
- GTSRB full-test top-1 accuracy is at least 95%, with no class having zero
  recall.
- TT100K dataset validation passes with `other` entirely assigned to `val` and
  no cross-split overlap.
- The new TT100K checkpoint passes the promotion rule against the old model on
  the corrected validation set.
- Single and batch uploads return real classifier/detector results on GPU and
  task details remain retrievable.
- Backend tests, frontend tests, frontend production build, package checks, and
  real HTTP smoke tests all pass.

## Operational Notes

Training artifacts and downloaded archives remain under `training/` and are not
committed. Scripts emit reproducible commands, seeds, source URLs, checksums,
dataset statistics, and final metrics. Long GPU jobs write logs and checkpoints
under versioned run directories so progress can be resumed after interruption.
