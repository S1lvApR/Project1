import { useRef, useEffect, useState, useCallback } from 'react'
import { Bot, User, Sparkles, Upload, FolderOpen, Loader2, Image } from 'lucide-react'
import { useStore } from '../store/useStore'
import { VideoResultCard } from './VideoResultCard'

export function ChatArea() {
  const { conversations, activeConversationId, user, recognizeSigns, recognizeVideo, loading } = useStore()
  const messagesEndRef = useRef(null)
  const [uploadingMessageId, setUploadingMessageId] = useState(null)

  const activeConversation = conversations.find((c) => c.id === activeConversationId)
  const messages = activeConversation?.messages || []
  const recentMessages = messages.slice(-20)

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [messages])

  const handleSignImageUpload = useCallback(async (e, conversationId) => {
    const files = Array.from(e.target.files)
    if (files.length === 0) return

    const imageFiles = files.filter(file => 
      file.type.startsWith('image/') || 
      file.name.toLowerCase().endsWith('.zip')
    )
    const videoFiles = files.filter(file => file.type.startsWith('video/'))

    if (videoFiles.length > 0) {
      await recognizeVideo(conversationId, videoFiles[0])
      return
    }

    if (imageFiles.length === 0) return

    setUploadingMessageId(conversationId)
    await recognizeSigns(conversationId, imageFiles)
    setUploadingMessageId(null)
  }, [recognizeSigns, recognizeVideo])

  

  const renderSignUploadCard = (conversationId) => {
    const isUploading = uploadingMessageId === conversationId || loading

    return (
      <div className="p-6 rounded-2xl bg-dark-700 border border-dark-600">
        <p className="text-white font-medium mb-4">交通标志与信号灯识别</p>
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
          <button
            onClick={() => document.getElementById(`sign-image-upload-${conversationId}`)?.click()}
            disabled={isUploading}
            className="flex flex-col items-center justify-center p-6 rounded-xl border-2 border-dashed border-dark-500 hover:border-accent-500 hover:bg-dark-600 transition-all group disabled:opacity-50"
          >
            <div className="w-12 h-12 rounded-full bg-accent-500/10 flex items-center justify-center mb-3 group-hover:bg-accent-500/20 transition-colors">
              {isUploading ? (
                <Loader2 className="w-6 h-6 text-accent-500 animate-spin" />
              ) : (
                <Image className="w-6 h-6 text-accent-500" />
              )}
            </div>
            <span className="text-white font-medium">上传图片</span>
            <span className="text-dark-500 text-sm mt-1">支持 JPG、PNG、BMP</span>
          </button>

          <button
            onClick={() => document.getElementById(`sign-batch-upload-${conversationId}`)?.click()}
            disabled={isUploading}
            className="flex flex-col items-center justify-center p-6 rounded-xl border-2 border-dashed border-dark-500 hover:border-accent-500 hover:bg-dark-600 transition-all group disabled:opacity-50"
          >
            <div className="w-12 h-12 rounded-full bg-accent-500/10 flex items-center justify-center mb-3 group-hover:bg-accent-500/20 transition-colors">
              {isUploading ? (
                <Loader2 className="w-6 h-6 text-accent-500 animate-spin" />
              ) : (
                <FolderOpen className="w-6 h-6 text-accent-500" />
              )}
            </div>
            <span className="text-white font-medium">批量上传</span>
            <span className="text-dark-500 text-sm mt-1">文件夹或ZIP压缩包</span>
          </button>

          <button
            onClick={() => document.getElementById(`sign-video-upload-${conversationId}`)?.click()}
            disabled={isUploading}
            className="flex flex-col items-center justify-center p-6 rounded-xl border-2 border-dashed border-dark-500 hover:border-accent-500 hover:bg-dark-600 transition-all group disabled:opacity-50"
          >
            <div className="w-12 h-12 rounded-full bg-accent-500/10 flex items-center justify-center mb-3 group-hover:bg-accent-500/20 transition-colors">
              {isUploading ? (
                <Loader2 className="w-6 h-6 text-accent-500 animate-spin" />
              ) : (
                <span className="text-accent-500 text-lg">🎬</span>
              )}
            </div>
            <span className="text-white font-medium">视频检测</span>
            <span className="text-dark-500 text-sm mt-1">支持 MP4、AVI、MOV</span>
          </button>
        </div>

        <input
          id={`sign-image-upload-${conversationId}`}
          type="file"
          multiple
          accept="image/*"
          onChange={(e) => handleSignImageUpload(e, conversationId)}
          className="hidden"
        />

        <input
          id={`sign-batch-upload-${conversationId}`}
          type="file"
          multiple
          webkitdirectory="true"
          directory="true"
          accept="image/*,.zip"
          onChange={(e) => handleSignImageUpload(e, conversationId)}
          className="hidden"
        />

        <input
          id={`sign-video-upload-${conversationId}`}
          type="file"
          accept="video/*"
          onChange={(e) => handleSignImageUpload(e, conversationId)}
          className="hidden"
        />

        {isUploading && (
          <div className="mt-4 flex items-center justify-center gap-2 text-accent-500">
            <Loader2 className="w-4 h-4 animate-spin" />
            <span className="text-sm">正在识别中...</span>
          </div>
        )}
      </div>
    )
  }

  if (!activeConversation) {
    return (
      <div className="flex-1 flex flex-col items-center justify-center bg-dark-900">
        <div className="w-20 h-20 rounded-2xl bg-gradient-to-br from-accent-500 to-accent-600 flex items-center justify-center mb-6 animate-pulse">
          <Sparkles className="w-10 h-10 text-white" />
        </div>
        <h2 className="text-2xl font-semibold text-white mb-2">
          Let's jump in, {user?.name || 'Guest'}
        </h2>
        <p className="text-dark-400 mb-8">
          Start a conversation with AI Assistant
        </p>
        <div className="w-full max-w-2xl px-8">
          <div className="flex items-center gap-4 p-4 rounded-xl bg-dark-800 border border-dark-600">
            <Bot className="w-5 h-5 text-accent-500" />
            <span className="text-dark-400 text-sm">
              Type a message to get started...
            </span>
          </div>
        </div>
      </div>
    )
  }

  return (
    <div className="flex-1 overflow-y-auto bg-dark-900 p-8">
      <div className="max-w-3xl mx-auto space-y-6">
        {messages.length === 0 ? (
          <div></div>
        ) : (
          recentMessages.map((message, index) => (
            <div
              key={message.id}
              className={`flex items-start gap-4 animate-fadeIn ${
                message.role === 'user' ? 'flex-row-reverse' : ''
              }`}
              style={{ animationDelay: `${index * 0.05}s` }}
            >
              <div
                className={`w-10 h-10 rounded-xl flex items-center justify-center flex-shrink-0 overflow-hidden ${
                  message.role === 'user'
                    ? user?.avatar ? '' : 'bg-gradient-to-br from-accent-500 to-accent-600'
                    : 'bg-dark-700'
                }`}
              >
                {message.role === 'user' ? (
                  user?.avatar ? (
                    <img
                      src={user.avatar}
                      alt="User"
                      className="w-full h-full object-cover"
                    />
                  ) : (
                    <User className="w-5 h-5 text-white" />
                  )
                ) : (
                  <Bot className="w-5 h-5 text-accent-500" />
                )}
              </div>

              {message.type === 'sign_upload' ? (
                <div className="max-w-[75%]">
                  <div className="p-4 rounded-2xl bg-dark-800 text-white rounded-bl-md mb-3">
                    <p className="text-sm leading-relaxed whitespace-pre-wrap">
                      {message.content}
                    </p>
                  </div>
                  {renderSignUploadCard(message.conversationId)}
                </div>
              ) : message.type === 'video_progress' && message.videoProgress ? (
                <div className="max-w-[75%]">
                  <div className="p-4 rounded-2xl bg-dark-800 text-white rounded-bl-md">
                    <div className="flex items-center gap-2 mb-3">
                      <Loader2 className="w-4 h-4 text-accent-500 animate-spin" />
                      <span className="text-sm text-accent-500">视频检测中...</span>
                    </div>
                    <div className="mb-2">
                      <div className="flex justify-between text-xs text-dark-400 mb-1">
                        <span>进度</span>
                        <span>{message.videoProgress.progress}%</span>
                      </div>
                      <div className="w-full bg-dark-600 rounded-full h-2">
                        <div
                          className="bg-accent-500 h-2 rounded-full transition-all duration-300"
                          style={{ width: `${message.videoProgress.progress}%` }}
                        />
                      </div>
                    </div>
                    <div className="text-xs text-dark-400">
                      已处理 {message.videoProgress.processedFrames || 0} 帧 / 共 {message.videoProgress.totalFrames || '未知'} 帧
                    </div>
                  </div>
                </div>
              ) : (
                <div
                  className={`max-w-[75%] p-4 rounded-2xl ${
                    message.role === 'user'
                      ? 'bg-gradient-to-r from-accent-500 to-accent-600 text-white rounded-br-md'
                      : 'bg-dark-800 text-white rounded-bl-md'
                  }`}
                >
                  {message.content && (
                    <p className="text-sm leading-relaxed whitespace-pre-wrap mb-3">
                      {message.content}
                    </p>
                  )}
                  {message.images && message.images.length > 0 && (
                    <div className="flex flex-wrap gap-2">
                      {message.images.map((img, idx) => (
                        <div
                          key={idx}
                          className="relative group cursor-pointer"
                        >
                          <img
                            src={img.url}
                            alt={img.name}
                            className="max-w-40 max-h-40 rounded-lg object-cover border border-dark-500 hover:border-accent-500 transition-colors"
                          />
                          <div className="absolute bottom-1 left-1 right-1 bg-black/60 text-white text-xs px-2 py-0.5 rounded truncate opacity-0 group-hover:opacity-100 transition-opacity">
                            {img.name}
                          </div>
                        </div>
                      ))}
                    </div>
                  )}
                  {message.videoResult && (
                    <VideoResultCard results={message.videoResult} />
                  )}
                </div>
              )}
            </div>
          ))
        )}
        <div ref={messagesEndRef} />
      </div>
    </div>
  )
}
