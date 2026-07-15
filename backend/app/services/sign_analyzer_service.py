import base64
import os
import requests
import zipfile
import io
from datetime import datetime

from app.config.settings import settings
from app.core.logger import get_logger

logger = get_logger(__name__)

TEMP_UPLOAD_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "temp", "uploads")

if not os.path.exists(TEMP_UPLOAD_DIR):
    os.makedirs(TEMP_UPLOAD_DIR)


class SignAnalyzerService:
    """交通标志与信号灯识别服务"""

    AGENT_NAME = "SignAnalyzer"

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
    def extract_zip(zip_bytes):
        """
        从ZIP文件中提取图片
        
        Args:
            zip_bytes: ZIP文件字节数据
            
        Returns:
            图片字节数据列表
        """
        images = []
        filenames = []
        
        try:
            with zipfile.ZipFile(io.BytesIO(zip_bytes), 'r') as zip_ref:
                for file_info in zip_ref.infolist():
                    if not file_info.is_dir():
                        file_name = file_info.filename
                        if file_name.lower().endswith(('.jpg', '.jpeg', '.png', '.bmp', '.gif')):
                            file_data = zip_ref.read(file_info)
                            images.append(file_data)
                            filenames.append(file_name)
            
            logger.info(f"从ZIP文件中提取了 {len(images)} 张图片")
            return images, filenames
            
        except Exception as e:
            logger.error(f"解压ZIP文件失败: {e}")
            return [], []

    @staticmethod
    def analyze_sign(image_bytes):
        """
        分析图片中的交通标志和信号灯
        
        Args:
            image_bytes: 图片字节数据
            
        Returns:
            识别结果:
            {
                'success': 是否成功,
                'error': 错误信息,
                'agent_name': 使用的智能体名称,
                'traffic_signs': 交通标志列表,
                'traffic_lights': 交通信号灯列表
            }
        """
        agent_name = SignAnalyzerService.AGENT_NAME
        api_key = settings.SIGN_ANALYZER_API_KEY
        api_url = settings.SIGN_ANALYZER_API_URL
        
        if not api_key:
            logger.warning(f"智能体 {agent_name} API密钥未配置，使用模拟模式")
            return SignAnalyzerService._mock_analyze(image_bytes)
        
        try:
            logger.info(f"正在调用智能体 {agent_name} 进行交通标志与信号灯识别，图片大小: {len(image_bytes)} bytes")
            
            base64_image = base64.b64encode(image_bytes).decode("utf-8")
            
            headers = {
                "Content-Type": "application/json",
                "Authorization": f"Bearer {api_key}"
            }
            
            data = {
                "image": base64_image,
                "analyze_type": ["traffic_sign", "traffic_light"]
            }
            
            response = requests.post(api_url, headers=headers, json=data)
            response.raise_for_status()
            
            result = response.json()
            
            logger.info(f"智能体 {agent_name} 响应状态码: {response.status_code}")
            logger.info(f"智能体 {agent_name} 响应内容: {response.text[:2000]}")
            
            if "error" in result:
                error_msg = result.get("error", "未知错误")
                logger.error(f"智能体 {agent_name} 识别失败: {error_msg}")
                return {
                    "success": False,
                    "error": error_msg,
                    "agent_name": agent_name,
                    "traffic_signs": [],
                    "traffic_lights": []
                }
            
            traffic_signs = result.get("traffic_signs", [])
            traffic_lights = result.get("traffic_lights", [])
            
            logger.info(f"交通标志识别成功，识别到 {len(traffic_signs)} 个标志，{len(traffic_lights)} 个信号灯")
            return {
                "success": True,
                "error": None,
                "agent_name": agent_name,
                "traffic_signs": traffic_signs,
                "traffic_lights": traffic_lights
            }
            
        except Exception as e:
            logger.error(f"交通标志与信号灯识别异常: {e}")
            import traceback
            logger.error(f"异常堆栈: {traceback.format_exc()}")
            return {
                "success": False,
                "error": str(e),
                "agent_name": agent_name,
                "traffic_signs": [],
                "traffic_lights": []
            }

    @staticmethod
    def _mock_analyze(image_bytes):
        """
        模拟交通标志与信号灯识别（当API密钥未配置时使用）
        
        Args:
            image_bytes: 图片字节数据
            
        Returns:
            模拟识别结果
        """
        agent_name = SignAnalyzerService.AGENT_NAME
        logger.info(f"使用模拟模式进行交通标志与信号灯识别")
        logger.info(f"图片大小: {len(image_bytes)} bytes")
        
        return {
            "success": True,
            "error": None,
            "agent_name": agent_name,
            "traffic_signs": [
                {
                    "type": "限速标志",
                    "value": "60",
                    "unit": "km/h",
                    "confidence": 95,
                    "location": {"left": 100, "top": 80, "width": 60, "height": 60}
                },
                {
                    "type": "禁止通行",
                    "value": None,
                    "unit": None,
                    "confidence": 88,
                    "location": {"left": 200, "top": 150, "width": 50, "height": 50}
                }
            ],
            "traffic_lights": [
                {
                    "type": "信号灯",
                    "status": "red",
                    "confidence": 92,
                    "location": {"left": 300, "top": 50, "width": 40, "height": 100}
                }
            ]
        }

    @staticmethod
    def batch_analyze(image_list):
        """
        批量分析多张图片中的交通标志和信号灯
        
        Args:
            image_list: 图片字节数据列表
            
        Returns:
            批量识别结果:
            {
                'total_images': 总图片数,
                'total_signs': 总标志数,
                'total_lights': 总信号灯数,
                'results': [
                    {
                        'image_index': 图片索引,
                        'success': 是否成功,
                        'traffic_signs': 交通标志列表,
                        'traffic_lights': 交通信号灯列表,
                        'agent_name': 使用的智能体名称
                    }
                ]
            }
        """
        results = []
        total_signs = 0
        total_lights = 0
        
        for index, image_bytes in enumerate(image_list):
            result = SignAnalyzerService.analyze_sign(image_bytes)
            results.append({
                "image_index": index,
                "success": result["success"],
                "error": result["error"],
                "traffic_signs": result["traffic_signs"],
                "traffic_lights": result["traffic_lights"],
                "agent_name": result["agent_name"]
            })
            if result["success"]:
                total_signs += len(result["traffic_signs"])
                total_lights += len(result["traffic_lights"])
        
        return {
            "total_images": len(image_list),
            "total_signs": total_signs,
            "total_lights": total_lights,
            "results": results
        }

    @staticmethod
    def analyze_from_temp(file_path):
        image_bytes = SignAnalyzerService.load_image_from_temp(file_path)
        result = SignAnalyzerService.analyze_sign(image_bytes)
        SignAnalyzerService.delete_temp_image(file_path)
        return result


sign_analyzer_service = SignAnalyzerService()