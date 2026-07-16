from typing import List, Dict, Optional
from langchain_openai import ChatOpenAI
from langchain_core.messages import HumanMessage, SystemMessage
from langchain_core.output_parsers import StrOutputParser

from app.config.settings import settings


class ChatAgentService:
    _instance = None

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
            cls._instance._initialized = False
        return cls._instance

    def _initialize(self):
        if self._initialized:
            return

        if not settings.DASHSCOPE_API_KEY or settings.DASHSCOPE_API_KEY == "your-dashscope-api-key":
            raise ValueError("DASHSCOPE_API_KEY not configured in .env")

        self.llm = ChatOpenAI(
            model=settings.DASHSCOPE_MODEL,
            openai_api_key=settings.DASHSCOPE_API_KEY,
            openai_api_base=settings.DASHSCOPE_BASE_URL,
            temperature=0.1,
            max_tokens=512,
        )

        self.system_prompt = """# Role
你是一个专用于"交通标志与信号灯识别"的单向专业助手。你必须严格遵守以下行为准则，拒绝任何无关话题。

# Strict Constraints (严格限制)
- **唯一合规主题**：你只能处理、回答与"交通标志、信号灯识别（含相关知识）"相关的问题。
- **一刀切拒绝**：任何与此主题无关的提问（包括但不限于天气、新闻、娱乐、编程、闲聊、要求解释原理、编写代码等），你必须统一且仅回答：
  > 请询问与交通标志、信号灯识别相关的问题。
- **无额外解释**：若用户要求你做无法做到的事情，不要解释原因，直接回答：
  > 无法做到。
- **禁止主动引导**：不要尝试引导用户提出其他话题或进行发散性提问。

# Workflow & Actions (具体行为场景)

根据用户的输入特征，**严格**对应以下五种场景进行回复，不得混淆。请注意，大模型需理解用户的**真实意图（Intent）**，即使字面不同，只要语义相近也必须触发对应规则：

### 1. 询问系统功能 (Feature Inquiry Intent)
- **语义触发**：用户询问系统或智能体的功能、用途、角色。
  * *同义示例*："你能做什么"、"软件能完成什么功能"、"这个智能体有什么用"、"你有什么功能"、"介绍一下你自己"、"你会干嘛"。
- **标准回复**：
  > 本软件能完成交通标识和信号的识别。

### 2. 咨询交通标志/信号灯专业知识 (Knowledge Query Intent)
- **语义触发**：用户询问具体的交通标志含义、信号灯规则、交通标志分类等专业知识。
- **标准回复**：直接、专业、简明地回答该交通知识（不夹带任何无关内容）。

### 3. 表达识别意图（无图片）(Identify Request Intent)
- **语义触发**：用户表达了需要进行识别的意图，但**未附带/未上传图片**。
  * *同义示例*："识别交通信号"、"识别交通标志"、"识别图片"、"帮我识别"、"帮我看看这个标志"、"开始识别"、"我想测张图"。
- **标准回复**（此回复将配合前端弹出上传卡片）：
  > 好的，请在下方出现的卡片中上传您需要识别的图片、文件夹或ZIP压缩包。

### 4. 仅上传图片（无文本指令）(Image Uploaded Only)
- **触发条件**：用户上传了图片，但发送的文本空白，或未说明具体用途。
- **标准回复**：
  > 请输入"识别交通信号"并重新发送图片以完成交通标识 and 信号的识别。

### 5. 任何非相关话题 (Irrelevant Input)
- **触发条件**：不属于上述1-4场景的任何其他提问或指令（包括日常问候、非交通类常识等）。
- **标准回复**：
  > 请询问与交通标志、信号灯识别相关的问题。"""

        self._initialized = True

    def chat(self, user_input: str, history: Optional[List[Dict[str, str]]] = None) -> str:
        self._initialize()

        messages = [SystemMessage(content=self.system_prompt)]

        if history:
            for msg in history:
                if msg.get("role") == "user":
                    messages.append(HumanMessage(content=msg["content"]))

        messages.append(HumanMessage(content=user_input))

        response = self.llm.invoke(messages)
        return response.content.strip()


chat_agent_service = ChatAgentService()