import { create } from 'zustand'
import { formatSignResult } from '../utils/signResults'
import { pollVideoStatus, uploadVideo } from '../api/detection'

const API_BASE = '/api'

const mockResponses = [
  'Hello! How can I assist you today?',
  'That\'s a great question! Let me think about it.',
  'I understand. Here\'s what I know about that topic.',
  'Interesting perspective! I can help you with that.',
  'Thanks for asking. Here\'s my response:',
]

const generateResponse = () => {
  return mockResponses[Math.floor(Math.random() * mockResponses.length)]
}

const getToken = () => {
  return localStorage.getItem('token')
}

const setToken = (token) => {
  localStorage.setItem('token', token)
}

const removeToken = () => {
  localStorage.removeItem('token')
}

const request = async (url, options = {}) => {
  const token = getToken()
  const headers = {
    'Content-Type': 'application/json',
    ...options.headers,
  }
  
  if (token) {
    headers['Authorization'] = `Bearer ${token}`
  }
  
  const response = await fetch(`${API_BASE}${url}`, {
    ...options,
    headers,
  })
  
  const data = await response.json()
  
  if (!response.ok) {
    throw new Error(data.detail || data.message || '请求失败')
  }
  
  return data
}

const requestFormData = async (url, options = {}) => {
  const token = getToken()
  const headers = {
    ...options.headers,
  }
  
  if (token) {
    headers['Authorization'] = `Bearer ${token}`
  }
  
  const response = await fetch(`${API_BASE}${url}`, {
    ...options,
    headers,
  })
  
  const data = await response.json()
  
  if (!response.ok) {
    throw new Error(data.detail || data.message || '请求失败')
  }
  
  return data
}

export const useStore = create((set, get) => ({
  user: null,
  conversations: [
    {
      id: '1',
      title: 'New Conversation',
      messages: [],
      createdAt: new Date(),
      persisted: false,
    },
  ],
  activeConversationId: '1',
  loading: false,
  error: null,
  theme: 'dark',

  setLoading: (loading) => set({ loading }),
  setError: (error) => set({ error }),

  toggleTheme: () => set((state) => ({
    theme: state.theme === 'dark' ? 'light' : 'dark',
  })),

  register: async (username, email, password) => {
    get().setLoading(true)
    get().setError(null)
    try {
      const data = await request('/auth/register', {
        method: 'POST',
        body: JSON.stringify({ username, email, password }),
      })
      return data
    } catch (error) {
      get().setError(error.message)
      throw error
    } finally {
      get().setLoading(false)
    }
  },

  login: async (username, password) => {
    get().setLoading(true)
    get().setError(null)
    try {
      const data = await request('/auth/login', {
        method: 'POST',
        body: JSON.stringify({ username, password }),
      })
      setToken(data.access_token)
      set({
        user: {
          id: data.user.id,
          name: data.user.username,
          email: data.user.email,
          avatar: data.user.avatar,
          roles: data.user.roles,
          isLoggedIn: true,
        },
      })
      await get().loadConversations()
      return data
    } catch (error) {
      get().setError(error.message)
      throw error
    } finally {
      get().setLoading(false)
    }
  },

  logout: () => {
    removeToken()
    set({
      user: null,
      conversations: [
        {
          id: '1',
          title: 'New Conversation',
          messages: [],
          createdAt: new Date(),
          persisted: false,
        },
      ],
      activeConversationId: '1',
    })
  },

  getCurrentUser: async () => {
    get().setLoading(true)
    get().setError(null)
    try {
      const data = await request('/auth/me')
      set({
        user: {
          id: data.id,
          name: data.username,
          email: data.email,
          avatar: data.avatar,
          roles: data.roles,
          isLoggedIn: true,
        },
      })
      await get().loadConversations()
      return data
    } catch (error) {
      get().setError(error.message)
      removeToken()
      set({ user: null })
      return null
    } finally {
      get().setLoading(false)
    }
  },

  loadConversations: async () => {
    try {
      const data = await request('/chat-sessions')
      if (data.success && data.data) {
        const conversations = data.data.map(session => ({
          id: session.id,
          title: session.title,
          messages: session.messages || [],
          createdAt: session.createdAt ? new Date(session.createdAt) : new Date(),
          updatedAt: session.updatedAt ? new Date(session.updatedAt) : new Date(),
          persisted: true,
        }))
        set((state) => ({
          conversations: conversations.length > 0 ? conversations : state.conversations,
          activeConversationId: conversations.length > 0 ? conversations[0].id : state.activeConversationId,
        }))
      }
    } catch (error) {
      console.error('Failed to load conversations:', error)
    }
  },

  saveConversation: async (conversation) => {
    if (!conversation.persisted) return
    try {
      await request(`/chat-sessions/${conversation.id}/title?title=${encodeURIComponent(conversation.title)}`, {
        method: 'PUT',
      })
    } catch (error) {
      console.error('Failed to save conversation:', error)
    }
  },

  saveMessage: async (conversationId, role, content) => {
    const conv = get().conversations.find(c => c.id === conversationId)
    if (!conv || !conv.persisted) return
    try {
      await request(`/chat-sessions/${conversationId}/messages?role=${encodeURIComponent(role)}&content=${encodeURIComponent(content)}`, {
        method: 'POST',
      })
    } catch (error) {
      console.error('Failed to save message:', error)
    }
  },

  forgotPassword: async (email) => {
    get().setLoading(true)
    get().setError(null)
    try {
      const data = await request('/auth/forgot-password', {
        method: 'POST',
        body: JSON.stringify({ email }),
      })
      return data
    } catch (error) {
      get().setError(error.message)
      throw error
    } finally {
      get().setLoading(false)
    }
  },

  changePassword: async (oldPassword, newPassword) => {
    get().setLoading(true)
    get().setError(null)
    try {
      const data = await request('/auth/change-password', {
        method: 'POST',
        body: JSON.stringify({ old_password: oldPassword, new_password: newPassword }),
      })
      return data
    } catch (error) {
      get().setError(error.message)
      throw error
    } finally {
      get().setLoading(false)
    }
  },

  updateEmail: async (newEmail) => {
    get().setLoading(true)
    get().setError(null)
    try {
      const data = await request('/auth/update-email', {
        method: 'POST',
        body: JSON.stringify({ email: newEmail }),
      })
      set((state) => ({
        user: state.user ? { ...state.user, email: data.email } : null,
      }))
      return data
    } catch (error) {
      get().setError(error.message)
      throw error
    } finally {
      get().setLoading(false)
    }
  },

  uploadAvatar: async (file) => {
    get().setLoading(true)
    get().setError(null)
    try {
      const formData = new FormData()
      formData.append('file', file)
      
      const data = await requestFormData('/auth/upload-avatar', {
        method: 'POST',
        body: formData,
      })
      
      set((state) => ({
        user: state.user ? { ...state.user, avatar: data.avatar } : null,
      }))
      return data
    } catch (error) {
      get().setError(error.message)
      throw error
    } finally {
      get().setLoading(false)
    }
  },

  recognizeSigns: async (conversationId, files) => {
    get().setLoading(true)
    get().setError(null)
    try {
      conversationId = await get().ensureConversationPersisted(conversationId)
      const formData = new FormData()
      files.forEach(file => {
        formData.append('files', file)
      })
      
      const data = await requestFormData('/sign-analyzer/batch', {
        method: 'POST',
        body: formData,
      })
      
      const resultContent = formatSignResult(data.data)
      
      set((state) => ({
        conversations: state.conversations.map((c) =>
          c.id === conversationId
            ? {
                ...c,
                title: c.messages.length === 0 ? '交通标志与信号灯识别' : c.title,
                messages: [
                  ...c.messages,
                  {
                    id: Date.now().toString(),
                    conversationId,
                    role: 'user',
                    content: `识别了 ${data.data?.total_images || files.length} 张图片`,
                    createdAt: new Date(),
                  },
                  {
                    id: (Date.now() + 1).toString(),
                    conversationId,
                    role: 'assistant',
                    content: resultContent,
                    createdAt: new Date(),
                    type: 'sign_result',
                    resultData: data.data,
                  },
                ],
              }
            : c
        ),
      }))
      
      await get().saveMessage(conversationId, 'user', `识别了 ${data.data?.total_images || files.length} 张图片`)
      await get().saveMessage(conversationId, 'assistant', resultContent)
      
      const conversation = get().conversations.find(c => c.id === conversationId)
      if (conversation && conversation.messages.length === 2) {
        await get().saveConversation(conversation)
      }
      
      return data
    } catch (error) {
      get().setError(error.message)
      throw error
    } finally {
      get().setLoading(false)
    }
  },

  detectVideo: async (conversationId, file, options = {}) => {
    conversationId = await get().ensureConversationPersisted(conversationId)
    const now = Date.now()
    const resultMessageId = `video-result-${now}`
    const initialData = {
      filename: file.name,
      status: 'pending',
      progress: 0,
      processed_frames: 0,
      sampled_frames: 0,
      key_frames: [],
    }
    const updateResult = (resultData) => {
      set((state) => ({
        conversations: state.conversations.map((conversation) =>
          conversation.id === conversationId
            ? {
                ...conversation,
                messages: conversation.messages.map((message) =>
                  message.id === resultMessageId
                    ? {
                        ...message,
                        resultData: {
                          ...message.resultData,
                          ...resultData,
                          filename: resultData.filename || file.name,
                        },
                      }
                    : message,
                ),
              }
            : conversation,
        ),
      }))
    }

    set((state) => ({
      conversations: state.conversations.map((conversation) =>
        conversation.id === conversationId
          ? {
              ...conversation,
              title: conversation.messages.length === 0
                ? '视频交通标志检测'
                : conversation.title,
              messages: [
                ...conversation.messages,
                {
                  id: `video-user-${now}`,
                  conversationId,
                  role: 'user',
                  content: `上传视频：${file.name}`,
                  createdAt: new Date(),
                },
                {
                  id: resultMessageId,
                  conversationId,
                  role: 'assistant',
                  content: '视频检测处理中',
                  createdAt: new Date(),
                  type: 'video_result',
                  resultData: initialData,
                },
              ],
            }
          : conversation,
      ),
    }))

    try {
      const submission = await uploadVideo(file, options)
      updateResult({ ...submission, filename: file.name })
      const result = await pollVideoStatus(submission.task_id, {
        onProgress: updateResult,
      })
      updateResult(result)
      await get().saveMessage(conversationId, 'user', `上传视频：${file.name}`)
      if (result.status === 'failed') {
        await get().saveMessage(
          conversationId,
          'assistant',
          `视频检测失败：${result.error || '服务未能完成该任务'}`,
        )
      } else {
        await get().saveMessage(
          conversationId,
          'assistant',
          `视频检测完成：${result.total_objects || 0} 个交通标志，${result.key_frames?.length || 0} 个关键帧`,
        )
      }
      return result
    } catch (error) {
      updateResult({ status: 'failed', error: error.message })
      get().setError(error.message)
      throw error
    }
  },

  addConversation: async () => {
    try {
      const data = await request(`/chat-sessions?title=${encodeURIComponent('New Chat')}`, {
        method: 'POST',
      })
      if (data.success && data.data) {
        const newConversation = {
          id: data.data.id,
          title: data.data.title,
          messages: data.data.messages || [],
          createdAt: data.data.createdAt ? new Date(data.data.createdAt) : new Date(),
          updatedAt: data.data.updatedAt ? new Date(data.data.updatedAt) : new Date(),
          persisted: true,
        }
        set((state) => ({
          conversations: [...state.conversations, newConversation],
          activeConversationId: newConversation.id,
        }))
        return newConversation.id
      }
    } catch (error) {
      console.error('Failed to create conversation:', error)
    }
    
    const newId = Date.now().toString()
    const newConversation = {
      id: newId,
      title: 'New Chat',
      messages: [],
      createdAt: new Date(),
      persisted: false,
    }
    set((state) => ({
      conversations: [...state.conversations, newConversation],
      activeConversationId: newId,
    }))
    return newId
  },

  ensureConversationPersisted: async (conversationId) => {
    const token = getToken()
    if (!token) return conversationId
    const conv = get().conversations.find(c => c.id === conversationId)
    if (!conv || conv.persisted) return conversationId
    try {
      const data = await request(`/chat-sessions?title=${encodeURIComponent(conv.title || 'New Chat')}`, {
        method: 'POST',
      })
      if (data.success && data.data) {
        const newId = data.data.id
        set((state) => ({
          conversations: state.conversations.map(c =>
            c.id === conversationId
              ? {
                  ...c,
                  id: newId,
                  persisted: true,
                  createdAt: data.data.createdAt ? new Date(data.data.createdAt) : c.createdAt,
                  updatedAt: data.data.updatedAt ? new Date(data.data.updatedAt) : c.updatedAt,
                }
              : c
          ),
          activeConversationId: state.activeConversationId === conversationId ? newId : state.activeConversationId,
        }))
        return newId
      }
    } catch (error) {
      console.error('Failed to persist conversation:', error)
    }
    return conversationId
  },

  setActiveConversation: (id) => {
    set({ activeConversationId: id })
  },

  closeConversation: async (id) => {
    try {
      await request(`/chat-sessions/${id}`, {
        method: 'DELETE',
      })
    } catch (error) {
      console.error('Failed to delete conversation:', error)
    }
    
    set((state) => {
      const conversations = state.conversations.filter((c) => c.id !== id)
      let newActiveId = state.activeConversationId
      if (state.activeConversationId === id) {
        newActiveId = conversations.length > 0 ? conversations[0].id : null
      }
      return { conversations, activeConversationId: newActiveId }
    })
  },

  updateConversationTitle: (conversationId, title) => {
    set((state) => ({
      conversations: state.conversations.map((c) =>
        c.id === conversationId ? { ...c, title } : c
      ),
    }))
  },

  pinConversation: (conversationId) => {
    set((state) => {
      const conversations = [...state.conversations]
      const index = conversations.findIndex((c) => c.id === conversationId)
      if (index > 0) {
        const [pinned] = conversations.splice(index, 1)
        conversations.unshift(pinned)
      }
      return { conversations }
    })
  },

  sendMessage: async (conversationId, content) => {
    conversationId = await get().ensureConversationPersisted(conversationId)
    const trimmedContent = content.trim().toLowerCase()
    
    if (trimmedContent.includes('视频检测') || trimmedContent.includes('视频识别')) {
      const uploadMessage = {
        id: Date.now().toString(),
        conversationId,
        role: 'assistant',
        content: '',
        createdAt: new Date(),
        type: 'video_upload',
      }
      set((state) => ({
        conversations: state.conversations.map((conversation) =>
          conversation.id === conversationId
            ? {
                ...conversation,
                messages: [...conversation.messages, uploadMessage],
                title: conversation.messages.length === 0
                  ? '视频交通标志检测'
                  : conversation.title,
              }
            : conversation,
        ),
      }))
      return
    }

    if (trimmedContent.includes('标志识别') || trimmedContent.includes('交通标志') || trimmedContent.includes('信号灯')) {
      const uploadMessage = {
        id: Date.now().toString(),
        conversationId,
        role: 'assistant',
        content: '',
        createdAt: new Date(),
        type: 'sign_upload',
      }

      set((state) => ({
        conversations: state.conversations.map((c) =>
          c.id === conversationId
            ? { 
                ...c, 
                messages: [...c.messages, uploadMessage],
                title: c.messages.length === 0 ? '交通标志与信号灯识别' : c.title
              }
            : c
        ),
      }))
      
      const conversation = get().conversations.find(c => c.id === conversationId)
      if (conversation && conversation.messages.length === 1) {
        await get().saveConversation(conversation)
      }
      return
    }

    const userMessage = {
      id: Date.now().toString(),
      conversationId,
      role: 'user',
      content,
      createdAt: new Date(),
    }

    set((state) => ({
      conversations: state.conversations.map((c) =>
        c.id === conversationId
          ? { 
              ...c, 
              messages: [...c.messages, userMessage],
              title: c.messages.length === 0 ? '通用对话' : c.title
            }
          : c
      ),
    }))
    
    await get().saveMessage(conversationId, 'user', content)
    
    const conversation = get().conversations.find(c => c.id === conversationId)
    if (conversation && conversation.messages.length === 1) {
      await get().saveConversation(conversation)
    }

    setTimeout(async () => {
      const responseContent = generateResponse()
      const assistantMessage = {
        id: (Date.now() + 1).toString(),
        conversationId,
        role: 'assistant',
        content: responseContent,
        createdAt: new Date(),
        type: 'text',
      }

      set((state) => ({
        conversations: state.conversations.map((c) =>
          c.id === conversationId
            ? { ...c, messages: [...c.messages, assistantMessage] }
            : c
        ),
      }))
      
      await get().saveMessage(conversationId, 'assistant', responseContent)
    }, 1000)
  },

  updateMessage: (conversationId, messageId, content) => {
    set((state) => ({
      conversations: state.conversations.map((c) =>
        c.id === conversationId
          ? {
              ...c,
              messages: c.messages.map((m) =>
                m.id === messageId ? { ...m, content } : m
              ),
            }
          : c
      ),
    }))
  },
}))
