import { create } from "zustand";

const API_BASE = "/api";

const mockResponses = [
  "Hello! How can I assist you today?",
  "That's a great question! Let me think about it.",
  "I understand. Here's what I know about that topic.",
  "Interesting perspective! I can help you with that.",
  "Thanks for asking. Here's my response:",
];

const generateResponse = () => {
  return mockResponses[Math.floor(Math.random() * mockResponses.length)];
};

const formatSignResult = (data) => {
  if (!data) return "识别完成";

  let result = `识别时间：${data.time}\n\n`;
  result += `共识别 ${data.total_images} 张图片\n`;

  if (data.total_signs > 0) {
    result += `\n🚦 交通标志（共 ${data.total_signs} 个）：\n`;
    data.results?.forEach((imageResult, index) => {
      if (imageResult.traffic_signs && imageResult.traffic_signs.length > 0) {
        result += `\n图片 ${index + 1}：\n`;
        imageResult.traffic_signs.forEach((sign) => {
          result += `- ${sign.type}：${sign.value || "无"}，置信度 ${sign.confidence}%\n`;
        });
      }
    });
  }

  if (data.total_lights > 0) {
    result += `\n🔴 交通信号灯（共 ${data.total_lights} 个）：\n`;
    data.results?.forEach((imageResult, index) => {
      if (imageResult.traffic_lights && imageResult.traffic_lights.length > 0) {
        result += `\n图片 ${index + 1}：\n`;
        imageResult.traffic_lights.forEach((light) => {
          const statusText = { red: "红灯", green: "绿灯", yellow: "黄灯" };
          result += `- 信号灯：${statusText[light.status] || light.status}，置信度 ${light.confidence}%\n`;
        });
      }
    });
  }

  if (data.total_signs === 0 && data.total_lights === 0) {
    result += "\n未识别到交通标志和信号灯";
  }

  return result;
};

const formatVideoResult = (data) => {
  if (!data) return "视频检测完成";

  let result = "视频检测完成\n\n";
  
  if (data.total_signs > 0 || data.total_lights > 0) {
    result += `识别到 🚦交通标志 ${data.total_signs} 个，🔴交通信号灯 ${data.total_lights} 个`;
  } else {
    result += "未识别到交通标志和信号灯";
  }

  return result;
};

const getToken = () => {
  return localStorage.getItem("token");
};

const setToken = (token) => {
  localStorage.setItem("token", token);
};

const removeToken = () => {
  localStorage.removeItem("token");
};

const request = async (url, options = {}) => {
  const token = getToken();
  const headers = {
    "Content-Type": "application/json",
    ...options.headers,
  };

  if (token) {
    headers["Authorization"] = `Bearer ${token}`;
  }

  const response = await fetch(`${API_BASE}${url}`, {
    ...options,
    headers,
  });

  const data = await response.json();

  if (!response.ok) {
    if (response.status === 401) {
      removeToken();
      set({ user: null });
      window.location.href = "/";
    }
    throw new Error(data.detail || data.message || "请求失败");
  }

  return data;
};

const requestFormData = async (url, options = {}) => {
  const token = getToken();
  const headers = {
    ...options.headers,
  };

  if (token) {
    headers["Authorization"] = `Bearer ${token}`;
  }

  const response = await fetch(`${API_BASE}${url}`, {
    ...options,
    headers,
  });

  const data = await response.json();

  if (!response.ok) {
    if (response.status === 401) {
      removeToken();
      set({ user: null });
      window.location.href = "/";
    }
    throw new Error(data.detail || data.message || "请求失败");
  }

  return data;
};

export const useStore = create((set, get) => ({
  user: null,
  conversations: [],
  openTabs: [],
  activeConversationId: null,
  loading: false,
  error: null,
  theme: "dark",

  setLoading: (loading) => set({ loading }),
  setError: (error) => set({ error }),

  toggleTheme: () =>
    set((state) => ({
      theme: state.theme === "dark" ? "light" : "dark",
    })),

  register: async (username, email, password) => {
    get().setLoading(true);
    get().setError(null);
    try {
      const data = await request("/auth/register", {
        method: "POST",
        body: JSON.stringify({ username, email, password }),
      });
      return data;
    } catch (error) {
      get().setError(error.message);
      throw error;
    } finally {
      get().setLoading(false);
    }
  },

  login: async (username, password) => {
    get().setLoading(true);
    get().setError(null);
    try {
      const data = await request("/auth/login", {
        method: "POST",
        body: JSON.stringify({ username, password }),
      });
      setToken(data.access_token);
      set({
        user: {
          id: data.user.id,
          name: data.user.username,
          email: data.user.email,
          avatar: data.user.avatar,
          roles: data.user.roles,
          isLoggedIn: true,
          token: data.access_token,
        },
      });
      await get().loadConversations();
      
      const convs = get().conversations;
      if (!convs || convs.length === 0) {
        await get().addConversation();
      }
      
      return data;
    } catch (error) {
      get().setError(error.message);
      throw error;
    } finally {
      get().setLoading(false);
    }
  },

  logout: () => {
    removeToken();
    set({
      user: null,
      conversations: [],
      openTabs: [],
      activeConversationId: null,
    });
  },

  getCurrentUser: async () => {
    get().setLoading(true);
    get().setError(null);
    try {
      const data = await request("/auth/me");
      set({
        user: {
          id: data.id,
          name: data.username,
          email: data.email,
          avatar: data.avatar,
          roles: data.roles,
          isLoggedIn: true,
          token: getToken(),
        },
      });
      await get().loadConversations();
      
      const convs = get().conversations;
      if (!convs || convs.length === 0) {
        await get().addConversation();
      }
      
      return data;
    } catch (error) {
      get().setError(error.message);
      removeToken();
      set({ user: null });
      return null;
    } finally {
      get().setLoading(false);
    }
  },

  loadConversations: async () => {
    try {
      const data = await request("/chat-sessions");
      if (data.success && data.data) {
        const conversations = data.data.map((session) => ({
          id: session.id,
          title: session.title,
          messages: session.messages || [],
          createdAt: session.createdAt
            ? new Date(session.createdAt)
            : new Date(),
          updatedAt: session.updatedAt
            ? new Date(session.updatedAt)
            : new Date(),
          persisted: true,
        }));
        set((state) => ({
          conversations:
            conversations.length > 0 ? conversations : state.conversations,
          openTabs:
            conversations.length > 0 ? [conversations[0].id] : state.openTabs,
          activeConversationId:
            conversations.length > 0
              ? conversations[0].id
              : state.activeConversationId,
        }));
      }
    } catch (error) {
      console.error("Failed to load conversations:", error);
    }
  },

  saveConversation: async (conversation) => {
    if (!conversation.persisted) return;
    try {
      await request(
        `/chat-sessions/${conversation.id}/title?title=${encodeURIComponent(conversation.title)}`,
        {
          method: "PUT",
        },
      );
    } catch (error) {
      console.error("Failed to save conversation:", error);
    }
  },

  saveMessage: async (conversationId, role, content, videoResult = null) => {
    const conv = get().conversations.find((c) => c.id === conversationId);
    if (!conv || !conv.persisted) return null;
    try {
      const body = { role, content };
      if (videoResult) {
        body.video_result = videoResult;
      }
      const response = await request(
        `/chat-sessions/${conversationId}/messages`,
        {
          method: "POST",
          body: JSON.stringify(body),
        },
      );
      return response;
    } catch (error) {
      console.error("Failed to save message:", error);
      return null;
    }
  },

  forgotPassword: async (email) => {
    get().setLoading(true);
    get().setError(null);
    try {
      const data = await request("/auth/forgot-password", {
        method: "POST",
        body: JSON.stringify({ email }),
      });
      return data;
    } catch (error) {
      get().setError(error.message);
      throw error;
    } finally {
      get().setLoading(false);
    }
  },

  changePassword: async (oldPassword, newPassword) => {
    get().setLoading(true);
    get().setError(null);
    try {
      const data = await request("/auth/change-password", {
        method: "POST",
        body: JSON.stringify({
          old_password: oldPassword,
          new_password: newPassword,
        }),
      });
      return data;
    } catch (error) {
      get().setError(error.message);
      throw error;
    } finally {
      get().setLoading(false);
    }
  },

  updateEmail: async (newEmail) => {
    get().setLoading(true);
    get().setError(null);
    try {
      const data = await request("/auth/update-email", {
        method: "POST",
        body: JSON.stringify({ email: newEmail }),
      });
      set((state) => ({
        user: state.user ? { ...state.user, email: data.email } : null,
      }));
      return data;
    } catch (error) {
      get().setError(error.message);
      throw error;
    } finally {
      get().setLoading(false);
    }
  },

  uploadAvatar: async (file) => {
    get().setLoading(true);
    get().setError(null);
    try {
      const formData = new FormData();
      formData.append("file", file);

      const data = await requestFormData("/auth/upload-avatar", {
        method: "POST",
        body: formData,
      });

      set((state) => ({
        user: state.user ? { ...state.user, avatar: data.avatar } : null,
      }));
      return data;
    } catch (error) {
      get().setError(error.message);
      throw error;
    } finally {
      get().setLoading(false);
    }
  },

  recognizeSigns: async (conversationId, files) => {
    get().setLoading(true);
    get().setError(null);
    try {
      conversationId = await get().ensureConversationPersisted(conversationId);
      const formData = new FormData();
      files.forEach((file) => {
        formData.append("files", file);
      });

      const data = await requestFormData("/sign-analyzer/batch", {
        method: "POST",
        body: formData,
      });

      const resultContent = formatSignResult(data.data);

      const userImages = files.map(file => ({
        url: URL.createObjectURL(file),
        name: file.name,
      }));

      set((state) => ({
        conversations: state.conversations.map((c) =>
          c.id === conversationId
            ? {
                ...c,
                title:
                  c.messages.length === 0 ? "交通标志与信号灯识别" : c.title,
                messages: [
                  ...c.messages,
                  {
                    id: Date.now().toString(),
                    conversationId,
                    role: "user",
                    content: `识别了 ${data.data?.total_images || files.length} 张图片`,
                    images: userImages,
                    createdAt: new Date(),
                  },
                  {
                    id: (Date.now() + 1).toString(),
                    conversationId,
                    role: "assistant",
                    content: resultContent,
                    createdAt: new Date(),
                    type: "text",
                  },
                ],
              }
            : c,
        ),
      }));

      await get().saveMessage(
        conversationId,
        "user",
        `识别了 ${data.data?.total_images || files.length} 张图片`,
      );
      await get().saveMessage(conversationId, "assistant", resultContent);

      const conversation = get().conversations.find(
        (c) => c.id === conversationId,
      );
      if (conversation && conversation.messages.length === 2) {
        await get().saveConversation(conversation);
      }

      return data;
    } catch (error) {
      get().setError(error.message);
      throw error;
    } finally {
      get().setLoading(false);
    }
  },

  recognizeVideo: async (conversationId, videoFile) => {
    get().setError(null);
    try {
      conversationId = await get().ensureConversationPersisted(conversationId);
      const formData = new FormData();
      formData.append("video", videoFile);

      const data = await requestFormData("/video-detection/analyze", {
        method: "POST",
        body: formData,
      });

      const taskId = data.task_id;
      const progressMessageId = Date.now().toString();

      set((state) => ({
        conversations: state.conversations.map((c) =>
          c.id === conversationId
            ? {
                ...c,
                title:
                  c.messages.length === 0 ? "视频检测" : c.title,
                messages: [
                  ...c.messages,
                  {
                    id: (Date.now() - 1).toString(),
                    conversationId,
                    role: "user",
                    content: `上传了视频：${videoFile.name}`,
                    createdAt: new Date(),
                  },
                  {
                    id: progressMessageId,
                    conversationId,
                    role: "assistant",
                    content: "",
                    createdAt: new Date(),
                    type: "video_progress",
                    videoProgress: {
                      taskId,
                      status: "processing",
                      progress: 0,
                      totalFrames: 0,
                      processedFrames: 0,
                      results: null,
                    },
                  },
                ],
              }
            : c,
        ),
      }));

      const pollProgress = async () => {
        try {
          const progressData = await request(`/video-detection/${taskId}/progress`);
          if (progressData.success && progressData.data) {
            const { status, progress, total_frames, processed_frames, results } = progressData.data;
            
            set((state) => ({
              conversations: state.conversations.map((c) =>
                c.id === conversationId
                  ? {
                      ...c,
                      messages: c.messages.map((msg) =>
                        msg.id === progressMessageId
                          ? {
                              ...msg,
                              videoProgress: {
                                taskId,
                                status,
                                progress,
                                totalFrames: total_frames,
                                processedFrames: processed_frames,
                                results,
                              },
                            }
                          : msg
                      ),
                    }
                  : c,
              ),
            }));

            if (status === "processing") {
              setTimeout(pollProgress, 2000);
            } else if (status === "completed") {
              const resultContent = formatVideoResult(results);
              set((state) => ({
                conversations: state.conversations.map((c) =>
                  c.id === conversationId
                    ? {
                        ...c,
                        messages: c.messages.map((msg) =>
                          msg.id === progressMessageId
                            ? {
                                ...msg,
                                content: resultContent,
                                type: "text",
                                videoProgress: null,
                                videoUrl: results?.annotated_video_url || null,
                                videoResult: results,
                              }
                            : msg
                        ),
                      }
                    : c,
                ),
              }));
              await get().saveMessage(conversationId, "assistant", resultContent, results);
            } else if (status === "failed") {
              set((state) => ({
                conversations: state.conversations.map((c) =>
                  c.id === conversationId
                    ? {
                        ...c,
                        messages: c.messages.map((msg) =>
                          msg.id === progressMessageId
                            ? {
                                ...msg,
                                content: `视频检测失败：${results.error || '未知错误'}`,
                                type: "text",
                                videoProgress: null,
                              }
                            : msg
                        ),
                      }
                    : c,
                ),
              }));
            }
          }
        } catch (error) {
          console.error("视频检测进度查询失败:", error);
          setTimeout(pollProgress, 3000);
        }
      };

      setTimeout(pollProgress, 1000);

      return data;
    } catch (error) {
      get().setError(error.message);
      throw error;
    }
  },

  

  addConversation: async () => {
    const token = getToken();
    if (!token) {
      throw new Error("请先登录");
    }
    
    try {
      const data = await request(
        `/chat-sessions?title=${encodeURIComponent("New Chat")}`,
        {
          method: "POST",
        },
      );
      if (data.success && data.data) {
        const newConversation = {
          id: data.data.id,
          title: data.data.title,
          messages: data.data.messages || [],
          createdAt: data.data.createdAt
            ? new Date(data.data.createdAt)
            : new Date(),
          updatedAt: data.data.updatedAt
            ? new Date(data.data.updatedAt)
            : new Date(),
          persisted: true,
        };
        set((state) => ({
          conversations: [...state.conversations, newConversation],
          openTabs: [...state.openTabs, newConversation.id],
          activeConversationId: newConversation.id,
        }));
        return newConversation.id;
      }
    } catch (error) {
      console.error("Failed to create conversation:", error);
      throw error;
    }

    throw new Error("创建会话失败");
  },

  ensureConversationPersisted: async (conversationId) => {
    const token = getToken();
    if (!token) throw new Error("请先登录");
    
    const conv = get().conversations.find((c) => c.id === conversationId);
    if (!conv) {
      return await get().addConversation();
    }
    
    if (conv.persisted) return conversationId;
    
    try {
      const data = await request(
        `/chat-sessions?title=${encodeURIComponent(conv.title || "New Chat")}`,
        {
          method: "POST",
        },
      );
      if (data.success && data.data) {
        const newId = data.data.id;
        set((state) => ({
          conversations: state.conversations.map((c) =>
            c.id === conversationId
              ? {
                  ...c,
                  id: newId,
                  persisted: true,
                  createdAt: data.data.createdAt
                    ? new Date(data.data.createdAt)
                    : c.createdAt,
                  updatedAt: data.data.updatedAt
                    ? new Date(data.data.updatedAt)
                    : c.updatedAt,
                }
              : c,
          ),
          activeConversationId:
            state.activeConversationId === conversationId
              ? newId
              : state.activeConversationId,
        }));
        return newId;
      }
    } catch (error) {
      console.error("Failed to persist conversation:", error);
    }
    
    return await get().addConversation();
  },

  setActiveConversation: (id) => {
    set((state) => {
      if (!state.openTabs.includes(id)) {
        return {
          activeConversationId: id,
          openTabs: [...state.openTabs, id],
        };
      }
      return { activeConversationId: id };
    });
  },

  closeConversation: async (id) => {
    try {
      await request(`/chat-sessions/${id}`, {
        method: "DELETE",
      });
    } catch (error) {
      console.error("Failed to delete conversation:", error);
    }

    set((state) => {
      const conversations = state.conversations.filter((c) => c.id !== id);
      const openTabs = state.openTabs.filter((tabId) => tabId !== id);
      let newActiveId = state.activeConversationId;
      if (state.activeConversationId === id) {
        newActiveId = conversations.length > 0 ? conversations[0].id : null;
      }
      return { conversations, openTabs, activeConversationId: newActiveId };
    });
  },

  closeTab: (id) => {
    set((state) => {
      const openTabs = state.openTabs.filter((tabId) => tabId !== id);
      let newActiveId = state.activeConversationId;
      if (state.activeConversationId === id) {
        newActiveId = openTabs.length > 0 ? openTabs[0] : null;
      }
      return { openTabs, activeConversationId: newActiveId };
    });
  },

  updateConversationTitle: (conversationId, title) => {
    set((state) => ({
      conversations: state.conversations.map((c) =>
        c.id === conversationId ? { ...c, title } : c,
      ),
    }));
  },

  pinConversation: (conversationId) => {
    set((state) => {
      const conversations = [...state.conversations];
      const index = conversations.findIndex((c) => c.id === conversationId);
      if (index > 0) {
        const [pinned] = conversations.splice(index, 1);
        conversations.unshift(pinned);
      }
      return { conversations };
    });
  },

  sendMessage: async (conversationId, content, images = []) => {
    if (!conversationId) {
      conversationId = await get().addConversation();
    }
    conversationId = await get().ensureConversationPersisted(conversationId);

    const hasImages = images.length > 0;
    const hasText = content.trim().length > 0;

    if (!hasImages && !hasText) {
      return;
    }

    const userMessage = {
      id: Date.now().toString(),
      conversationId,
      role: "user",
      content,
      images: hasImages ? images.map(img => ({ url: img.url, name: img.name })) : [],
      createdAt: new Date(),
    };

    set((state) => ({
      conversations: state.conversations.map((c) =>
        c.id === conversationId
          ? {
              ...c,
              messages: [...c.messages, userMessage],
              title: c.messages.length === 0 ? "通用对话" : c.title,
            }
          : c,
      ),
    }));

    const recognitionKeywords = ["识别交通信号", "识别交通标志", "识别图片", "帮我识别", "识别一下", "识别图", "识别信号"];
    const isRecognitionRequest = recognitionKeywords.some(keyword => content.includes(keyword));
    
    if (isRecognitionRequest) {
      const uploadMessage = {
        id: (Date.now() + 1).toString(),
        conversationId,
        role: "assistant",
        content: "请上传图片进行识别。支持上传单张图片、文件夹或ZIP压缩包。",
        createdAt: new Date(),
        type: "sign_upload",
      };
      set((state) => ({
        conversations: state.conversations.map((c) =>
          c.id === conversationId
            ? { ...c, messages: [...c.messages, uploadMessage] }
            : c,
        ),
      }));
      return;
    }

    if (content.startsWith("/")) {
      const response = await get().saveMessage(conversationId, "user", content);
      if (response && response.data) {
        const assistantMessage = {
          id: response.data.id,
          conversationId,
          role: response.data.role,
          content: response.data.content,
          createdAt: response.data.createdAt
            ? new Date(response.data.createdAt)
            : new Date(),
          type: "text",
        };
        set((state) => ({
          conversations: state.conversations.map((c) =>
            c.id === conversationId
              ? { ...c, messages: [...c.messages, assistantMessage] }
              : c,
          ),
        }));
      }
      return;
    }

    get().setLoading(true);
    try {
      const persistedId = await get().ensureConversationPersisted(conversationId);
      
      let imageBase64 = null;
      if (hasImages && images.length > 0) {
        imageBase64 = await get().fileToBase64(images[0].file);
      }

      const bodyData = {
        content: content,
        image_base64: imageBase64
      };

      const aiResponse = await request(
        `/chat-sessions/${persistedId}/chat`,
        {
          method: "POST",
          body: JSON.stringify(bodyData),
        },
      );

      if (aiResponse.success && aiResponse.data) {
        const assistantMessage = {
          id: aiResponse.data.id,
          conversationId: persistedId,
          role: aiResponse.data.role,
          content: aiResponse.data.content,
          createdAt: aiResponse.data.createdAt
            ? new Date(aiResponse.data.createdAt)
            : new Date(),
          type: "text",
          images: aiResponse.data.images || [],
        };

        set((state) => ({
          conversations: state.conversations.map((c) =>
            c.id === conversationId || c.id === persistedId
              ? {
                  ...c,
                  messages: c.messages.map((msg) =>
                    msg.id === userMessage.id
                      ? { ...msg, images: aiResponse.data.user_images || msg.images }
                      : msg
                  ),
                }
              : c,
          ),
        }));

        set((state) => ({
          conversations: state.conversations.map((c) =>
            c.id === conversationId || c.id === persistedId
              ? { ...c, messages: [...c.messages, assistantMessage] }
              : c,
          ),
        }));
      }
    } catch (error) {
      console.error("AI chat failed:", error);
      get().setError(error.message);
    } finally {
      get().setLoading(false);
    }
  },

  fileToBase64: (file) => {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => {
        const result = reader.result;
        const base64 = result.split(',')[1];
        resolve(base64);
      };
      reader.onerror = reject;
      reader.readAsDataURL(file);
    });
  },

  updateMessage: (conversationId, messageId, content) => {
    set((state) => ({
      conversations: state.conversations.map((c) =>
        c.id === conversationId
          ? {
              ...c,
              messages: c.messages.map((m) =>
                m.id === messageId ? { ...m, content } : m,
              ),
            }
          : c,
      ),
    }));
  },
}));
