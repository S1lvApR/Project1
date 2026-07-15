import json
from typing import Dict, List, Optional

import httpx
from app.config.settings import settings
from app.core.logger import get_logger
from app.services.sign_analyzer_service import sign_analyzer_service

logger = get_logger(__name__)


class AIService:
    SUPPORTED_PROVIDERS = ["openai", "baidu", "doubao", "qianwen", "bailian"]

    TOOLS = [
        {
            "type": "function",
            "function": {
                "name": "analyze_traffic_signs",
                "description": "识别图片中的交通标志和信号灯。当用户提到需要识别交通标志、信号灯、路标等，或者上传了图片要求识别时，调用此工具。",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "image_base64": {
                            "type": "string",
                            "description": "待识别图片的Base64编码字符串",
                        }
                    },
                    "required": ["image_base64"],
                },
            },
        }
    ]

    def __init__(self):
        self.provider = (
            settings.AI_PROVIDER.lower()
            if hasattr(settings, "AI_PROVIDER")
            else "openai"
        )
        if self.provider not in self.SUPPORTED_PROVIDERS:
            logger.warning(f"未知AI供应商: {self.provider}，使用默认供应商 openai")
            self.provider = "openai"
        self.client = self._create_client()

    def _get_system_prompt(self):
        return """你是一个交通标志与信号灯识别助手。你的任务是：

严格规则：
- 你只能回答与交通标志、信号灯识别相关的问题。
- 如果用户的问题与交通标志、信号灯识别无关，你必须回答：请询问与交通标志、信号灯识别相关的问题。

具体行为：
1. 当用户询问软件能完成什么功能时，回答：本软件能完成交通标识和信号的识别。
2. 当用户询问交通标志、信号灯相关的知识时，直接回答。
3. 当用户说"识别交通信号"、"识别交通标志"、"识别图片"、"帮我识别"等任何表示需要识别的话时，回答：请上传图片进行识别。支持上传单张图片、文件夹或ZIP压缩包。
4. 当用户上传图片但没有说明用途时，回答：请上传图片进行识别。支持上传单张图片、文件夹或ZIP压缩包。
5. 对于其他不相关的问题，回答：请询问与交通标志、信号灯识别相关的问题。

禁止行为：
- 不要回答任何与交通标志、信号灯识别无关的问题。
- 不要解释为什么无法做到，直接回答：无法做到。
- 不要尝试引导用户提出其他问题。
- 不要回答天气、新闻、娱乐、编程等无关话题。"""

    def _create_client(self):
        timeout = httpx.Timeout(60.0, read=60.0)
        if self.provider == "openai":
            api_key = getattr(settings, "OPENAI_API_KEY", "")
            base_url = getattr(settings, "OPENAI_API_BASE", "https://api.openai.com/v1")
            return httpx.AsyncClient(
                base_url=base_url,
                headers={"Authorization": f"Bearer {api_key}"},
                timeout=timeout,
            )
        elif self.provider == "baidu":
            return httpx.AsyncClient(timeout=timeout)
        elif self.provider == "doubao":
            api_key = getattr(settings, "DOUBAO_API_KEY", "")
            return httpx.AsyncClient(
                base_url="https://chatbot.bytedance.net/api",
                headers={"Authorization": f"Bearer {api_key}"},
                timeout=timeout,
            )
        elif self.provider == "qianwen":
            api_key = getattr(settings, "QIANWEN_API_KEY", "")
            return httpx.AsyncClient(
                base_url="https://dashscope.aliyuncs.com/compatible-mode/v1",
                headers={"Authorization": f"Bearer {api_key}"},
                timeout=timeout,
            )
        elif self.provider == "bailian":
            api_key = getattr(settings, "BAILIAN_API_KEY", "")
            base_url = getattr(
                settings,
                "BAILIAN_API_BASE",
                "https://dashscope.aliyuncs.com/compatible-mode/v1",
            )
            return httpx.AsyncClient(
                base_url=base_url,
                headers={"Authorization": f"Bearer {api_key}"},
                timeout=timeout,
            )
        return httpx.AsyncClient(timeout=timeout)

    async def chat_completion(
        self, messages: List[Dict], model: Optional[str] = None
    ) -> str:
        system_prompt = self._get_system_prompt()
        messages_with_system = [{"role": "system", "content": system_prompt}]
        messages_with_system.extend(messages)

        if self.provider == "openai":
            return await self._call_openai(messages_with_system, model)
        elif self.provider == "baidu":
            return await self._call_baidu(messages_with_system, model)
        elif self.provider == "doubao":
            return await self._call_doubao(messages_with_system, model)
        elif self.provider == "qianwen":
            return await self._call_qianwen(messages_with_system, model)
        elif self.provider == "bailian":
            return await self._call_bailian(messages_with_system, model)
        return "暂不支持该AI供应商"

    async def chat_with_tools(
        self, messages: List[Dict], model: Optional[str] = None
    ) -> str:
        try:
            system_prompt = self._get_system_prompt()

            tool_messages = [{"role": "system", "content": system_prompt}]
            tool_messages.extend(messages)

            response = await self._call_with_tools(tool_messages, model)

            if response.get("tool_calls"):
                tool_results = []
                for tool_call in response["tool_calls"]:
                    result = await self._execute_tool(tool_call)
                    tool_results.append(
                        {
                            "role": "tool",
                            "content": json.dumps(result),
                            "tool_call_id": tool_call["id"],
                        }
                    )

                tool_messages.extend(tool_results)

                final_response = await self._call_with_tools(tool_messages, model)
                return final_response["content"]

            return response["content"]
        except Exception as e:
            logger.error(f"工具调用失败: {str(e)}")
            return f"工具调用失败: {str(e)}"

    async def _call_with_tools(
        self, messages: List[Dict], model: Optional[str] = None
    ) -> Dict:
        req_model = self._get_model(model)

        payload = {
            "model": req_model,
            "messages": messages,
            "temperature": 0.7,
            "tools": self.TOOLS,
            "tool_choice": "auto",
        }

        response = await self.client.post("/chat/completions", json=payload)
        response.raise_for_status()
        data = response.json()

        choice = data["choices"][0]
        message = choice["message"]

        if message.get("tool_calls"):
            return {"content": None, "tool_calls": message["tool_calls"]}

        return {"content": message.get("content", "").strip(), "tool_calls": None}

    def _get_model(self, model: Optional[str] = None) -> str:
        if model:
            return model
        if self.provider == "openai":
            return getattr(settings, "OPENAI_MODEL", "gpt-4o")
        elif self.provider == "bailian":
            return getattr(settings, "BAILIAN_MODEL", "qwen-turbo")
        elif self.provider == "qianwen":
            return getattr(settings, "QIANWEN_MODEL", "qwen2-72b-instruct")
        elif self.provider == "doubao":
            return getattr(settings, "DOUBAO_MODEL", "doubao-3.5")
        elif self.provider == "baidu":
            return "ERNIE-4.0-Turbo"
        return "qwen-turbo"

    async def _execute_tool(self, tool_call: Dict) -> Dict:
        tool_name = tool_call["function"]["name"]
        arguments = json.loads(tool_call["function"]["arguments"])

        if tool_name == "analyze_traffic_signs":
            image_base64 = arguments.get("image_base64", "")
            if not image_base64:
                return {"success": False, "error": "图片数据为空"}

            try:
                import base64

                image_bytes = base64.b64decode(image_base64)
                result = sign_analyzer_service.analyze_sign(image_bytes)
                return result
            except Exception as e:
                return {"success": False, "error": f"图片解码或识别失败: {str(e)}"}

        return {"success": False, "error": f"未知工具: {tool_name}"}

    async def _call_openai(
        self, messages: List[Dict], model: Optional[str] = None
    ) -> str:
        try:
            req_model = model or getattr(settings, "OPENAI_MODEL", "gpt-4o")
            response = await self.client.post(
                "/chat/completions",
                json={"model": req_model, "messages": messages, "temperature": 0.7},
            )
            response.raise_for_status()
            data = response.json()
            return data["choices"][0]["message"]["content"].strip()
        except Exception as e:
            logger.error(f"OpenAI API调用失败: {str(e)}")
            raise

    async def _call_baidu(
        self, messages: List[Dict], model: Optional[str] = None
    ) -> str:
        try:
            api_key = getattr(settings, "BAIDU_API_KEY", "")
            secret_key = getattr(settings, "BAIDU_SECRET_KEY", "")

            token_response = await self.client.post(
                "https://aip.baidubce.com/oauth/2.0/token",
                params={
                    "grant_type": "client_credentials",
                    "client_id": api_key,
                    "client_secret": secret_key,
                },
            )
            token_data = token_response.json()
            access_token = token_data.get("access_token", "")

            req_model = model or "ERNIE-4.0-Turbo"
            response = await self.client.post(
                "https://aip.baidubce.com/rpc/2.0/ai_custom/v1/wenxinworkshop/chat/completions_pro",
                params={"access_token": access_token},
                json={"model": req_model, "messages": messages, "temperature": 0.7},
            )
            response.raise_for_status()
            data = response.json()
            if data.get("error_code"):
                raise Exception(f"百度API错误: {data.get('error_msg', '未知错误')}")
            return data["result"].strip()
        except Exception as e:
            logger.error(f"百度API调用失败: {str(e)}")
            raise

    async def _call_doubao(
        self, messages: List[Dict], model: Optional[str] = None
    ) -> str:
        try:
            req_model = model or getattr(settings, "DOUBAO_MODEL", "doubao-3.5")
            response = await self.client.post(
                "/chat/completions",
                json={"model": req_model, "messages": messages, "temperature": 0.7},
            )
            response.raise_for_status()
            data = response.json()
            return data["choices"][0]["message"]["content"].strip()
        except Exception as e:
            logger.error(f"豆包API调用失败: {str(e)}")
            raise

    async def _call_qianwen(
        self, messages: List[Dict], model: Optional[str] = None
    ) -> str:
        try:
            req_model = model or getattr(
                settings, "QIANWEN_MODEL", "qwen2-72b-instruct"
            )
            response = await self.client.post(
                "/chat/completions",
                json={"model": req_model, "messages": messages, "temperature": 0.7},
            )
            response.raise_for_status()
            data = response.json()
            return data["choices"][0]["message"]["content"].strip()
        except Exception as e:
            logger.error(f"通义千问API调用失败: {str(e)}")
            raise

    async def _call_bailian(
        self, messages: List[Dict], model: Optional[str] = None
    ) -> str:
        try:
            req_model = model or getattr(settings, "BAILIAN_MODEL", "qwen-turbo")
            response = await self.client.post(
                "/chat/completions",
                json={"model": req_model, "messages": messages, "temperature": 0.7},
            )

            if response.status_code == 403:
                error_detail = response.text[:200] if response.text else "未知错误"
                raise Exception(
                    f"API Key 无效或无权限访问模型。请检查 .env 中的 BAILIAN_API_KEY 是否正确。错误详情: {error_detail}"
                )

            response.raise_for_status()
            data = response.json()

            if data.get("error"):
                error_msg = data["error"].get("message", "未知错误")
                raise Exception(f"阿里云百炼API错误: {error_msg}")

            return data["choices"][0]["message"]["content"].strip()
        except httpx.HTTPStatusError as e:
            error_detail = e.response.text[:200] if e.response.text else "未知错误"
            raise Exception(f"HTTP错误 {e.response.status_code}: {error_detail}")
        except Exception as e:
            logger.error(f"阿里云百炼API调用失败: {str(e)}")
            raise


ai_service = AIService()
