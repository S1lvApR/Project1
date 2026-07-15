import base64
import os
import requests
import io
from datetime import datetime

from app.config.settings import settings
from app.core.logger import get_logger

logger = get_logger(__name__)

TEMP_UPLOAD_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "temp", "uploads")

if not os.path.exists(TEMP_UPLOAD_DIR):
    os.makedirs(TEMP_UPLOAD_DIR)


class LicensePlateService:
    """车牌识别服务"""

    AGENT_NAME = "LicensePlateAgent"

    @staticmethod
    def save_image_to_temp(image_bytes, filename):
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        
        pure_filename = os.path.basename(filename)
        
        safe_filename = os.path.splitext(pure_filename)[0].replace(" ", "_")
        safe_filename = safe_filename.replace("/", "_").replace("\\", "_")
        
        temp_filename = f"{timestamp}_{safe_filename}{os.path.splitext(pure_filename)[1]}"
        temp_path = os.path.join(TEMP_UPLOAD_DIR, temp_filename)
        
        with open(temp_path, "wb") as f:
            f.write(image_bytes)
        
        logger.info(f"图片已保存到临时文件夹: {temp_path}")
        return temp_path

    @staticmethod
    def load_image_from_temp(file_path):
        with open(file_path, "rb") as f:
            image_bytes = f.read()
        
        logger.info(f"从临时文件夹加载图片: {file_path}, 大小: {len(image_bytes)} bytes")
        return image_bytes

    @staticmethod
    def delete_temp_image(file_path):
        if os.path.exists(file_path):
            os.remove(file_path)
            logger.info(f"临时图片已删除: {file_path}")

    @staticmethod
    def recognize_plate(image_bytes):
        """
        识别图片中的车牌
        
        Args:
            image_bytes: 图片字节数据
            
        Returns:
            识别结果:
            {
                'success': 是否成功,
                'error': 错误信息,
                'plates': [
                    {
                        'plate_number': 车牌号码,
                        'plate_color': 车牌颜色,
                        'confidence': 置信度
                    }
                ]
            }
        """
        agent_name = LicensePlateService.AGENT_NAME
        api_key = settings.LICENSE_PLATE_API_KEY
        api_url = settings.LICENSE_PLATE_API_URL
        
        if not api_key or not api_url:
            logger.warning(f"智能体 {agent_name} API密钥或URL未配置，使用模拟模式")
            return LicensePlateService._mock_recognize(image_bytes)
        
        try:
            logger.info(f"正在调用智能体 {agent_name} 进行车牌识别，图片大小: {len(image_bytes)} bytes")
            
            base64_image = base64.b64encode(image_bytes).decode("utf-8")
            
            headers = {
                "Content-Type": "application/json",
                "Authorization": f"Bearer {api_key}"
            }
            
            data = {
                "image": base64_image
            }
            
            response = requests.post(api_url, headers=headers, json=data)
            response.raise_for_status()
            
            result = response.json()
            
            logger.info(f"智能体 {agent_name} 响应状态码: {response.status_code}")
            
            if "error" in result:
                error_msg = result.get("error", "未知错误")
                logger.error(f"智能体 {agent_name} 识别失败: {error_msg}")
                return {
                    "success": False,
                    "error": error_msg,
                    "plates": []
                }
            
            plates = result.get("plates", [])
            
            logger.info(f"车牌识别成功，识别到 {len(plates)} 个车牌")
            return {
                "success": True,
                "error": None,
                "plates": plates
            }
            
        except Exception as e:
            logger.error(f"车牌识别异常: {e}")
            import traceback
            logger.error(f"异常堆栈: {traceback.format_exc()}")
            return {
                "success": False,
                "error": str(e),
                "plates": []
            }

    @staticmethod
    def _mock_recognize(image_bytes):
        """
        模拟车牌识别（当API密钥未配置时使用）
        
        Args:
            image_bytes: 图片字节数据
            
        Returns:
            模拟识别结果
        """
        agent_name = LicensePlateService.AGENT_NAME
        logger.info(f"使用模拟模式进行车牌识别")
        logger.info(f"图片大小: {len(image_bytes)} bytes")
        
        return {
            "success": True,
            "error": None,
            "plates": [
                {
                    "plate_number": "京A12345",
                    "plate_color": "蓝色",
                    "confidence": 95
                },
                {
                    "plate_number": "沪B67890",
                    "plate_color": "黄色",
                    "confidence": 88
                }
            ]
        }

    @staticmethod
    def batch_recognize(image_list):
        """
        批量识别多张图片中的车牌
        
        Args:
            image_list: 图片字节数据列表
            
        Returns:
            批量识别结果:
            {
                'total_images': 总图片数,
                'total_plates': 总车牌数,
                'results': [
                    {
                        'success': 是否成功,
                        'error': 错误信息,
                        'plates': 车牌列表
                    }
                ]
            }
        """
        results = []
        total_plates = 0
        
        for image_bytes in image_list:
            result = LicensePlateService.recognize_plate(image_bytes)
            results.append({
                "success": result["success"],
                "error": result["error"],
                "plates": result["plates"]
            })
            if result["success"]:
                total_plates += len(result["plates"])
        
        return {
            "total_images": len(image_list),
            "total_plates": total_plates,
            "results": results
        }

    @staticmethod
    def recognize_from_temp(file_path):
        image_bytes = LicensePlateService.load_image_from_temp(file_path)
        result = LicensePlateService.recognize_plate(image_bytes)
        LicensePlateService.delete_temp_image(file_path)
        return result


license_plate_service = LicensePlateService()