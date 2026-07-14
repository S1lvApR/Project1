import asyncio
import base64
import cv2
import json
import numpy as np
import time

from fastapi import WebSocket, WebSocketDisconnect

from app.core.logger import get_logger
from app.core.security import decode_access_token
from app.services.sign_analyzer_service import sign_analyzer_service
from app.services.video_detection_service import VideoDetectionService

logger = get_logger(__name__)


async def camera_detection_websocket(websocket: WebSocket):
    await websocket.accept()

    token = websocket.query_params.get("token")
    if not token:
        await websocket.send_json({"type": "error", "message": "缺少认证token"})
        await websocket.close()
        return

    try:
        payload = decode_access_token(token)
        user_id = payload.get("user_id")
        if not user_id:
            await websocket.send_json({"type": "error", "message": "token无效"})
            await websocket.close()
            return
    except Exception as e:
        await websocket.send_json({"type": "error", "message": f"token验证失败: {str(e)}"})
        await websocket.close()
        return

    logger.info(f"WebSocket连接建立 - 用户ID: {user_id}")

    mode = "cpu"
    conf = 0.25
    scene_id = 1
    fps_start_time = time.time()
    frame_count = 0

    try:
        while True:
            data = await websocket.receive_text()
            try:
                message = json.loads(data)
                msg_type = message.get("type")

                if msg_type == "config":
                    mode = message.get("mode", "cpu")
                    conf = message.get("conf", 0.25)
                    scene_id = message.get("scene_id", 1)
                    logger.info(
                        f"配置更新 - mode: {mode}, conf: {conf}, scene_id: {scene_id}"
                    )
                    await websocket.send_json(
                        {
                            "type": "config_ok",
                            "message": "配置更新成功",
                        }
                    )

                elif msg_type == "frame":
                    frame_count += 1
                    if frame_count % 30 == 0:
                        elapsed = time.time() - fps_start_time
                        current_fps = frame_count / elapsed if elapsed > 0 else 0
                        logger.debug(f"WebSocket帧率: {current_fps:.2f} fps")

                    frame_data = message.get("data")
                    if not frame_data:
                        await websocket.send_json(
                            {"type": "error", "message": "帧数据为空"}
                        )
                        continue

                    try:
                        image_bytes = base64.b64decode(frame_data)

                        start_time = time.time()
                        sign_result = await asyncio.to_thread(
                            sign_analyzer_service.analyze_sign, image_bytes
                        )
                        inference_time = (time.time() - start_time) * 1000

                        frame_array = cv2.imdecode(
                            np.frombuffer(image_bytes, np.uint8), cv2.IMREAD_COLOR
                        )

                        annotated_img = VideoDetectionService.draw_detections_on_frame(
                            frame_array, sign_result
                        )

                        _, buffer = cv2.imencode(
                            ".jpg", annotated_img, [cv2.IMWRITE_JPEG_QUALITY, 70]
                        )
                        annotated_base64 = base64.b64encode(buffer).decode("utf-8")

                        traffic_signs = sign_result.get("traffic_signs", [])
                        traffic_lights = sign_result.get("traffic_lights", [])

                        detections = []
                        for sign in traffic_signs:
                            location = sign.get("location", {})
                            detections.append({
                                "class_name": sign.get("type", "交通标志"),
                                "confidence": float(sign.get("confidence", 0)) / 100
                                if sign.get("confidence")
                                else 0,
                                "bbox": [
                                    location.get("left", 0),
                                    location.get("top", 0),
                                    location.get("width", 0),
                                    location.get("height", 0),
                                ],
                            })
                        for light in traffic_lights:
                            location = light.get("location", {})
                            detections.append({
                                "class_name": "信号灯",
                                "confidence": float(light.get("confidence", 0)) / 100
                                if light.get("confidence")
                                else 0,
                                "bbox": [
                                    location.get("left", 0),
                                    location.get("top", 0),
                                    location.get("width", 0),
                                    location.get("height", 0),
                                ],
                            })

                        elapsed = time.time() - fps_start_time
                        current_fps = frame_count / elapsed if elapsed > 0 else 0

                        await websocket.send_json(
                            {
                                "type": "result",
                                "annotated_frame": annotated_base64,
                                "detections": detections,
                                "object_count": len(detections),
                                "inference_time": round(inference_time, 2),
                                "fps": round(current_fps, 2),
                            }
                        )

                    except Exception as e:
                        logger.error(f"帧处理失败: {e}", exc_info=True)
                        await websocket.send_json(
                            {"type": "error", "message": f"检测失败: {str(e)}"}
                        )

                elif msg_type == "close":
                    logger.info("客户端请求关闭连接")
                    break

                else:
                    await websocket.send_json(
                        {"type": "error", "message": f"未知消息类型: {msg_type}"}
                    )

            except json.JSONDecodeError:
                await websocket.send_json({"type": "error", "message": "无效的JSON格式"})

    except WebSocketDisconnect:
        logger.info("WebSocket连接断开")
    except Exception as e:
        logger.error(f"WebSocket异常: {e}", exc_info=True)
        try:
            await websocket.send_json({"type": "error", "message": str(e)})
        except Exception:
            pass
    finally:
        logger.info("WebSocket连接关闭")
