import { useState, useEffect, useRef } from 'react'
import { User, LogOut, Sun, Moon, Mail, Lock, Upload, X, Camera } from 'lucide-react'
import { useNavigate } from 'react-router-dom'
import { useStore } from '../store/useStore'
import { LeftSidebar } from '../components/LeftSidebar'
import { ConversationTabs } from '../components/ConversationTabs'
import { ChatArea } from '../components/ChatArea'
import { ChatInput } from '../components/ChatInput'
import { LoginModal } from '../components/LoginModal'

export default function Home() {
  const navigate = useNavigate()
  const [isLoginModalOpen, setIsLoginModalOpen] = useState(false)
  const [showLogout, setShowLogout] = useState(false)
  const logoutTimeout = useRef(null)
  const [sidebarWidth, setSidebarWidth] = useState(256)
  const [chatInputHeight, setChatInputHeight] = useState(180)
  const [isResizingSidebar, setIsResizingSidebar] = useState(false)
  const [isResizingInput, setIsResizingInput] = useState(false)
  
  const [activeModal, setActiveModal] = useState(null)
  const [oldPassword, setOldPassword] = useState('')
  const [newPassword, setNewPassword] = useState('')
  const [confirmNewPassword, setConfirmNewPassword] = useState('')
  const [newEmail, setNewEmail] = useState('')
  const [avatarFile, setAvatarFile] = useState(null)
  const [avatarPreview, setAvatarPreview] = useState(null)
  const [modalError, setModalError] = useState('')
  const [modalSuccess, setModalSuccess] = useState('')
  
  const { user, addConversation, logout, getCurrentUser, theme, toggleTheme, changePassword, updateEmail, uploadAvatar, loading } = useStore()

  useEffect(() => {
    const token = localStorage.getItem('token')
    if (token && !user) {
      getCurrentUser()
    }
  }, [getCurrentUser, user])

  const handleCreateConversation = async () => {
    await addConversation()
  }

  const handleSidebarMouseDown = (e) => {
    e.preventDefault()
    setIsResizingSidebar(true)
  }

  const handleInputMouseDown = (e) => {
    e.preventDefault()
    setIsResizingInput(true)
  }

  useEffect(() => {
    const handleMouseMove = (e) => {
      if (isResizingSidebar) {
        const newWidth = Math.max(200, Math.min(500, e.clientX))
        setSidebarWidth(newWidth)
      }
      if (isResizingInput) {
        const containerRect = document.querySelector('.chat-container')?.getBoundingClientRect()
        if (containerRect) {
          const newHeight = Math.max(140, Math.min(400, containerRect.bottom - e.clientY))
          setChatInputHeight(newHeight)
        }
      }
    }

    const handleMouseUp = () => {
      setIsResizingSidebar(false)
      setIsResizingInput(false)
    }

    if (isResizingSidebar || isResizingInput) {
      document.addEventListener('mousemove', handleMouseMove)
      document.addEventListener('mouseup', handleMouseUp)
    }

    return () => {
      document.removeEventListener('mousemove', handleMouseMove)
      document.removeEventListener('mouseup', handleMouseUp)
    }
  }, [isResizingSidebar, isResizingInput])

  return (
    <div className={`flex h-screen bg-dark-900 ${theme === 'light' ? 'theme-light' : ''}`}>
      <LeftSidebar onCreateConversation={handleCreateConversation} style={{ width: `${sidebarWidth}px` }} />

      <div
        className={`w-1 bg-dark-600 cursor-col-resize hover:bg-dark-500 transition-colors ${isResizingSidebar ? 'bg-accent-500' : ''}`}
        onMouseDown={handleSidebarMouseDown}
      />

      <div className="flex-1 flex flex-col min-w-0 chat-container">
        <div className="bg-dark-800 border-b border-dark-600">
          <div className="h-12 flex items-center justify-between px-4">
            <div className="flex-1 flex items-center">
              <ConversationTabs onCreateConversation={handleCreateConversation} />
            </div>

            <div className="flex items-center gap-3">
              <button
                onClick={() => navigate('/camera')}
                className="flex h-9 w-9 items-center justify-center rounded-lg bg-dark-700 text-dark-300 transition-colors hover:bg-dark-600 hover:text-white"
                title="摄像头实时检测"
              >
                <Camera className="h-4 w-4" />
              </button>
              {!user && (
                <button
                  onClick={() => setIsLoginModalOpen(true)}
                  className="px-4 py-2 rounded-xl bg-gradient-to-r from-accent-500 to-accent-600 text-white font-medium hover:opacity-90 transition-opacity"
                >
                  Login
                </button>
              )}

              {user && (
                <div className="relative" onMouseEnter={() => {
                  clearTimeout(logoutTimeout.current)
                  setShowLogout(true)
                }} onMouseLeave={() => {
                  logoutTimeout.current = setTimeout(() => setShowLogout(false), 500)
                }}>
                  <div className="flex items-center gap-3">
                    <div className="relative">
                      <button className="w-10 h-10 rounded-xl bg-gradient-to-br from-accent-500 to-accent-600 flex items-center justify-center text-white">
                        {user.avatar ? (
                          <img src={user.avatar} alt="Avatar" className="w-full h-full rounded-xl object-cover" />
                        ) : (
                          <User className="w-5 h-5" />
                        )}
                      </button>
                      <div className="absolute -bottom-1 -right-1 w-4 h-4 bg-green-500 rounded-full border-2 border-dark-800" />
                    </div>
                    <div className="hidden md:block">
                      <p className="text-sm font-medium text-white">{user.name}</p>
                      <p className="text-xs text-dark-400">{user.email}</p>
                    </div>
                  </div>

                  {showLogout && (
                    <div className="absolute right-0 top-full mt-2 w-48 bg-dark-700 rounded-xl border border-dark-600 shadow-lg py-2 animate-fadeIn z-50">
                      <button
                        onClick={toggleTheme}
                        className="w-full flex items-center gap-3 px-4 py-1.5 text-xs text-dark-300 hover:bg-dark-600 hover:text-white transition-colors"
                      >
                        {theme === 'dark' ? (
                          <>
                            <Sun className="w-3.5 h-3.5" />
                            <span>切换日间模式</span>
                          </>
                        ) : (
                          <>
                            <Moon className="w-3.5 h-3.5" />
                            <span>切换夜间模式</span>
                          </>
                        )}
                      </button>
                      <button
                        onClick={() => { setActiveModal('password'); setShowLogout(false) }}
                        className="w-full flex items-center gap-3 px-4 py-1.5 text-xs text-dark-300 hover:bg-dark-600 hover:text-white transition-colors"
                      >
                        <Lock className="w-3.5 h-3.5" />
                        <span>修改密码</span>
                      </button>
                      <button
                        onClick={() => { setActiveModal('email'); setShowLogout(false) }}
                        className="w-full flex items-center gap-3 px-4 py-1.5 text-xs text-dark-300 hover:bg-dark-600 hover:text-white transition-colors"
                      >
                        <Mail className="w-3.5 h-3.5" />
                        <span>修改邮箱</span>
                      </button>
                      <button
                        onClick={() => { setActiveModal('avatar'); setShowLogout(false) }}
                        className="w-full flex items-center gap-3 px-4 py-1.5 text-xs text-dark-300 hover:bg-dark-600 hover:text-white transition-colors"
                      >
                        <Upload className="w-3.5 h-3.5" />
                        <span>上传头像</span>
                      </button>
                      <div className="border-t border-dark-600 my-1" />
                      <button
                        onClick={logout}
                        className="w-full flex items-center gap-3 px-4 py-1.5 text-xs text-dark-300 hover:bg-dark-600 hover:text-white transition-colors"
                      >
                        <LogOut className="w-3.5 h-3.5" />
                        <span>退出账户</span>
                      </button>
                    </div>
                  )}
                </div>
              )}
            </div>
          </div>
        </div>

        <ChatArea />

        <div
          className={`h-1 bg-dark-600 cursor-row-resize hover:bg-dark-500 transition-colors ${isResizingInput ? 'bg-accent-500' : ''}`}
          onMouseDown={handleInputMouseDown}
        />

        <ChatInput style={{ height: `${chatInputHeight}px` }} />
      </div>

      <LoginModal
        isOpen={isLoginModalOpen}
        onClose={() => setIsLoginModalOpen(false)}
      />

      {activeModal && (
        <div className="fixed inset-0 z-50 flex items-center justify-center">
          <div
            className="absolute inset-0 bg-black/60 backdrop-blur-sm"
            onClick={() => { setActiveModal(null); setModalError(''); setModalSuccess('') }}
          />

          <div className="relative w-full max-w-md mx-4 bg-dark-800 rounded-2xl border border-dark-600 shadow-2xl animate-fadeIn">
            <button
              onClick={() => { setActiveModal(null); setModalError(''); setModalSuccess('') }}
              className="absolute top-4 right-4 w-8 h-8 rounded-lg text-dark-400 hover:text-white hover:bg-dark-700 transition-colors"
            >
              <X className="w-5 h-5" />
            </button>

            <div className="p-8">
              <h2 className="text-xl font-semibold text-white mb-6">
                {activeModal === 'password' && '修改密码'}
                {activeModal === 'email' && '修改邮箱'}
                {activeModal === 'avatar' && '上传头像'}
              </h2>

              {activeModal === 'password' && (
                <form onSubmit={(e) => {
                  e.preventDefault()
                  setModalError('')
                  if (!oldPassword) { setModalError('请输入旧密码'); return }
                  if (!newPassword) { setModalError('请输入新密码'); return }
                  if (newPassword.length < 6) { setModalError('新密码至少需要6位'); return }
                  if (newPassword !== confirmNewPassword) { setModalError('两次输入的密码不一致'); return }
                  
                  changePassword(oldPassword, newPassword)
                    .then(() => {
                      setModalSuccess('密码修改成功')
                      setOldPassword('')
                      setNewPassword('')
                      setConfirmNewPassword('')
                      setTimeout(() => setActiveModal(null), 2000)
                    })
                    .catch(err => setModalError(err.message))
                }} className="space-y-4">
                  <div>
                    <label className="block text-sm font-medium text-dark-300 mb-2">旧密码</label>
                    <input
                      type="password"
                      value={oldPassword}
                      onChange={(e) => setOldPassword(e.target.value)}
                      placeholder="Enter your old password"
                      className="w-full px-4 py-3 rounded-xl bg-dark-900 border border-dark-600 text-white placeholder-dark-500 focus:outline-none focus:border-accent-500 transition-colors"
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-dark-300 mb-2">新密码</label>
                    <input
                      type="password"
                      value={newPassword}
                      onChange={(e) => setNewPassword(e.target.value)}
                      placeholder="Enter your new password"
                      className="w-full px-4 py-3 rounded-xl bg-dark-900 border border-dark-600 text-white placeholder-dark-500 focus:outline-none focus:border-accent-500 transition-colors"
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-dark-300 mb-2">确认新密码</label>
                    <input
                      type="password"
                      value={confirmNewPassword}
                      onChange={(e) => setConfirmNewPassword(e.target.value)}
                      placeholder="Confirm your new password"
                      className="w-full px-4 py-3 rounded-xl bg-dark-900 border border-dark-600 text-white placeholder-dark-500 focus:outline-none focus:border-accent-500 transition-colors"
                    />
                  </div>

                  {modalError && <div className="text-red-400 text-sm">{modalError}</div>}
                  {modalSuccess && <div className="text-green-400 text-sm">{modalSuccess}</div>}

                  <button
                    type="submit"
                    disabled={loading}
                    className="w-full py-3 rounded-xl bg-gradient-to-r from-accent-500 to-accent-600 text-white font-medium hover:opacity-90 transition-opacity disabled:opacity-50"
                  >
                    {loading ? 'Loading...' : '修改密码'}
                  </button>
                </form>
              )}

              {activeModal === 'email' && (
                <form onSubmit={(e) => {
                  e.preventDefault()
                  setModalError('')
                  if (!newEmail) { setModalError('请输入新邮箱'); return }
                  if (!newEmail.includes('@')) { setModalError('请输入有效的邮箱地址'); return }
                  
                  updateEmail(newEmail)
                    .then(() => {
                      setModalSuccess('邮箱修改成功')
                      setNewEmail('')
                      setTimeout(() => setActiveModal(null), 2000)
                    })
                    .catch(err => setModalError(err.message))
                }} className="space-y-4">
                  <div>
                    <label className="block text-sm font-medium text-dark-300 mb-2">当前邮箱</label>
                    <input
                      type="email"
                      value={user?.email || ''}
                      disabled
                      className="w-full px-4 py-3 rounded-xl bg-dark-900 border border-dark-600 text-dark-400 placeholder-dark-500 cursor-not-allowed"
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-dark-300 mb-2">新邮箱</label>
                    <input
                      type="email"
                      value={newEmail}
                      onChange={(e) => setNewEmail(e.target.value)}
                      placeholder="Enter your new email"
                      className="w-full px-4 py-3 rounded-xl bg-dark-900 border border-dark-600 text-white placeholder-dark-500 focus:outline-none focus:border-accent-500 transition-colors"
                    />
                  </div>

                  {modalError && <div className="text-red-400 text-sm">{modalError}</div>}
                  {modalSuccess && <div className="text-green-400 text-sm">{modalSuccess}</div>}

                  <button
                    type="submit"
                    disabled={loading}
                    className="w-full py-3 rounded-xl bg-gradient-to-r from-accent-500 to-accent-600 text-white font-medium hover:opacity-90 transition-opacity disabled:opacity-50"
                  >
                    {loading ? 'Loading...' : '修改邮箱'}
                  </button>
                </form>
              )}

              {activeModal === 'avatar' && (
                <div className="space-y-4">
                  <div className="flex flex-col items-center">
                    <div className="w-32 h-32 rounded-2xl bg-gradient-to-br from-accent-500 to-accent-600 flex items-center justify-center mb-4 relative">
                      {avatarPreview ? (
                        <img src={avatarPreview} alt="Preview" className="w-full h-full rounded-2xl object-cover" />
                      ) : user?.avatar ? (
                        <img src={user.avatar} alt="Current" className="w-full h-full rounded-2xl object-cover" />
                      ) : (
                        <User className="w-12 h-12 text-white" />
                      )}
                    </div>
                    <p className="text-dark-400 text-sm">支持 JPG、PNG、BMP 格式，大小不超过 2MB</p>
                  </div>

                  <input
                    type="file"
                    accept="image/jpeg,image/png,image/bmp"
                    onChange={(e) => {
                      const file = e.target.files[0]
                      if (!file) return

                      if (file.size > 2 * 1024 * 1024) {
                        setModalError('图片大小不能超过2MB')
                        return
                      }

                      const allowedTypes = ['image/jpeg', 'image/png', 'image/bmp']
                      if (!allowedTypes.includes(file.type)) {
                        setModalError('不支持的文件格式')
                        return
                      }

                      setModalError('')
                      setAvatarFile(file)
                      setAvatarPreview(URL.createObjectURL(file))
                    }}
                    className="w-full px-4 py-3 rounded-xl bg-dark-900 border border-dark-600 text-white cursor-pointer hover:border-accent-500 transition-colors"
                  />

                  {modalError && <div className="text-red-400 text-sm">{modalError}</div>}
                  {modalSuccess && <div className="text-green-400 text-sm">{modalSuccess}</div>}

                  <button
                    onClick={() => {
                      if (!avatarFile) { setModalError('请先选择图片'); return }
                      
                      uploadAvatar(avatarFile)
                        .then(() => {
                          setModalSuccess('头像上传成功')
                          setAvatarFile(null)
                          setAvatarPreview(null)
                          setTimeout(() => setActiveModal(null), 2000)
                        })
                        .catch(err => setModalError(err.message))
                    }}
                    disabled={loading || !avatarFile}
                    className="w-full py-3 rounded-xl bg-gradient-to-r from-accent-500 to-accent-600 text-white font-medium hover:opacity-90 transition-opacity disabled:opacity-50"
                  >
                    {loading ? 'Loading...' : '上传头像'}
                  </button>
                </div>
              )}
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
