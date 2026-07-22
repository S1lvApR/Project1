# TT100K Chinese Result Labels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make TT100K detection results display real Chinese traffic-sign meanings while preserving model class IDs and raw class codes.

**Architecture:** Keep one canonical, ID-aligned Chinese label tuple in `tt100k_labels.py`. Resolve labels in the backend serialization layer so immediate responses, persisted records, scene metadata, and task history share the same source; the frontend already consumes `display_name` and needs no duplicate map.

**Tech Stack:** Python 3.10, FastAPI, SQLAlchemy, pytest, React/Vitest, Ultralytics/SAHI runtime

**Portable path:** `$PROJECT_ROOT` denotes the repository root in all commands and examples.

---

### Task 1: Add the canonical TT100K Chinese label map

**Files:**
- Create: `backend/tests/test_tt100k_labels.py`
- Modify: `backend/app/services/tt100k_labels.py`

- [ ] **Step 1: Write the failing mapping tests**

```python
from app.services.tt100k_labels import (
    TT100K_COMMON_45_CLASSES,
    TT100K_COMMON_45_LABELS_ZH,
    tt100k_label_zh,
)


def test_common_45_chinese_labels_are_id_aligned_and_complete():
    assert len(TT100K_COMMON_45_LABELS_ZH) == len(TT100K_COMMON_45_CLASSES) == 45
    assert all(label.strip() for label in TT100K_COMMON_45_LABELS_ZH)


def test_representative_tt100k_codes_have_real_chinese_meanings():
    assert tt100k_label_zh("p10") == "禁止小型客车驶入"
    assert tt100k_label_zh("p23") == "禁止向左转弯"
    assert tt100k_label_zh("pl5") == "最高限速 5 km/h"
    assert tt100k_label_zh("pl60") == "最高限速 60 km/h"
    assert tt100k_label_zh("unknown") is None
```

- [ ] **Step 2: Run the tests and verify RED**

Run:

```powershell
Set-Location "$PROJECT_ROOT\backend"
.\.venv\Scripts\python.exe -m pytest tests\test_tt100k_labels.py -q
```

Expected: collection fails because `TT100K_COMMON_45_LABELS_ZH` and `tt100k_label_zh` do not exist.

- [ ] **Step 3: Add the complete ID-aligned mapping and lookup**

Append to `backend/app/services/tt100k_labels.py`:

```python
TT100K_COMMON_45_LABELS_ZH = (
    "非机动车行驶",
    "机动车行驶",
    "靠右侧道路行驶",
    "最低限速 100 km/h",
    "最低限速 60 km/h",
    "最低限速 80 km/h",
    "机动车靠左行驶",
    "人行横道",
    "禁止小型客车驶入",
    "禁止鸣喇叭",
    "禁止摩托车驶入",
    "禁止向右转弯",
    "禁止向左转弯",
    "禁止载货汽车驶入",
    "禁止运输危险物品车辆驶入",
    "禁止大型客车驶入",
    "禁止掉头",
    "禁止非机动车进入",
    "减速让行",
    "限制高度 4 m",
    "限制高度 4.5 m",
    "限制高度 5 m",
    "最高限速 100 km/h",
    "最高限速 120 km/h",
    "最高限速 20 km/h",
    "最高限速 30 km/h",
    "最高限速 40 km/h",
    "最高限速 5 km/h",
    "最高限速 50 km/h",
    "最高限速 60 km/h",
    "最高限速 70 km/h",
    "最高限速 80 km/h",
    "限制质量 20 t",
    "限制质量 30 t",
    "限制质量 55 t",
    "禁止停放车辆",
    "禁止驶入",
    "禁止小型客车向左转弯",
    "解除最高限速 40 km/h",
    "十字交叉路口",
    "道路施工",
    "注意儿童",
    "注意行人",
    "右侧合流",
    "其他警告标志",
)

TT100K_LABELS_ZH_BY_CODE = dict(
    zip(TT100K_COMMON_45_CLASSES, TT100K_COMMON_45_LABELS_ZH, strict=True)
)


def tt100k_label_zh(class_name: str) -> str | None:
    normalized_name = TT100K_CLASS_ALIASES.get(class_name.strip(), class_name.strip())
    return TT100K_LABELS_ZH_BY_CODE.get(normalized_name)
```

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run:

```powershell
.\.venv\Scripts\python.exe -m pytest tests\test_tt100k_labels.py tests\test_yolo_detector.py -q
```

Expected: all label and detector tests pass.

- [ ] **Step 5: Commit the label source**

```powershell
git -c safe.directory="$PROJECT_ROOT" add backend/app/services/tt100k_labels.py backend/tests/test_tt100k_labels.py
git -c safe.directory="$PROJECT_ROOT" commit -m "Add TT100K Chinese label meanings"
```

### Task 2: Populate Chinese names in immediate detection results and scene metadata

**Files:**
- Modify: `backend/app/services/detection_task_service.py`
- Modify: `backend/tests/test_detection_task_service.py`

- [ ] **Step 1: Add failing service assertions**

Extend `test_run_task_registers_model_persists_results_and_writes_annotation`:

```python
    sign = outcome.images[0]["traffic_signs"][0]
    assert sign["type"] == "pl60"
    assert sign["class_name"] == "pl60"
    assert sign["class_name_cn"] == "最高限速 60 km/h"
    assert sign["display_name"] == "最高限速 60 km/h"

    record = (
        db_session.query(DetectionResult)
        .filter_by(task_id=outcome.task.id)
        .one()
    )
    assert record.class_name == "pl60"
    assert record.class_name_cn == "最高限速 60 km/h"

    scene = db_session.query(DetectionScene).filter_by(
        name="tt100k_traffic_signs"
    ).one()
    assert scene.class_names_cn["pl60"] == "最高限速 60 km/h"
```

Keep the classifier test and add:

```python
    assert result["traffic_signs"][0]["display_name"] == "禁止 3.5 吨以上车辆通行"
```

- [ ] **Step 2: Run the service test and verify RED**

Run:

```powershell
.\.venv\Scripts\python.exe -m pytest tests\test_detection_task_service.py -q
```

Expected: the TT100K result has `class_name_cn=None`, and scene metadata has no Chinese map.

- [ ] **Step 3: Resolve labels by recognition mode**

Import the TT100K mapping:

```python
from app.services.tt100k_labels import (
    TT100K_LABELS_ZH_BY_CODE,
    tt100k_label_zh,
)
```

In `ensure_registry`, set detector scene metadata while preserving GTSRB behavior:

```python
        class_names_cn = None if is_classification else TT100K_LABELS_ZH_BY_CODE
```

Use `class_names_cn=class_names_cn` when creating the scene and update it on existing scenes when changed.

In `_serialize_signs`, replace the classifier-only expression with:

```python
            if recognition_mode == "classify":
                class_name_cn = (
                    GTSRB_LABELS_ZH[detection.class_id]
                    if 0 <= detection.class_id < len(GTSRB_LABELS_ZH)
                    else None
                )
            else:
                class_name_cn = tt100k_label_zh(detection.class_name)
```

Do not change `type`, `class_name`, `class_id`, or persisted confidence values.

- [ ] **Step 4: Run focused service tests and verify GREEN**

Run:

```powershell
.\.venv\Scripts\python.exe -m pytest tests\test_detection_task_service.py tests\test_recognition_router.py -q
```

Expected: all tests pass; TT100K results expose Chinese names and GTSRB still uses its existing translation.

- [ ] **Step 5: Commit immediate-result support**

```powershell
git -c safe.directory="$PROJECT_ROOT" add backend/app/services/detection_task_service.py backend/tests/test_detection_task_service.py
git -c safe.directory="$PROJECT_ROOT" commit -m "Expose Chinese TT100K detection names"
```

### Task 3: Translate persisted task-history results without migration

**Files:**
- Modify: `backend/app/api/sign_analyzer.py`
- Modify: `backend/tests/test_sign_analyzer.py`

- [ ] **Step 1: Add failing task-history assertions**

In `test_task_list_and_detail_are_scoped_to_authenticated_user`, add:

```python
    assert persisted_result["class_name"] == "pl60"
    assert persisted_result["class_name_cn"] == "最高限速 60 km/h"
    assert persisted_result["display_name"] == "最高限速 60 km/h"
```

Add a direct regression test for an old database row:

```python
def test_persisted_tt100k_result_derives_missing_chinese_name():
    result = SimpleNamespace(
        id=1,
        task_id=2,
        task=SimpleNamespace(
            model_version=SimpleNamespace(model_type="yolov11s")
        ),
        image_path="road.jpg",
        annotated_image_url="/uploads/detections/2/0000_road.jpg",
        class_name="p23",
        class_name_cn=None,
        class_id=12,
        confidence=0.9,
        bbox=[1.0, 2.0, 3.0, 4.0],
        inference_time=3.0,
        image_width=2048,
        image_height=2048,
        created_at=None,
    )

    payload = sign_analyzer._result_payload(result)

    assert payload["class_name"] == "p23"
    assert payload["class_name_cn"] == "禁止向左转弯"
    assert payload["display_name"] == "禁止向左转弯"
```

- [ ] **Step 2: Run the API tests and verify RED**

Run:

```powershell
.\.venv\Scripts\python.exe -m pytest tests\test_sign_analyzer.py -q
```

Expected: history payload lacks `display_name` and old TT100K records keep a null Chinese name.

- [ ] **Step 3: Add task-history fallback serialization**

Import `tt100k_label_zh` in `sign_analyzer.py`. Update `_result_payload` before returning:

```python
    metadata = _recognition_metadata(model_version.model_type if model_version else None)
    class_name_cn = result.class_name_cn
    if not class_name_cn and metadata["dataset"] == "tt100k":
        class_name_cn = tt100k_label_zh(result.class_name)
```

Return:

```python
        "class_name_cn": class_name_cn,
        "display_name": class_name_cn or result.class_name,
```

Spread the already computed `metadata` instead of calling `_recognition_metadata` twice.

- [ ] **Step 4: Run API and frontend-display tests and verify GREEN**

Run:

```powershell
.\.venv\Scripts\python.exe -m pytest tests\test_sign_analyzer.py -q
cd ..\frontend
npm run test:run
```

Expected: API tests and all 10 frontend tests pass; no frontend mapping change is needed.

- [ ] **Step 5: Commit history support**

```powershell
git -c safe.directory="$PROJECT_ROOT" add backend/app/api/sign_analyzer.py backend/tests/test_sign_analyzer.py
git -c safe.directory="$PROJECT_ROOT" commit -m "Translate TT100K task history labels"
```

### Task 4: Full verification and real screenshot-case smoke test

**Files:**
- Modify only if verification reveals a defect.

- [ ] **Step 1: Run the full automated suite**

```powershell
Set-Location "$PROJECT_ROOT\backend"
.\.venv\Scripts\python.exe -m pytest -q
.\.venv\Scripts\python.exe -m pip check
cd ..\frontend
npm run test:run
npm run build
```

Expected: backend tests pass, pip reports no broken requirements, frontend has 10 passing tests, and Vite production build exits 0.

- [ ] **Step 2: Restart the backend with current local model settings**

Stop only the process listening on port 8000, then start `backend/.venv/Scripts/python.exe -m uvicorn main:app --host 127.0.0.1 --port 8000` from the backend directory with the existing `.env`, `YOLO_CONFIG_DIR`, and `MPLCONFIGDIR` settings.

Expected: `GET http://127.0.0.1:8000/api/health/detail` returns `data.status=healthy`.

- [ ] **Step 3: Re-run the screenshot image through the authenticated API**

Upload `$PROJECT_ROOT\training\raw\tt100k\data\train\1395.jpg` to `POST /api/sign-analyzer/analyze` with `mode=detect`.

Expected detections keep raw codes in `class_name`, while each known result has non-empty `class_name_cn` and matching `display_name`; representative results include readable meanings such as `禁止小型客车驶入` and `禁止向左转弯`.

- [ ] **Step 4: Verify workspace and final diff**

```powershell
git -c safe.directory="$PROJECT_ROOT" diff --check
git -c safe.directory="$PROJECT_ROOT" status --short
```

Expected: no whitespace errors; user-owned archives, TT100K reference folder, and temporary source files remain untracked and untouched.
