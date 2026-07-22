import { useState, useRef } from 'react'
import { Send, Image, Video } from 'lucide-react'
import { useStore } from '../store/useStore'

export function ChatInput({ style }) {
  const [message, setMessage] = useState('')
  const textareaRef = useRef(null)
  const { activeConversationId, sendMessage, loading } = useStore()

  const handleSubmit = () => {
    if (!message.trim() || !activeConversationId) return
    sendMessage(activeConversationId, message.trim())
    setMessage('')
    if (textareaRef.current) {
      textareaRef.current.style.height = '44px'
    }
  }

  const handleKeyDown = (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault()
      handleSubmit()
    }
  }

  const handleInput = (e) => {
    setMessage(e.target.value)
    if (textareaRef.current) {
      textareaRef.current.style.height = 'auto'
      textareaRef.current.style.height = textareaRef.current.scrollHeight + 'px'
    }
  }

  return (
    <div className="p-4 bg-dark-800 border-t border-dark-600 flex flex-col overflow-y-auto" style={style}>
      <div className="mx-auto flex flex-col h-full w-full" style={{ maxWidth: style?.height ? Math.min(1200, 960 + parseInt(style.height) * 0.6) + 'px' : '960px' }}>
        <div className="flex items-end gap-3 p-2 rounded-2xl bg-dark-900 border border-dark-600 hover:border-dark-500 transition-colors flex-1 min-h-0">
          <button
            onClick={() => {
              if (!activeConversationId) return
              sendMessage(activeConversationId, '标志识别')
            }}
            className="w-10 h-10 rounded-xl flex items-center justify-center transition-all flex-shrink-0 bg-dark-700 text-dark-400 hover:text-white hover:bg-dark-600"
            title="图片识别"
          >
            <Image className="w-4 h-4" />
          </button>

          <button
            onClick={() => {
              if (!activeConversationId) return
              sendMessage(activeConversationId, '视频检测')
            }}
            className="w-10 h-10 rounded-xl flex items-center justify-center transition-all flex-shrink-0 bg-dark-700 text-dark-400 hover:text-white hover:bg-dark-600"
            title="视频检测"
          >
            <Video className="w-4 h-4" />
          </button>

          <div className="flex-1 relative flex flex-col min-h-0">
            <textarea
              ref={textareaRef}
              value={message}
              onChange={handleInput}
              onKeyDown={handleKeyDown}
              placeholder="Type a message..."
              rows={1}
              className="w-full bg-transparent text-white placeholder-dark-500 resize-none outline-none py-3 px-2 text-sm overflow-y-auto"
              style={{ minHeight: '44px', maxHeight: 'none' }}
            />
          </div>

          <button
            onClick={handleSubmit}
            disabled={!message.trim() || !activeConversationId}
            className={`w-10 h-10 rounded-xl flex items-center justify-center transition-all flex-shrink-0 ${
              message.trim() && activeConversationId
                ? 'bg-gradient-to-r from-accent-500 to-accent-600 text-white hover:opacity-90'
                : 'bg-dark-700 text-dark-500 cursor-not-allowed'
            }`}
          >
            <Send className="w-4 h-4" />
          </button>
        </div>
      </div>
    </div>
  )
}
