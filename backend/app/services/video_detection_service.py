import asyncio
import base64
import cv2
import os
import shutil
import subprocess
import tempfile
from datetime import datetime
from typing import Dict, Optional

from app.core.logger import get_logger
from app.database.session import SessionLocal
from app.entity.db_models import DetectionTask, DetectionResult
from app.services.sign_analyzer_service import sign_analyzer_service

logger = get_logger(__name__)

video_tasks: Dict[str, Dict] = {}


class VideoDetectionService:
    """视频检测服务 - 异步处理视频帧提取和识别"""

    CLASS_COLORS = {
        "限速标志": (0, 0, 255),
        "禁止标志": (255, 0, 0),
        "警告标志": (0, 255, 255),
        "指示标志": (0, 255, 0),
        "信号灯": (255, 128, 0),
    }

    @staticmethod
    def get_color(cls_name):
        return VideoDetectionService.CLASS_COLORS.get(cls_name, (255, 128, 0))

    @staticmethod
    def draw_detections_on_frame(frame, sign_result):
        """在帧上绘制检测结果"""
        annotated = frame.copy()
        height, width = frame.shape[:2]

        for sign in sign_result.get("traffic_signs", []):
            location = sign.get("location", {})
            if location:
                x1 = int(location.get("left", 0))
                y1 = int(location.get("top", 0))
                x2 = int(x1 + location.get("width", 0))
                y2 = int(y1 + location.get("height", 0))
                x1 = max(0, min(x1, width))
                y1 = max(0, min(y1, height))
                x2 = max(0, min(x2, width))
                y2 = max(0, min(y2, height))

                color = VideoDetectionService.get_color(sign.get("type", "交通标志"))
                cv2.rectangle(annotated, (x1, y1), (x2, y2), color, 2)
                label = f"{sign.get('type', '')} {sign.get('value', '')}{sign.get('unit', '')} {sign.get('confidence', '')}%"
                cv2.putText(
                    annotated,
                    label,
                    (x1, max(y1 - 10, 15)),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.5,
                    color,
                    2,
                )

        for light in sign_result.get("traffic_lights", []):
            location = light.get("location", {})
            if location:
                x1 = int(location.get("left", 0))
                y1 = int(location.get("top", 0))
                x2 = int(x1 + location.get("width", 0))
                y2 = int(y1 + location.get("height", 0))
                x1 = max(0, min(x1, width))
                y1 = max(0, min(y1, height))
                x2 = max(0, min(x2, width))
                y2 = max(0, min(y2, height))

                color = VideoDetectionService.get_color("信号灯")
                cv2.rectangle(annotated, (x1, y1), (x2, y2), color, 2)
                status_text = {"red": "红灯", "green": "绿灯", "yellow": "黄灯"}
                label = f"信号灯: {status_text.get(light.get('status', ''), light.get('status', ''))} {light.get('confidence', '')}%"
                cv2.putText(
                    annotated,
                    label,
                    (x1, max(y1 - 10, 15)),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.5,
                    color,
                    2,
                )

        return annotated

    @staticmethod
    def create_task(task_id: str, user_id: int, filename: str, frame_interval: int = 10):
        """创建视频检测任务"""
        video_tasks[task_id] = {
            "task_id": task_id,
            "user_id": user_id,
            "filename": filename,
            "frame_interval": frame_interval,
            "status": "pending",
            "total_frames": 0,
            "processed_frames": 0,
            "progress": 0,
            "results": [],
            "error": None,
            "created_at": datetime.now(),
            "started_at": None,
            "completed_at": None,
            "annotated_video_url": None,
            "total_signs": 0,
            "total_lights": 0,
        }
        logger.info(f"创建视频检测任务: {task_id}, 文件名: {filename}")

    @staticmethod
    def get_task(task_id: str) -> Optional[Dict]:
        """获取任务状态"""
        return video_tasks.get(task_id)

    @staticmethod
    def update_task(task_id: str, **kwargs):
        """更新任务状态"""
        if task_id in video_tasks:
            video_tasks[task_id].update(kwargs)

    @staticmethod
    def delete_task(task_id: str):
        """删除任务（释放内存）"""
        if task_id in video_tasks:
            del video_tasks[task_id]

    @staticmethod
    def _process_video_sync(task_id: str, video_bytes: bytes, frame_interval: int = 10):
        """
        同步处理视频：提取帧并识别交通标志（供asyncio.to_thread调用）
        
        处理流程（结合根目录版本优势）：
        1. OpenCV 打开视频，获取总帧数和 fps
        2. 场景变化检测：比较当前帧与上一帧的灰度差异
        3. 动态帧采样：根据视频长度计算有效采样间隔
        4. 对关键帧执行交通标志识别
        5. 生成标注帧图像（Base64）和标注视频
        6. ffmpeg转码为H.264格式
        7. 上传标注视频到MinIO
        8. 保存检测结果到数据库
        9. 汇总统计结果
        
        Args:
            task_id: 任务ID
            video_bytes: 视频文件字节数据
            frame_interval: 帧提取间隔（每隔多少帧提取一帧）
        
        Returns:
            最终检测结果字典
        """
        db = SessionLocal()
        try:
            temp_video_path = os.path.join(
                os.path.dirname(__file__), "..", "uploads", f"temp_video_{task_id}.mp4"
            )
            with open(temp_video_path, "wb") as f:
                f.write(video_bytes)

            cap = cv2.VideoCapture(temp_video_path)
            if not cap.isOpened():
                raise ValueError("无法打开视频文件")

            total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
            fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
            width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
            height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
            duration_seconds = total_frames / fps if fps > 0 else 0

            VideoDetectionService.update_task(task_id, total_frames=total_frames)

            logger.info(
                f"开始处理视频: {task_id}, 尺寸: {width}×{height}, FPS: {fps}, 总帧数: {total_frames}, 时长: {duration_seconds:.2f}秒"
            )

            max_frames = 50
            effective_interval = max(frame_interval, total_frames // max_frames)
            sample_indices = list(range(0, total_frames, effective_interval))
            if len(sample_indices) > max_frames:
                sample_indices = sample_indices[:max_frames]

            sample_set = set(sample_indices)
            key_frames = []
            total_signs = 0
            total_lights = 0
            last_detections = None
            last_frame = None
            frame_idx = 0
            sampled_count = 0

            output_tmp = tempfile.NamedTemporaryFile(suffix=".mp4", delete=False)
            output_video_path = output_tmp.name
            output_tmp.close()

            fourcc = cv2.VideoWriter_fourcc(*"mp4v")
            video_writer = cv2.VideoWriter(output_video_path, fourcc, fps, (width, height))

            detection_task = DetectionTask(
                user_id=video_tasks[task_id]["user_id"],
                scene_id=1,
                task_type="video",
                status="processing",
                total_images=len(sample_indices),
                conf_threshold=0.25,
                iou_threshold=0.45,
            )
            db.add(detection_task)
            db.flush()
            db_task_id = detection_task.id

            while True:
                ret, frame = cap.read()
                if not ret:
                    break

                current_frame_gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
                current_frame_gray = cv2.resize(current_frame_gray, (100, 100))

                scene_changed = False
                if last_frame is not None:
                    frame_diff = cv2.absdiff(last_frame, current_frame_gray)
                    diff_score = frame_diff.mean()
                    if diff_score > 10:
                        scene_changed = True
                else:
                    scene_changed = True

                last_frame = current_frame_gray.copy()

                if scene_changed:
                    success, buffer = cv2.imencode(".jpg", frame)
                    if success:
                        image_bytes = buffer.tobytes()

                        sign_result = sign_analyzer_service.analyze_sign(image_bytes)

                        frame_signs = sign_result.get("traffic_signs", [])
                        frame_lights = sign_result.get("traffic_lights", [])
                        total_signs += len(frame_signs)
                        total_lights += len(frame_lights)

                        last_detections = sign_result
                        sampled_count += 1

                        annotated_img = VideoDetectionService.draw_detections_on_frame(frame, sign_result)
                        video_writer.write(annotated_img)

                        annotated_base64 = None
                        if len(key_frames) < 6:
                            _, buffer_anno = cv2.imencode(
                                ".jpg", annotated_img, [cv2.IMWRITE_JPEG_QUALITY, 70]
                            )
                            annotated_base64 = base64.b64encode(buffer_anno).decode("utf-8")

                        key_frames.append({
                            "frame_index": frame_idx,
                            "timestamp": round(frame_idx / fps, 2),
                            "annotated_image_base64": annotated_base64,
                            "sign_count": len(frame_signs),
                            "light_count": len(frame_lights),
                            "traffic_signs": frame_signs,
                            "traffic_lights": frame_lights,
                        })

                        for sign in frame_signs:
                            db_result = DetectionResult(
                                task_id=db_task_id,
                                image_path=f"frame_{frame_idx}.jpg",
                                class_name=sign.get("type", "交通标志"),
                                class_id=0,
                                confidence=float(sign.get("confidence", 0)) / 100 if sign.get("confidence") else 0,
                                bbox=[
                                    sign.get("location", {}).get("left", 0),
                                    sign.get("location", {}).get("top", 0),
                                    sign.get("location", {}).get("width", 0),
                                    sign.get("location", {}).get("height", 0),
                                ],
                                inference_time=0,
                            )
                            db.add(db_result)

                        for light in frame_lights:
                            db_result = DetectionResult(
                                task_id=db_task_id,
                                image_path=f"frame_{frame_idx}.jpg",
                                class_name="信号灯",
                                class_id=0,
                                confidence=float(light.get("confidence", 0)) / 100 if light.get("confidence") else 0,
                                bbox=[
                                    light.get("location", {}).get("left", 0),
                                    light.get("location", {}).get("top", 0),
                                    light.get("location", {}).get("width", 0),
                                    light.get("location", {}).get("height", 0),
                                ],
                                inference_time=0,
                            )
                            db.add(db_result)

                        db.commit()

                        progress = int((sampled_count / max(len(sample_indices), 1)) * 100)
                        VideoDetectionService.update_task(
                            task_id,
                            processed_frames=sampled_count,
                            progress=progress,
                            results={
                                "total_signs": total_signs,
                                "total_lights": total_lights,
                                "key_frames": key_frames[:],
                            },
                            total_signs=total_signs,
                            total_lights=total_lights,
                        )
                else:
                    if last_detections:
                        annotated_frame = VideoDetectionService.draw_detections_on_frame(frame, last_detections)
                        video_writer.write(annotated_frame)
                    else:
                        video_writer.write(frame)

                frame_idx += 1

            cap.release()
            video_writer.release()

            h264_video_path = output_video_path.replace(".mp4", "_h264.mp4")
            ffmpeg_path = shutil.which("ffmpeg")
            if ffmpeg_path:
                try:
                    subprocess.run(
                        [
                            ffmpeg_path,
                            "-y",
                            "-i",
                            output_video_path,
                            "-c:v",
                            "libx264",
                            "-preset",
                            "fast",
                            "-crf",
                            "23",
                            "-pix_fmt",
                            "yuv420p",
                            "-movflags",
                            "+faststart",
                            h264_video_path,
                        ],
                        capture_output=True,
                        timeout=300,
                        check=True,
                    )
                    os.replace(h264_video_path, output_video_path)
                    logger.info("视频已转码为 H.264 格式")
                except Exception as e:
                    logger.warning("ffmpeg 转码失败，使用原始 mp4v 视频: %s", str(e))
                    try:
                        os.unlink(h264_video_path)
                    except Exception:
                        pass
            else:
                logger.warning("ffmpeg 未安装，使用原始 mp4v 视频")

            annotated_video_url = None
            try:
                from app.storage.minio_client import MinIOClient
                minio_client = MinIOClient()
                object_name = f"detections/{task_id}/annotated_video.mp4"
                annotated_video_url = minio_client.upload_file(object_name, output_video_path)
                logger.info("标注视频已上传: %s", object_name)
            except Exception as e:
                logger.warning("标注视频上传 MinIO 失败: %s", str(e))
                logger.warning("如果需要视频上传功能，请确保正确配置 MinIO 环境变量")

            try:
                os.unlink(output_video_path)
            except Exception:
                pass

            try:
                os.unlink(temp_video_path)
            except Exception:
                pass

            detection_task.status = "completed"
            detection_task.total_objects = total_signs + total_lights
            detection_task.completed_at = datetime.now()
            db.commit()

            final_result = {
                "total_frames": total_frames,
                "processed_frames": len(key_frames),
                "frame_interval": frame_interval,
                "fps": round(fps, 2),
                "duration_seconds": round(duration_seconds, 2),
                "video_resolution": {"width": width, "height": height},
                "total_signs": total_signs,
                "total_lights": total_lights,
                "key_frames": key_frames,
                "annotated_video_url": annotated_video_url,
            }

            VideoDetectionService.update_task(
                task_id,
                status="completed",
                progress=100,
                results=final_result,
                annotated_video_url=annotated_video_url,
                completed_at=datetime.now(),
            )

            logger.info(
                f"视频检测完成: {task_id}, 提取{len(key_frames)}帧, 识别{total_signs}个标志, {total_lights}个信号灯"
            )

            return final_result

        except Exception as e:
            logger.error(f"视频检测失败: {task_id}, 错误: {str(e)}", exc_info=True)

            try:
                os.unlink(temp_video_path)
            except Exception:
                pass

            try:
                detection_task.status = "failed"
                detection_task.error_message = str(e)
                db.commit()
            except Exception:
                pass

            VideoDetectionService.update_task(
                task_id,
                status="failed",
                error=str(e),
                completed_at=datetime.now(),
            )

            raise
        finally:
            db.close()

    @staticmethod
    async def process_video(task_id: str, video_bytes: bytes, frame_interval: int = 10):
        """
        异步处理视频：将同步处理逻辑包装在asyncio.to_thread中
        
        Args:
            task_id: 任务ID
            video_bytes: 视频文件字节数据
            frame_interval: 帧提取间隔（每隔多少帧提取一帧）
        """
        VideoDetectionService.update_task(task_id, status="processing", started_at=datetime.now())

        try:
            await asyncio.to_thread(
                VideoDetectionService._process_video_sync,
                task_id=task_id,
                video_bytes=video_bytes,
                frame_interval=frame_interval,
            )
        except Exception as e:
            logger.error(f"异步视频检测失败: {task_id}, 错误: {str(e)}", exc_info=True)


video_detection_service = VideoDetectionService()
