import { useState, useRef } from 'react'
import { Send, Image, X, Paperclip } from 'lucide-react'
import { useStore } from '../store/useStore'

export function ChatInput({ style }) {
  const [message, setMessage] = useState('')
  const [uploadedImages, setUploadedImages] = useState([])
  const textareaRef = useRef(null)
  const fileInputRef = useRef(null)
  const { activeConversationId, sendMessage, loading } = useStore()

  const handleImageUpload = (e) => {
    const files = Array.from(e.target.files)
    if (files.length === 0) return

    const imageFiles = files.filter(file => file.type.startsWith('image/'))
    if (imageFiles.length === 0) return

    const newImages = imageFiles.map(file => ({
      id: Date.now() + Math.random(),
      file,
      url: URL.createObjectURL(file),
      name: file.name,
    }))

    setUploadedImages(prev => [...prev, ...newImages])
    e.target.value = ''
  }

  const removeImage = (id) => {
    setUploadedImages(prev => {
      const removed = prev.find(img => img.id === id)
      if (removed) {
        URL.revokeObjectURL(removed.url)
      }
      return prev.filter(img => img.id !== id)
    })
  }

  const handleSubmit = async () => {
    if (!message.trim() && uploadedImages.length === 0) return
    
    await sendMessage(activeConversationId, message.trim(), uploadedImages)
    
    setMessage('')
    uploadedImages.forEach(img => URL.revokeObjectURL(img.url))
    setUploadedImages([])
    
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
    <div className="p-4 bg-dark-800 border-t border-dark-600 flex flex-col shrink-0" style={{ minHeight: style?.height || '72px' }}>
      <div className="mx-auto flex flex-col w-full" style={{ maxWidth: '960px' }}>
        {uploadedImages.length > 0 && (
          <div className="flex flex-wrap gap-2 mb-3 p-2 rounded-xl bg-dark-900/50">
            {uploadedImages.map((img) => (
              <div
                key={img.id}
                className="relative w-12 h-12 rounded-lg overflow-hidden border border-dark-600 group"
              >
                <img
                  src={img.url}
                  alt={img.name}
                  className="w-full h-full object-cover"
                />
                <button
                  onClick={() => removeImage(img.id)}
                  className="absolute top-0.5 right-0.5 w-4 h-4 rounded-full bg-black/70 flex items-center justify-center opacity-0 group-hover:opacity-100 transition-opacity"
                >
                  <X className="w-2.5 h-2.5 text-white" />
                </button>
              </div>
            ))}
          </div>
        )}

        <div className="flex items-center gap-2 p-2 rounded-2xl bg-dark-900 border border-dark-600 hover:border-dark-500 transition-colors">
          <button
            onClick={() => fileInputRef.current?.click()}
            className="w-10 h-10 rounded-xl flex items-center justify-center transition-all flex-shrink-0 bg-dark-700 text-dark-400 hover:text-white hover:bg-dark-600"
          >
            <Paperclip className="w-4 h-4" />
          </button>

          <input
            ref={fileInputRef}
            type="file"
            multiple
            accept="image/*"
            onChange={handleImageUpload}
            className="hidden"
          />

          <div className="flex-1 relative">
            <textarea
              ref={textareaRef}
              value={message}
              onChange={handleInput}
              onKeyDown={handleKeyDown}
              placeholder="Type a message..."
              rows={1}
              className="w-full bg-transparent text-white placeholder-dark-500 resize-none outline-none py-2.5 px-3 text-sm"
              style={{ minHeight: '44px', maxHeight: '150px' }}
            />
          </div>

          <button
            onClick={handleSubmit}
            disabled={!message.trim() && uploadedImages.length === 0}
            className={`w-10 h-10 rounded-xl flex items-center justify-center transition-all flex-shrink-0 ${
              message.trim() || uploadedImages.length > 0
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