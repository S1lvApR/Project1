import { useRef, useEffect, useState, useCallback } from 'react'
import { Bot, User, Sparkles, Upload, FolderOpen, Loader2, Image, Video } from 'lucide-react'
import { useStore } from '../store/useStore'
import { SignDetectionResult } from './SignDetectionResult'
import { VideoDetectionResult } from './VideoDetectionResult'

export function ChatArea() {
  const { conversations, activeConversationId, user, recognizeLicensePlate, recognizeHumans, recognizeSigns, detectVideo, loading } = useStore()
  const messagesEndRef = useRef(null)
  const [uploadingMessageId, setUploadingMessageId] = useState(null)

  const activeConversation = conversations.find((c) => c.id === activeConversationId)
  const messages = activeConversation?.messages || []
  const recentMessages = messages.slice(-20)

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [activeConversationId, messages.length])

  const handleImageUpload = useCallback(async (e, conversationId) => {
    const files = Array.from(e.target.files)
    if (files.length === 0) return

    const imageFiles = files.filter(file => file.type.startsWith('image/'))
    if (imageFiles.length === 0) return

    setUploadingMessageId(conversationId)
    await recognizeLicensePlate(conversationId, imageFiles)
    setUploadingMessageId(null)
  }, [recognizeLicensePlate])

  const handleFolderUpload = useCallback(async (e, conversationId) => {
    const files = Array.from(e.target.files)
    if (files.length === 0) return

    const imageFiles = files.filter(file => file.type.startsWith('image/'))
    if (imageFiles.length === 0) return

    setUploadingMessageId(conversationId)
    await recognizeLicensePlate(conversationId, imageFiles)
    setUploadingMessageId(null)
  }, [recognizeLicensePlate])

  const handleHumanImageUpload = useCallback(async (e, conversationId) => {
    const files = Array.from(e.target.files)
    if (files.length === 0) return

    const imageFiles = files.filter(file => file.type.startsWith('image/'))
    if (imageFiles.length === 0) return

    setUploadingMessageId(conversationId)
    await recognizeHumans(conversationId, imageFiles)
    setUploadingMessageId(null)
  }, [recognizeHumans])

  const handleHumanFolderUpload = useCallback(async (e, conversationId) => {
    const files = Array.from(e.target.files)
    if (files.length === 0) return

    const imageFiles = files.filter(file => file.type.startsWith('image/'))
    if (imageFiles.length === 0) return

    setUploadingMessageId(conversationId)
    await recognizeHumans(conversationId, imageFiles)
    setUploadingMessageId(null)
  }, [recognizeHumans])

  const handleSignImageUpload = useCallback(async (e, conversationId) => {
    const files = Array.from(e.target.files)
    if (files.length === 0) return

    const validFiles = files.filter(file => 
      file.type.startsWith('image/') || file.name.toLowerCase().endsWith('.zip')
    )
    if (validFiles.length === 0) return

    setUploadingMessageId(conversationId)
    await recognizeSigns(conversationId, validFiles)
    setUploadingMessageId(null)
  }, [recognizeSigns])

  const handleSignFolderUpload = useCallback(async (e, conversationId) => {
    const files = Array.from(e.target.files)
    if (files.length === 0) return

    const imageFiles = files.filter(file => file.type.startsWith('image/'))
    if (imageFiles.length === 0) return

    setUploadingMessageId(conversationId)
    await recognizeSigns(conversationId, imageFiles)
    setUploadingMessageId(null)
  }, [recognizeSigns])

  const handleVideoUpload = useCallback(async (e, conversationId) => {
    const file = e.target.files?.[0]
    e.target.value = ''
    if (!file) return
    setUploadingMessageId(conversationId)
    try {
      await detectVideo(conversationId, file)
    } finally {
      setUploadingMessageId(null)
    }
  }, [detectVideo])

  const renderVideoUploadCard = (conversationId) => {
    const isUploading = uploadingMessageId === conversationId
    return (
      <div className="rounded-lg border border-dark-600 bg-dark-700 p-5">
        <p className="mb-4 font-medium text-white">视频交通标志检测</p>
        <button
          onClick={() => document.getElementById(`video-upload-${conversationId}`)?.click()}
          disabled={isUploading}
          className="flex w-full items-center justify-center gap-3 rounded-lg border border-dashed border-dark-500 px-5 py-6 text-dark-200 transition-colors hover:border-accent-500 hover:bg-dark-600 disabled:opacity-50"
        >
          {isUploading ? (
            <Loader2 className="h-5 w-5 animate-spin text-accent-400" />
          ) : (
            <Video className="h-5 w-5 text-accent-400" />
          )}
          <span>{isUploading ? '正在上传视频' : '选择视频'}</span>
        </button>
        <input
          id={`video-upload-${conversationId}`}
          type="file"
          accept=".mp4,.avi,.mov,.mkv,.wmv,.flv"
          onChange={(event) => handleVideoUpload(event, conversationId)}
          className="hidden"
        />
        <p className="mt-3 text-xs text-dark-400">MP4 / AVI / MOV / MKV / WMV / FLV，最大 50 MB</p>
      </div>
    )
  }

  const renderHumanCountUploadCard = (conversationId) => {
    const isUploading = uploadingMessageId === conversationId || loading

    return (
      <div className="p-6 rounded-2xl bg-dark-700 border border-dark-600">
        <p className="text-white font-medium mb-4">请上传包含行人的图片</p>
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          <button
            onClick={() => document.getElementById(`human-image-upload-${conversationId}`)?.click()}
            disabled={isUploading}
            className="flex flex-col items-center justify-center p-6 rounded-xl border-2 border-dashed border-dark-500 hover:border-accent-500 hover:bg-dark-600 transition-all group disabled:opacity-50"
          >
            <div className="w-12 h-12 rounded-full bg-accent-500/10 flex items-center justify-center mb-3 group-hover:bg-accent-500/20 transition-colors">
              {isUploading ? (
                <Loader2 className="w-6 h-6 text-accent-500 animate-spin" />
              ) : (
                <Upload className="w-6 h-6 text-accent-500" />
              )}
            </div>
            <span className="text-white font-medium">上传图片</span>
            <span className="text-dark-500 text-sm mt-1">支持 JPG、PNG、BMP</span>
          </button>

          <button
            onClick={() => document.getElementById(`human-folder-upload-${conversationId}`)?.click()}
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
            <span className="text-white font-medium">选择文件夹</span>
            <span className="text-dark-500 text-sm mt-1">批量读取图片</span>
          </button>
        </div>

        <input
          id={`human-image-upload-${conversationId}`}
          type="file"
          multiple
          accept="image/*"
          onChange={(e) => handleHumanImageUpload(e, conversationId)}
          className="hidden"
        />

        <input
          id={`human-folder-upload-${conversationId}`}
          type="file"
          multiple
          webkitdirectory="true"
          directory="true"
          accept="image/*"
          onChange={(e) => handleHumanFolderUpload(e, conversationId)}
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

  const renderLicensePlateUploadCard = (conversationId) => {
    const isUploading = uploadingMessageId === conversationId || loading

    return (
      <div className="p-6 rounded-2xl bg-dark-700 border border-dark-600">
        <p className="text-white font-medium mb-4">请上传包含车牌的图片</p>
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          <button
            onClick={() => document.getElementById(`image-upload-${conversationId}`)?.click()}
            disabled={isUploading}
            className="flex flex-col items-center justify-center p-6 rounded-xl border-2 border-dashed border-dark-500 hover:border-accent-500 hover:bg-dark-600 transition-all group disabled:opacity-50"
          >
            <div className="w-12 h-12 rounded-full bg-accent-500/10 flex items-center justify-center mb-3 group-hover:bg-accent-500/20 transition-colors">
              {isUploading ? (
                <Loader2 className="w-6 h-6 text-accent-500 animate-spin" />
              ) : (
                <Upload className="w-6 h-6 text-accent-500" />
              )}
            </div>
            <span className="text-white font-medium">上传图片</span>
            <span className="text-dark-500 text-sm mt-1">支持 JPG、PNG、BMP</span>
          </button>

          <button
            onClick={() => document.getElementById(`folder-upload-${conversationId}`)?.click()}
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
            <span className="text-white font-medium">选择文件夹</span>
            <span className="text-dark-500 text-sm mt-1">批量读取图片</span>
          </button>
        </div>

        <input
          id={`image-upload-${conversationId}`}
          type="file"
          multiple
          accept="image/*"
          onChange={(e) => handleImageUpload(e, conversationId)}
          className="hidden"
        />

        <input
          id={`folder-upload-${conversationId}`}
          type="file"
          multiple
          webkitdirectory="true"
          directory="true"
          accept="image/*"
          onChange={(e) => handleFolderUpload(e, conversationId)}
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

  const renderSignUploadCard = (conversationId) => {
    const isUploading = uploadingMessageId === conversationId || loading

    return (
      <div className="p-6 rounded-2xl bg-dark-700 border border-dark-600">
        <p className="text-white font-medium mb-4">交通标志与信号灯识别</p>
        <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-4">
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
            onClick={() => document.getElementById(`sign-folder-upload-${conversationId}`)?.click()}
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
            <span className="text-white font-medium">选择文件夹</span>
            <span className="text-dark-500 text-sm mt-1">批量读取图片</span>
          </button>

          <button
            onClick={() => document.getElementById(`sign-zip-upload-${conversationId}`)?.click()}
            disabled={isUploading}
            className="flex flex-col items-center justify-center p-6 rounded-xl border-2 border-dashed border-dark-500 hover:border-accent-500 hover:bg-dark-600 transition-all group disabled:opacity-50"
          >
            <div className="w-12 h-12 rounded-full bg-accent-500/10 flex items-center justify-center mb-3 group-hover:bg-accent-500/20 transition-colors">
              {isUploading ? (
                <Loader2 className="w-6 h-6 text-accent-500 animate-spin" />
              ) : (
                <span className="text-accent-500 text-lg">📦</span>
              )}
            </div>
            <span className="text-white font-medium">上传ZIP</span>
            <span className="text-dark-500 text-sm mt-1">压缩包批量识别</span>
          </button>

          <button
            onClick={() => document.getElementById(`sign-video-upload-${conversationId}`)?.click()}
            disabled={isUploading}
            className="flex flex-col items-center justify-center p-6 rounded-xl border-2 border-dashed border-dark-500 hover:border-accent-500 hover:bg-dark-600 transition-all group disabled:opacity-50"
          >
            <div className="w-12 h-12 rounded-full bg-accent-500/10 flex items-center justify-center mb-3 group-hover:bg-accent-500/20 transition-colors">
              <Video className="w-6 h-6 text-accent-500" />
            </div>
            <span className="text-white font-medium">上传视频</span>
            <span className="text-dark-500 text-sm mt-1">最大 50 MB</span>
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
          id={`sign-folder-upload-${conversationId}`}
          type="file"
          multiple
          webkitdirectory="true"
          directory="true"
          accept="image/*"
          onChange={(e) => handleSignFolderUpload(e, conversationId)}
          className="hidden"
        />

        <input
          id={`sign-zip-upload-${conversationId}`}
          type="file"
          accept=".zip"
          onChange={(e) => handleSignImageUpload(e, conversationId)}
          className="hidden"
        />

        <input
          id={`sign-video-upload-${conversationId}`}
          type="file"
          accept=".mp4,.avi,.mov,.mkv,.wmv,.flv"
          onChange={(event) => handleVideoUpload(event, conversationId)}
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
                className={`w-10 h-10 rounded-xl flex items-center justify-center flex-shrink-0 ${
                  message.role === 'user'
                    ? 'bg-gradient-to-br from-accent-500 to-accent-600'
                    : 'bg-dark-700'
                }`}
              >
                {message.role === 'user' ? (
                  <User className="w-5 h-5 text-white" />
                ) : (
                  <Bot className="w-5 h-5 text-accent-500" />
                )}
              </div>

              {message.type === 'license_plate_upload' ? (
                <div className="max-w-[75%]">
                  {renderLicensePlateUploadCard(message.conversationId)}
                </div>
              ) : message.type === 'human_count_upload' ? (
                <div className="max-w-[75%]">
                  {renderHumanCountUploadCard(message.conversationId)}
                </div>
              ) : message.type === 'sign_upload' ? (
                <div className="max-w-[75%]">
                  {renderSignUploadCard(message.conversationId)}
                </div>
              ) : message.type === 'sign_result' ? (
                <SignDetectionResult data={message.resultData} />
              ) : message.type === 'video_upload' ? (
                <div className="max-w-[75%]">
                  {renderVideoUploadCard(message.conversationId)}
                </div>
              ) : message.type === 'video_result' ? (
                <VideoDetectionResult data={message.resultData} />
              ) : (
                <div
                  className={`max-w-[75%] p-4 rounded-2xl ${
                    message.role === 'user'
                      ? 'bg-gradient-to-r from-accent-500 to-accent-600 text-white rounded-br-md'
                      : 'bg-dark-800 text-white rounded-bl-md'
                  }`}
                >
                  <p className="text-sm leading-relaxed whitespace-pre-wrap">
                    {message.content}
                  </p>
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
