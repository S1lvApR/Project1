import { useState } from 'react'
import { Bot, MessageSquare, History, ChevronRight, Sparkles, Pin, Trash2 } from 'lucide-react'
import { useStore } from '../store/useStore'

const formatTime = (date) => {
  if (!date) return ''
  const d = new Date(date)
  const hours = d.getHours().toString().padStart(2, '0')
  const minutes = d.getMinutes().toString().padStart(2, '0')
  const seconds = d.getSeconds().toString().padStart(2, '0')
  return `${hours}:${minutes}:${seconds}`
}

export function LeftSidebar({ onCreateConversation, style }) {
  const { conversations, activeConversationId, setActiveConversation, closeConversation, pinConversation } = useStore()
  const [hoveredId, setHoveredId] = useState(null)

  const sidebarWidth = style?.width ? parseInt(style.width) : 256
  const scale = Math.max(0.6, sidebarWidth / 256)
  
  const iconSize = Math.round(40 * scale)
  const logoIconSize = Math.round(20 * scale)
  const textSize = scale >= 0.85 ? 'text-lg' : scale >= 0.7 ? 'text-base' : scale >= 0.6 ? 'text-sm' : 'text-xs'

  return (
    <div className="h-full bg-dark-800 border-r border-dark-600 flex flex-col overflow-hidden" style={style}>
      <div className="p-4">
        <div className="flex items-center gap-2" style={{ gap: `${Math.round(12 * scale)}px` }}>
          <div 
            className="rounded-xl bg-gradient-to-br from-accent-500 to-accent-600 flex items-center justify-center flex-shrink-0"
            style={{ width: `${iconSize}px`, height: `${iconSize}px` }}
          >
            <Sparkles className="text-white" style={{ width: `${logoIconSize}px`, height: `${logoIconSize}px` }} />
          </div>
          <span className={`font-semibold text-white flex-shrink-0 ${textSize}`} style={{ fontSize: `${Math.round(18 * scale)}px` }}>
            TrafficAgent
          </span>
        </div>
      </div>

      <div className="px-4 py-3">
        <button
          onClick={() => onCreateConversation()}
          className="w-full flex items-center rounded-xl bg-gradient-to-r from-accent-500 to-accent-600 hover:opacity-90 transition-opacity text-white font-medium"
          style={{ 
            gap: `${Math.round(12 * scale)}px`, 
            padding: `${Math.round(12 * scale)}px ${Math.round(16 * scale)}px`,
            fontSize: `${Math.round(14 * scale)}px`
          }}
        >
          <Bot className="flex-shrink-0" style={{ width: `${Math.round(20 * scale)}px`, height: `${Math.round(20 * scale)}px` }} />
          <span className="flex-shrink-0">New Chat</span>
        </button>
      </div>

      <div className="px-4 py-2 border-t border-dark-600">
        <div className="flex items-center gap-2 text-dark-500 font-medium" style={{ fontSize: `${Math.round(14 * scale)}px` }}>
          <History className="flex-shrink-0" style={{ width: `${Math.round(16 * scale)}px`, height: `${Math.round(16 * scale)}px` }} />
          <span className="flex-shrink-0">History</span>
        </div>
        <div className="mt-2 space-y-1">
          {conversations.map((conversation) => (
            <div
              key={conversation.id}
              className="relative group"
              onMouseEnter={() => setHoveredId(conversation.id)}
              onMouseLeave={() => setHoveredId(null)}
            >
              <button
                onClick={() => setActiveConversation(conversation.id)}
                className={`w-full flex items-center gap-3 px-4 py-2.5 rounded-lg transition-all ${
                  activeConversationId === conversation.id
                    ? 'bg-dark-600 text-white'
                    : 'text-dark-400 hover:bg-dark-700 hover:text-white'
                }`}
                style={{ 
                  gap: `${Math.round(12 * scale)}px`, 
                  padding: `${Math.round(10 * scale)}px ${Math.round(16 * scale)}px`,
                  fontSize: `${Math.round(14 * scale)}px`
                }}
              >
                <MessageSquare className="flex-shrink-0" style={{ width: `${Math.round(16 * scale)}px`, height: `${Math.round(16 * scale)}px` }} />
                <span className="truncate flex-1">{conversation.title}</span>
                <span className="text-xs text-dark-500 flex-shrink-0" style={{ fontSize: `${Math.round(12 * scale)}px` }}>
                  {formatTime(conversation.updatedAt || conversation.createdAt)}
                </span>
                <ChevronRight className="flex-shrink-0 opacity-0 hover:opacity-100 transition-opacity" style={{ width: `${Math.round(16 * scale)}px`, height: `${Math.round(16 * scale)}px` }} />
              </button>

              <div
                className={`absolute right-2 top-1/2 -translate-y-1/2 flex items-center gap-1 transition-opacity duration-200 ${
                  hoveredId === conversation.id ? 'opacity-100' : 'opacity-0'
                }`}
                style={{ right: `${Math.round(8 * scale)}px`, gap: `${Math.round(4 * scale)}px` }}
              >
                <button
                  onClick={(e) => {
                    e.stopPropagation()
                    pinConversation(conversation.id)
                  }}
                  className="p-1.5 rounded-lg bg-dark-700 text-dark-400 hover:text-white hover:bg-dark-600 transition-colors"
                  title="置顶该记录"
                  style={{ padding: `${Math.round(6 * scale)}px` }}
                >
                  <Pin style={{ width: `${Math.round(14 * scale)}px`, height: `${Math.round(14 * scale)}px` }} />
                </button>
                <button
                  onClick={(e) => {
                    e.stopPropagation()
                    closeConversation(conversation.id)
                  }}
                  className="p-1.5 rounded-lg bg-dark-700 text-dark-400 hover:text-red-400 hover:bg-dark-600 transition-colors"
                  title="删除该记录"
                  style={{ padding: `${Math.round(6 * scale)}px` }}
                >
                  <Trash2 style={{ width: `${Math.round(14 * scale)}px`, height: `${Math.round(14 * scale)}px` }} />
                </button>
              </div>
            </div>
          ))}
        </div>
      </div>

      <div className="flex-1" />

      <div className="px-4 py-3 border-t border-dark-600">
        <div className="flex items-center gap-2 text-dark-500" style={{ fontSize: `${Math.round(12 * scale)}px`, gap: `${Math.round(8 * scale)}px` }}>
          <div className="rounded-full bg-green-500 flex-shrink-0" style={{ width: `${Math.round(8 * scale)}px`, height: `${Math.round(8 * scale)}px` }} />
          <span className="flex-shrink-0">TrafficAgent is online</span>
        </div>
      </div>
    </div>
  )
}
