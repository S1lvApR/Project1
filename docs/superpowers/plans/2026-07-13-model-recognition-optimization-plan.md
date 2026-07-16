# Traffic-Sign Recognition Model Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add a validated GTSRB crop-classification path, repair TT100K split conversion, retrain both models on the local GPU, and expose both through the existing sign-recognition API.

**Architecture:** Keep the TT100K detector as a lazy model service and add a matching lazy GTSRB classifier. A recognition router chooses the classifier for compact crops and the detector for full scenes. The existing task service persists both through the current result contract, with additive mode and model metadata.

**Tech Stack:** Python 3.10, FastAPI, SQLAlchemy, Pillow/OpenCV, Ultralytics YOLO11, PyTorch CUDA 12.8, pytest, Vitest, PowerShell.

**Portable path:** `$PROJECT_ROOT` denotes the repository root in all commands and examples.

---

## Execution Rules

- Preserve unrelated dirty files in the current branch.
- Use TDD for every production behavior: write one focused failing test, run it and confirm the expected failure, implement the smallest change, then rerun focused and full tests.
- Never copy anything from `Test/` into train or validation data. It is read-only evaluation input.
- Use versioned dataset and run directories. Do not overwrite `training/runs/tt100k_yolo11n_gpu`.
- Keep archives, generated datasets, checkpoints, metrics, and runtime databases untracked.

## File Map

- Modify `backend/tools/prepare_tt100k.py` and `backend/tests/test_prepare_tt100k.py` for official split mapping and the frozen common-45 vocabulary.
- Create `backend/tools/prepare_gtsrb.py`, `backend/tests/test_prepare_gtsrb.py`, `backend/tools/evaluate_gtsrb.py`, and `backend/tests/test_evaluate_gtsrb.py` for GTSRB data preparation and held-out evaluation.
- Create `backend/app/services/gtsrb_labels.py`, `backend/app/services/gtsrb_classifier.py`, and `backend/tests/test_gtsrb_classifier.py`.
- Modify `backend/app/config/settings.py` and `backend/.env.local.example` for classifier and router settings.
- Create `backend/app/services/recognition_router.py` and `backend/tests/test_recognition_router.py`.
- Modify `backend/app/services/detection_task_service.py`, `backend/tests/test_detection_task_service.py`, `backend/app/api/sign_analyzer.py`, and `backend/tests/test_sign_analyzer.py` for persistence and API compatibility.
- Create `backend/tools/train_gtsrb.py`, `backend/tests/test_training_commands.py`, `scripts/prepare-gtsrb.ps1`, `scripts/train-gtsrb-gpu.ps1`, and `scripts/evaluate-gtsrb.ps1`.
- Modify `scripts/train-tt100k-gpu.ps1`, `frontend/src/utils/signResults.js`, `frontend/src/components/SignDetectionResult.jsx`, their focused tests, `docs/local-development.md`, and `README.md`.

### Task 1: Repair TT100K Conversion

**Files:** `backend/tools/prepare_tt100k.py`, `backend/tests/test_prepare_tt100k.py`

- [ ] **Step 1: Write the failing split test.** Add a test passing paths `train/a.jpg`, `other/b.jpg`, and `test/c.jpg` to `split_records(..., val_ratio=0.1, test_ratio=0.1, seed=42)` and assert the records remain respectively in `train`, `val`, and `test`.
- [ ] **Step 2: Verify RED.** Run `Set-Location "$PROJECT_ROOT\backend"; .\.venv\Scripts\python.exe -m pytest tests/test_prepare_tt100k.py::test_split_records_maps_tt100k_other_to_validation -q`; it must fail because `other` is currently ratio-split.
- [ ] **Step 3: Implement the mapping.** Add `"other": "val"` to `VALID_SPLIT_NAMES`. Add the existing canonical 45 class codes as a module-level tuple and let `convert_dataset` accept an optional `class_names` list, so the repair command does not derive classes from validation/test annotations.
- [ ] **Step 4: Add no-leakage tests.** Test official paths, unknown-path ratio splitting, supplied class IDs, normalized boxes, and that excluded classes are skipped instead of added to YAML.
- [ ] **Step 5: Verify and regenerate.** Run `pytest tests/test_prepare_tt100k.py -q`, then generate `training/datasets/tt100k_corrected_45/` with hardlinks. Verify source counts are local `train=6103`, `other/val=7641`, `test=3067` before missing-image reporting and run `tools/train_yolo.py --dry-run`.

### Task 2: Prepare GTSRB Safely

**Files:** `backend/tools/prepare_gtsrb.py`, `backend/tests/test_prepare_gtsrb.py`

- [ ] **Step 1: Write failing grouped-split tests.** Build a temporary `GTSRB/Training/00` tree with files sharing track prefixes such as `00000_00000.ppm` and `00000_00001.ppm`. Assert all files from one track go to one split, output uses `train/<class>` and `val/<class>`, and all 43 classes are declared.
- [ ] **Step 2: Verify RED.** Run `Set-Location "$PROJECT_ROOT\backend"; .\.venv\Scripts\python.exe -m pytest tests/test_prepare_gtsrb.py -q`; it must fail because the module does not exist.
- [ ] **Step 3: Implement deterministic preparation.** Group by `(class, stem before the final underscore)`, shuffle groups with a local seed, assign whole groups to validation, and copy or hardlink only training archive files. Write `dataset.yaml` with 43 numeric names. Reject output equal to or nested under project `Test/`.
- [ ] **Step 4: Implement verified download.** Add a streaming downloader with MD5 validation using torchvision's GTSRB URL and checksum `513f3c79a4c5141765e10e952eaa2478`; keep download/extraction separate from preparation for testability.
- [ ] **Step 5: Add contamination test and run.** Assert a `Test/` output path raises `ValueError`; run all preparation tests, download the 187,490,228-byte archive to `training/raw/gtsrb/`, and create versioned `training/datasets/gtsrb_cls/` using hardlinks.

### Task 3: Add Labels, Evaluator, and Training Tool

**Files:** `backend/app/services/gtsrb_labels.py`, `backend/tools/evaluate_gtsrb.py`, `backend/tests/test_evaluate_gtsrb.py`, `backend/tools/train_gtsrb.py`, `backend/tests/test_training_commands.py`

- [ ] **Step 1: Write failing evaluator tests.** Test CSV stem matching (`00000.ppm` to `Test/00000.png`), truth labels 16 and 18, all-correct top-1 aggregation, missing truth errors, and zero-recall class reporting.
- [ ] **Step 2: Verify RED.** Run `Set-Location "$PROJECT_ROOT\backend"; .\.venv\Scripts\python.exe -m pytest tests/test_evaluate_gtsrb.py -q` and confirm import/function failures.
- [ ] **Step 3: Implement labels and evaluation.** Add all 43 labels in class-ID order. Load the semicolon CSV, normalize image stems, run a classification checkpoint on the requested device, and write `metrics.json`, `predictions.csv`, and `confusion_matrix.csv`. Print predictions for `00000` and `00006`, top-1, macro recall, and zero-recall classes.
- [ ] **Step 4: Write and test the classifier trainer.** Add parser defaults `yolo11n-cls.pt`, `imgsz=128`, `batch=128`, `epochs=50`, `device=0`; validate class folders before importing Ultralytics; support `--dry-run`; call `model.train(..., task="classify", ...)`.
- [ ] **Step 5: Verify and prepare truth.** Run evaluator/training parser tests and dry-run. Download the checksum-verified test-GT archive using the torchvision mirror, validate MD5 `fe31e9c9270bbcd7b84b7f21a9d9d9e5`, and copy only its CSV to `Test/GT-final_test.csv`; do not copy test images.

### Task 4: Implement the GTSRB Classifier

**Files:** `backend/app/config/settings.py`, `backend/.env.local.example`, `backend/app/services/gtsrb_classifier.py`, `backend/tests/test_gtsrb_classifier.py`

- [ ] **Step 1: Write failing settings/service tests.** Assert absolute classifier-path resolution, `GTSRB_IMAGE_SIZE=128`, crop threshold `512`, and auto CUDA selection. Use a fake Ultralytics result with `probs.top1=16` and `top1conf` to assert class, display label, full-image bbox, dimensions, timing, and JPEG annotation. Test missing checkpoint and corrupt bytes.
- [ ] **Step 2: Verify RED.** Run `Set-Location "$PROJECT_ROOT\backend"; .\.venv\Scripts\python.exe -m pytest tests/test_gtsrb_classifier.py tests/test_local_mode.py -q` and confirm the new settings/module are missing.
- [ ] **Step 3: Implement the lazy classifier.** Mirror `LocalYoloDetector` locking, lazy load, device selection, and errors. Decode with Pillow, call `model.predict(source=image, imgsz=..., device=..., verbose=False)`, convert top-1 to one `DetectedObject` with bbox `(0,0,width,height)`, and draw label/confidence before JPEG encoding.
- [ ] **Step 4: Run focused tests and refactor only after green.** Run the focused tests, then `pytest tests/test_yolo_detector.py tests/test_gtsrb_classifier.py -q`.

### Task 5: Add Router and Persistence Metadata

**Files:** `backend/app/services/recognition_router.py`, `backend/tests/test_recognition_router.py`, `backend/app/services/detection_task_service.py`, `backend/tests/test_detection_task_service.py`

- [ ] **Step 1: Write failing router tests.** Use fake services and call counters. Assert `auto` sends a `53x54` image to the classifier and a `1280x720` image to the detector; explicit `detect` and `classify` override the rule.
- [ ] **Step 2: Verify RED.** Run `Set-Location "$PROJECT_ROOT\backend"; .\.venv\Scripts\python.exe -m pytest tests/test_recognition_router.py -q` and confirm the router/metadata are absent.
- [ ] **Step 3: Implement router metadata.** Define a normalized prediction with `recognition_mode`, `model_family`, and `result_type`. Validate modes `auto`, `detect`, `classify`; use Pillow dimensions only for auto routing.
- [ ] **Step 4: Adapt task service.** Accept the router while retaining the current detector constructor for existing tests. Persist classification full-image results, display labels, mode/type metadata, and annotated output. For mixed auto batches, retain legacy task model-version compatibility and include per-image model metadata.
- [ ] **Step 5: Verify persistence.** Add a fake-classifier task test for class 16, `result_type=classification`, full-image bbox, and output URL; run `pytest tests/test_detection_task_service.py -q`.

### Task 6: Expose the Mode and Update the UI

**Files:** `backend/app/api/sign_analyzer.py`, `backend/tests/test_sign_analyzer.py`, `frontend/src/utils/signResults.js`, `frontend/src/components/SignDetectionResult.jsx`, and focused frontend tests

- [ ] **Step 1: Write failing API/UI tests.** Post a compact JPEG with `mode=auto` and assert `recognition_mode=classify`, `result_type=classification`, and the GTSRB display label. Add a frontend fixture that renders selected mode and display label while retaining detection codes.
- [ ] **Step 2: Verify RED.** Run backend focused tests and `cd ..\frontend; npm run test:run -- tests/utils/signResults.test.js tests/components/SignDetectionResult.test.js`; confirm the additive fields are missing.
- [ ] **Step 3: Implement API fields.** Accept and validate `mode` on single and batch endpoints, default to `auto`, pass it to the task service, and add mode/model-family/dataset/result-type fields without removing existing fields.
- [ ] **Step 4: Implement UI rendering.** Render mode/model metadata and human-readable classifier labels; keep detector codes, empty-result states, and failure states. Run focused tests and `npm run build`.

### Task 7: Train and Evaluate on the GPU

**Files:** `scripts/prepare-gtsrb.ps1`, `scripts/train-gtsrb-gpu.ps1`, `scripts/evaluate-gtsrb.ps1`, `scripts/train-tt100k-gpu.ps1`, `docs/local-development.md`, `README.md`

- [ ] **Step 1: Add reproducible scripts.** Scripts resolve project paths, use the backend virtualenv, default to CUDA device 0, expose epochs/image-size/batch/run-name, and never use `Test/` as training data.
- [ ] **Step 2: Train classifier.** Run `scripts/train-gtsrb-gpu.ps1 -Epochs 50 -ImageSize 128 -Batch 128 -Device 0`; reduce batch only after measured CUDA OOM. Require `training/runs/gtsrb_yolo11n_cls_gpu/weights/best.pt`.
- [ ] **Step 3: Evaluate all Test images.** Run the evaluator on all 12,630 images. Require class 16 for `00000`, class 18 for `00006`, top-1 at least 95%, and no zero-recall class.
- [ ] **Step 4: Train corrected detector.** Run a fresh TT100K job with `-Epochs 100 -ImageSize 1280 -Batch 4 -Device 0 -RunName tt100k_yolo11n_gpu_corrected`; do not resume the contaminated run. Evaluate old and new checkpoints on the same corrected validation split and enforce non-regression plus 10% relative improvement in at least one of recall/mAP50-95.
- [ ] **Step 5: Point local config at promoted checkpoints.** Keep old weights for rollback; update only local environment values and restart the backend.

### Task 8: End-to-End Verification

- [ ] **Step 1: Run all backend tests, frontend tests/build, and `pip check`.**
- [ ] **Step 2: Upload `Test/00000.png`, `Test/00006.png`, one TT100K scene, and a mixed batch to the running API.** Verify HTTP 200, GPU device 0, correct GTSRB labels, detector output, accessible annotated URLs, and task detail ownership.
- [ ] **Step 3: Run `git diff --check` and inspect staged files.** Ensure archives, checkpoints, runtime DBs, temporary HTML, and metrics are not staged.
- [ ] **Step 4: Report actual GTSRB and TT100K metrics.** Do not claim completion if either model was not trained or an acceptance gate is missing.

## Self-Review

- All design goals are covered by Tasks 1-8, including Test isolation and exact sample labels.
- Every production behavior has a named failing test and verification command.
- Classifier output uses the existing `ImagePrediction`/`DetectedObject` protocol, so current persistence and frontend contracts remain usable.
- Large downloads and GPU runs use versioned directories and explicit promotion gates.
