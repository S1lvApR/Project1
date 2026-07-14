import asyncio
import base64
import cv2
import io
import os
from datetime import datetime
from typing import Dict, Optional

from app.core.logger import get_logger
from app.services.sign_analyzer_service import sign_analyzer_service

logger = get_logger(__name__)

video_tasks: Dict[str, Dict] = {}


class VideoDetectionService:
    """视频检测服务 - 异步处理视频帧提取和识别"""

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
    async def process_video(task_id: str, video_bytes: bytes, frame_interval: int = 10):
        """
        异步处理视频：提取帧并识别交通标志
        
        Args:
            task_id: 任务ID
            video_bytes: 视频文件字节数据
            frame_interval: 帧提取间隔（每隔多少帧提取一帧）
        """
        VideoDetectionService.update_task(task_id, status="processing", started_at=datetime.now())

        try:
            video_stream = io.BytesIO(video_bytes)
            video_stream.seek(0)

            temp_video_path = os.path.join(
                os.path.dirname(__file__), "..", "uploads", f"temp_video_{task_id}.mp4"
            )
            with open(temp_video_path, "wb") as f:
                f.write(video_bytes)

            cap = cv2.VideoCapture(temp_video_path)
            if not cap.isOpened():
                raise ValueError("无法打开视频文件")

            total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
            fps = cap.get(cv2.CAP_PROP_FPS)
            duration = total_frames / fps if fps > 0 else 0

            VideoDetectionService.update_task(task_id, total_frames=total_frames)

            logger.info(f"开始处理视频: {task_id}, 总帧数: {total_frames}, FPS: {fps}, 时长: {duration:.2f}秒")

            results = []
            processed_frames = 0
            frame_index = 0

            while True:
                ret, frame = cap.read()
                if not ret:
                    break

                if frame_index % frame_interval == 0:
                    success, buffer = cv2.imencode(".jpg", frame)
                    if success:
                        image_bytes = buffer.tobytes()
                        
                        sign_result = sign_analyzer_service.analyze_sign(image_bytes)
                        
                        results.append({
                            "frame_index": frame_index,
                            "timestamp": frame_index / fps if fps > 0 else 0,
                            "success": sign_result["success"],
                            "traffic_signs": sign_result["traffic_signs"],
                            "traffic_lights": sign_result["traffic_lights"],
                        })

                        processed_frames += 1
                        progress = int((processed_frames / max(total_frames // frame_interval, 1)) * 100)
                        
                        VideoDetectionService.update_task(
                            task_id,
                            processed_frames=processed_frames,
                            progress=progress,
                            results=results[:]
                        )

                        await asyncio.sleep(0.1)

                frame_index += 1

            cap.release()

            os.remove(temp_video_path)

            total_signs = sum(len(r.get("traffic_signs", [])) for r in results)
            total_lights = sum(len(r.get("traffic_lights", [])) for r in results)

            final_result = {
                "total_frames": total_frames,
                "extracted_frames": processed_frames,
                "frame_interval": frame_interval,
                "duration": duration,
                "total_signs": total_signs,
                "total_lights": total_lights,
                "results": results,
            }

            VideoDetectionService.update_task(
                task_id,
                status="completed",
                progress=100,
                results=final_result,
                completed_at=datetime.now(),
            )

            logger.info(f"视频检测完成: {task_id}, 提取{processed_frames}帧, 识别{total_signs}个标志, {total_lights}个信号灯")

        except Exception as e:
            logger.error(f"视频检测失败: {task_id}, 错误: {str(e)}")
            import traceback
            logger.error(f"异常堆栈: {traceback.format_exc()}")
            
            VideoDetectionService.update_task(
                task_id,
                status="failed",
                error=str(e),
                completed_at=datetime.now(),
            )

            if os.path.exists(temp_video_path):
                os.remove(temp_video_path)


video_detection_service = VideoDetectionService()
