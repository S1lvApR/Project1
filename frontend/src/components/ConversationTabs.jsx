import { X, Plus, MessageSquare } from 'lucide-react'
import { useStore } from '../store/useStore'

export function ConversationTabs({ onCreateConversation }) {
  const { conversations, activeConversationId, setActiveConversation, closeConversation } = useStore()

  return (
    <div className="flex items-center gap-2 overflow-x-auto">
      {conversations.map((conversation) => (
        <div
          key={conversation.id}
          className={`flex items-center gap-2 px-3 py-2 rounded-lg whitespace-nowrap transition-all cursor-pointer ${
            activeConversationId === conversation.id
              ? 'bg-dark-600 text-white'
              : 'text-dark-400 hover:bg-dark-700 hover:text-white'
          }`}
          onClick={() => setActiveConversation(conversation.id)}
        >
          <MessageSquare className="w-4 h-4" />
          <span className="text-sm">{conversation.title}</span>
          <button
            onClick={(e) => {
              e.stopPropagation()
              closeConversation(conversation.id)
            }}
            className="w-6 h-6 rounded-full flex items-center justify-center hover:bg-dark-500 transition-colors"
          >
            <X className="w-3.5 h-3.5" />
          </button>
        </div>
      ))}

      <button
        onClick={onCreateConversation}
        className="w-9 h-9 rounded-lg bg-dark-700 hover:bg-dark-600 flex items-center justify-center text-dark-400 hover:text-white transition-colors flex-shrink-0"
      >
        <Plus className="w-4 h-4" />
      </button>
    </div>
  )
}
