"""
检测智能体（Day 11 升级版）— 多工具 Agent + 对话记忆 + 增强 SSE

升级内容（相比 Day 8）：
  1. Prompt 模板外置到 prompts.py
  2. 工具从 4 个扩展到 8 个（检测 4 + RAG 1 + 统计 2 + 用户 1）
  3. 集成对话记忆（Redis），支持跨轮次上下文
  4. SSE 事件协议增强（thinking/tool_start/tool_end/done/error）

架构：
  用户消息 → 加载历史 → Agent（LLM + 8 工具）→ 调用工具 → SSE 流式返回
"""

import json
from typing import AsyncGenerator

from langchain.agents import create_agent
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage
from langchain_core.prompts import ChatPromptTemplate, MessagesPlaceholder

from app.agent.memory import conversation_memory
from app.agent.prompts import DETECTION_AGENT_SYSTEM_PROMPT
from app.agent.tools.analysis_tool import ANALYSIS_TOOLS
from app.agent.tools.detection_tool import DETECTION_TOOLS
from app.agent.tools.knowledge_tool import KNOWLEDGE_TOOLS
from app.config.settings import settings
from app.core.logger import get_logger
from app.rag.retriever import knowledge_retriever

logger = get_logger(__name__)


def create_llm():
    """
    根据配置创建 LLM 实例
    优先使用 DASHSCOPE_API_KEY，其次使用 QWEN_API_KEY
    """
    from langchain_openai import ChatOpenAI

    dashscope_api_key = getattr(settings, "DASHSCOPE_API_KEY", "")
    qwen_api_key = getattr(settings, "QWEN_API_KEY", "")
    
    if dashscope_api_key and dashscope_api_key != "your-dashscope-api-key":
        api_key = dashscope_api_key
        base_url = getattr(
            settings, "DASHSCOPE_BASE_URL",
            "https://dashscope.aliyuncs.com/compatible-mode/v1",
        )
        model_name = getattr(settings, "DASHSCOPE_MODEL", "qwen-turbo")
        logger.info(f"使用 DASHSCOPE API: model={model_name}")
    elif qwen_api_key and qwen_api_key != "your-qwen-api-key":
        api_key = qwen_api_key
        base_url = getattr(
            settings, "QWEN_BASE_URL",
            "https://dashscope.aliyuncs.com/compatible-mode/v1",
        )
        model_name = getattr(settings, "QWEN_MODEL", "qwen-turbo")
        logger.info(f"使用 QWEN API: model={model_name}")
    else:
        api_key = getattr(settings, "OPENAI_API_KEY", "")
        base_url = getattr(settings, "OPENAI_BASE_URL", "https://api.openai.com/v1")
        model_name = getattr(settings, "OPENAI_MODEL", "gpt-4o-mini")
        logger.info(f"使用 OPENAI API: model={model_name}")

    if not api_key or api_key.startswith("your-"):
        raise ValueError("未配置有效的 API Key，请在 .env 文件中设置 DASHSCOPE_API_KEY 或 QWEN_API_KEY")

    return ChatOpenAI(
        model=model_name,
        openai_api_key=api_key,
        openai_api_base=base_url,
        temperature=0.1,
    )


class DetectionAgent:
    """检测智能体（Day 11 升级版）"""

    def __init__(self):
        self.llm = create_llm()

        self.all_tools = DETECTION_TOOLS + ANALYSIS_TOOLS + KNOWLEDGE_TOOLS

        self.agent = create_agent(
            model=self.llm,
            tools=self.all_tools,
            system_prompt=DETECTION_AGENT_SYSTEM_PROMPT,
        )

        try:
            knowledge_retriever.build_index()
        except Exception as e:
            logger.warning("RAG 知识库初始化失败（不影响检测功能）: %s", str(e))

        logger.info(
            "DetectionAgent 初始化完成，绑定 %d 个工具（检测 %d + 分析 %d + 知识 %d）",
            len(self.all_tools),
            len(DETECTION_TOOLS),
            len(ANALYSIS_TOOLS),
            len(KNOWLEDGE_TOOLS),
        )

    async def chat_stream(
        self,
        message: str,
        user_id: int = 0,
        session_id: str = "default",
        image_path: str = None,
    ) -> AsyncGenerator:
        """
        流式处理对话消息（增强版 SSE）
        """
        if image_path:
            message = f"{message}\n[附件图片路径: {image_path}]"

        messages = []
        try:
            history = conversation_memory.load_history(user_id, session_id)
            for msg in history:
                if msg["role"] == "user":
                    messages.append(HumanMessage(content=msg["content"]))
                elif msg["role"] == "ai":
                    messages.append(AIMessage(content=msg["content"]))
        except Exception as e:
            logger.warning("加载对话历史失败: %s", str(e))

        messages.append(HumanMessage(content=message))

        try:
            conversation_memory.save_message(user_id, session_id, "user", message)
        except Exception as e:
            logger.warning("保存用户消息失败: %s", str(e))

        yield {"type": "thinking", "content": "正在分析您的请求..."}

        full_text = ""
        try:
            async for chunk in self.agent.astream({
                "messages": messages,
            }, stream_mode="updates"):
                logger.info("Agent chunk type: %s", type(chunk).__name__)
                logger.info("Agent chunk repr: %s", repr(chunk)[:500])
                
                if isinstance(chunk, dict):
                    logger.info("Chunk keys: %s", list(chunk.keys()))
                    
                    messages_list = []
                    if "messages" in chunk:
                        messages_list = chunk["messages"]
                    elif "model" in chunk and isinstance(chunk["model"], dict) and "messages" in chunk["model"]:
                        messages_list = chunk["model"]["messages"]
                    elif "response" in chunk:
                        response = chunk["response"]
                        if isinstance(response, AIMessage):
                            messages_list = [response]
                    
                    if messages_list:
                        logger.info("Messages count: %d", len(messages_list))
                        for msg in messages_list:
                            logger.info("Message type: %s", type(msg).__name__)
                            if isinstance(msg, AIMessage):
                                logger.info("AIMessage content: %s", repr(msg.content)[:200])
                                if msg.content:
                                    full_text += msg.content
                                    yield {
                                        "type": "text_chunk",
                                        "content": msg.content,
                                    }
                                else:
                                    logger.warning("AIMessage content is empty")
                                if hasattr(msg, 'tool_calls') and msg.tool_calls:
                                    for tool_call in msg.tool_calls:
                                        yield {
                                            "type": "tool_start",
                                            "tool": tool_call.get("name", ""),
                                            "input": tool_call.get("args", {}),
                                        }
                    else:
                        logger.warning("No messages found in chunk, checking for other formats")
                        if "content" in chunk:
                            content = chunk["content"]
                            if isinstance(content, str) and content:
                                full_text += content
                                yield {
                                    "type": "text_chunk",
                                    "content": content,
                                }
                        elif "output" in chunk:
                            output = chunk["output"]
                            if isinstance(output, str) and output:
                                full_text += output
                                yield {
                                    "type": "text_chunk",
                                    "content": output,
                                }
                        else:
                            logger.warning("No content found in chunk: %s", repr(chunk)[:200])

        except Exception as e:
            logger.error("Agent 流式执行异常: %s", str(e), exc_info=True)
            yield {
                "type": "error",
                "content": f"处理出错：{str(e)}",
            }

        if full_text:
            try:
                conversation_memory.save_message(user_id, session_id, "ai", full_text)
            except Exception as e:
                logger.warning("保存 AI 回复失败: %s", str(e))

        yield {
            "type": "done",
            "full_text": full_text,
        }

    async def chat(self, message: str, image_path: str = None) -> dict:
        """非流式对话（兼容旧接口）"""
        if image_path:
            message = f"{message}\n[附件图片路径: {image_path}]"
        try:
            result = await self.agent.ainvoke({
                "messages": [HumanMessage(content=message)],
            })
            output = ""
            if isinstance(result, dict) and "messages" in result:
                for msg in result["messages"]:
                    if isinstance(msg, AIMessage) and msg.content:
                        output += msg.content
            return {
                "output": output,
                "intermediate_steps": [],
            }
        except Exception as e:
            logger.error("Agent 执行异常: %s", str(e), exc_info=True)
            return {
                "output": f"抱歉，处理过程中出现错误：{str(e)}",
                "intermediate_steps": [],
            }


detection_agent = DetectionAgent()