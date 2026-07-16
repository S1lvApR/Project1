"""
检测服务 — 提供统一的检测接口

为 Agent 工具提供简化的检测方法。
"""

import os
import tempfile
import zipfile

from app.config.settings import settings
from app.core.logger import get_logger
from app.services.video_detection_service import video_detection_service
from app.services.yolo_detector import LocalYoloDetector

logger = get_logger(__name__)


class DetectionService:
    """检测服务"""

    def __init__(self):
        self.detector = LocalYoloDetector(
            model_path=settings.yolo_model_path,
            device=settings.YOLO_DEVICE,
            canonicalize_tt100k_classes=settings.YOLO_CANONICALIZE_TT100K_CLASSES,
            use_sahi=settings.YOLO_USE_SAHI,
            sahi_slice_height=settings.YOLO_SAHI_SLICE_HEIGHT,
            sahi_slice_width=settings.YOLO_SAHI_SLICE_WIDTH,
            sahi_overlap_ratio=settings.YOLO_SAHI_OVERLAP_RATIO,
            sahi_model_image_size=settings.YOLO_SAHI_MODEL_IMAGE_SIZE,
            sahi_perform_standard_prediction=settings.YOLO_SAHI_STANDARD_PREDICTION,
        )

    def detect_single(self, image_path: str, conf: float = 0.25, iou: float = 0.45) -> dict:
        """检测单张图片"""
        try:
            with open(image_path, "rb") as f:
                content = f.read()

            prediction = self.detector.predict(
                content,
                confidence=conf,
                iou=iou,
                image_size=settings.YOLO_IMAGE_SIZE,
            )

            signs = []
            for detection in prediction.detections:
                x1, y1, x2, y2 = detection.bbox
                signs.append({
                    "type": detection.class_name,
                    "confidence": round(detection.confidence * 100, 2),
                    "bbox": [x1, y1, x2, y2],
                    "class_id": detection.class_id,
                    "class_name": detection.class_name,
                })

            return {
                "total_objects": len(prediction.detections),
                "class_counts": {},
                "objects": signs,
                "inference_time": prediction.inference_time_ms,
                "annotated_image_url": None,
            }
        except Exception as e:
            logger.error("单图检测失败: %s", str(e))
            return {"error": f"检测失败: {str(e)}"}

    def detect_batch(self, image_paths: list[str], conf: float = 0.25) -> dict:
        """批量检测多张图片"""
        results = []
        for image_path in image_paths:
            result = self.detect_single(image_path, conf=conf)
            results.append({
                "image_path": image_path,
                **result,
            })
        return {"results": results, "total_images": len(image_paths)}

    def detect_zip(self, zip_path: str, conf: float = 0.25) -> dict:
        """检测 ZIP 文件中的图片"""
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                with zipfile.ZipFile(zip_path, "r") as zip_ref:
                    zip_ref.extractall(tmpdir)

                image_extensions = {".jpg", ".jpeg", ".png", ".bmp", ".gif"}
                image_paths = []
                for root, dirs, files in os.walk(tmpdir):
                    for file in files:
                        if os.path.splitext(file)[1].lower() in image_extensions:
                            image_paths.append(os.path.join(root, file))

                if not image_paths:
                    return {"error": "ZIP 文件中没有找到图片"}

                return self.detect_batch(image_paths, conf=conf)
        except Exception as e:
            logger.error("ZIP 检测失败: %s", str(e))
            return {"error": f"ZIP 检测失败: {str(e)}"}

    def detect_video(self, video_path: str, conf: float = 0.25, frame_sample_rate: int = 5) -> dict:
        """检测视频文件"""
        try:
            from app.services.video_detection_service import video_detection_service

            result = video_detection_service.process_video_file(
                video_path,
                confidence=conf,
                frame_sample_rate=frame_sample_rate,
            )
            return result
        except Exception as e:
            logger.error("视频检测失败: %s", str(e))
            return {"error": f"视频检测失败: {str(e)}"}


detection_service = DetectionService()