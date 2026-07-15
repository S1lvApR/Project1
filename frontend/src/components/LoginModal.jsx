import { useState } from 'react'
import { X, Mail, Lock, Sparkles, User, ArrowLeft } from 'lucide-react'
import { useStore } from '../store/useStore'

export function LoginModal({ isOpen, onClose }) {
  const [isLogin, setIsLogin] = useState(true)
  const [isForgotPassword, setIsForgotPassword] = useState(false)
  const [username, setUsername] = useState('')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [confirmPassword, setConfirmPassword] = useState('')
  const [error, setError] = useState('')
  const { login, register, forgotPassword, loading } = useStore()

  const handleSubmit = async (e) => {
    e.preventDefault()
    setError('')

    if (isForgotPassword) {
      if (!email) {
        setError('Please enter your email')
        return
      }

      if (!email.includes('@')) {
        setError('Please enter a valid email address')
        return
      }

      try {
        await forgotPassword(email)
        setError('Password reset link has been sent to your email!')
        setEmail('')
        setTimeout(() => {
          setIsForgotPassword(false)
          setError('')
        }, 3000)
      } catch (err) {
        setError(err.message || 'Failed to send reset email')
      }
      return
    }

    if (isLogin) {
      if (!username || !password) {
        setError('Please fill in all fields')
        return
      }

      try {
        await login(username, password)
        onClose()
        setUsername('')
        setPassword('')
      } catch (err) {
        setError(err.message || 'Login failed')
      }
    } else {
      if (!username || !email || !password || !confirmPassword) {
        setError('Please fill in all fields')
        return
      }

      if (!email.includes('@')) {
        setError('Please enter a valid email address')
        return
      }

      if (password !== confirmPassword) {
        setError('Passwords do not match')
        return
      }

      if (password.length < 6) {
        setError('Password must be at least 6 characters')
        return
      }

      try {
        await register(username, email, password)
        setIsLogin(true)
        setError('Registration successful! Please login.')
        setUsername('')
        setEmail('')
        setPassword('')
        setConfirmPassword('')
      } catch (err) {
        setError(err.message || 'Registration failed')
      }
    }
  }

  if (!isOpen) return null

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      <div
        className="absolute inset-0 bg-black/60 backdrop-blur-sm"
        onClick={onClose}
      />

      <div className="relative w-full max-w-md mx-4 bg-dark-800 rounded-2xl border border-dark-600 shadow-2xl animate-fadeIn">
        <button
          onClick={onClose}
          className="absolute top-4 right-4 w-8 h-8 rounded-lg text-dark-400 hover:text-white hover:bg-dark-700 transition-colors"
        >
          <X className="w-5 h-5" />
        </button>

        <div className="p-8">
          <div className="flex flex-col items-center mb-8">
            <div className="w-16 h-16 rounded-2xl bg-gradient-to-br from-accent-500 to-accent-600 flex items-center justify-center mb-4">
              <Sparkles className="w-8 h-8 text-white" />
            </div>
            <h2 className="text-2xl font-semibold text-white">
              {isForgotPassword ? 'Forgot Password' : isLogin ? 'Welcome Back' : 'Create Account'}
            </h2>
            <p className="text-dark-400 text-sm mt-1">
              {isForgotPassword ? 'Enter your email to reset password' : isLogin ? 'Sign in to your account' : 'Create a new account'}
            </p>
          </div>

          <form onSubmit={handleSubmit} className="space-y-4">
            {isForgotPassword ? (
              <div>
                <label className="block text-sm font-medium text-dark-300 mb-2">
                  Email
                </label>
                <div className="relative">
                  <Mail className="absolute left-4 top-1/2 -translate-y-1/2 w-5 h-5 text-dark-500" />
                  <input
                    type="email"
                    value={email}
                    onChange={(e) => setEmail(e.target.value)}
                    placeholder="Enter your email"
                    className="w-full pl-12 pr-4 py-3 rounded-xl bg-dark-900 border border-dark-600 text-white placeholder-dark-500 focus:outline-none focus:border-accent-500 transition-colors"
                  />
                </div>
              </div>
            ) : (
              <>
                {!isLogin && (
                  <div>
                    <label className="block text-sm font-medium text-dark-300 mb-2">
                      Username
                    </label>
                    <div className="relative">
                      <User className="absolute left-4 top-1/2 -translate-y-1/2 w-5 h-5 text-dark-500" />
                      <input
                        type="text"
                        value={username}
                        onChange={(e) => setUsername(e.target.value)}
                        placeholder="Enter your username"
                        className="w-full pl-12 pr-4 py-3 rounded-xl bg-dark-900 border border-dark-600 text-white placeholder-dark-500 focus:outline-none focus:border-accent-500 transition-colors"
                      />
                    </div>
                  </div>
                )}

                <div>
                  <label className="block text-sm font-medium text-dark-300 mb-2">
                    {isLogin ? 'Username' : 'Email'}
                  </label>
                  <div className="relative">
                    {isLogin ? (
                      <User className="absolute left-4 top-1/2 -translate-y-1/2 w-5 h-5 text-dark-500" />
                    ) : (
                      <Mail className="absolute left-4 top-1/2 -translate-y-1/2 w-5 h-5 text-dark-500" />
                    )}
                    <input
                      type={isLogin ? 'text' : 'email'}
                      value={isLogin ? username : email}
                      onChange={(e) => isLogin ? setUsername(e.target.value) : setEmail(e.target.value)}
                      placeholder={isLogin ? 'Enter your username' : 'Enter your email'}
                      className="w-full pl-12 pr-4 py-3 rounded-xl bg-dark-900 border border-dark-600 text-white placeholder-dark-500 focus:outline-none focus:border-accent-500 transition-colors"
                    />
                  </div>
                </div>

                <div>
                  <label className="block text-sm font-medium text-dark-300 mb-2">
                    Password
                  </label>
                  <div className="relative">
                    <Lock className="absolute left-4 top-1/2 -translate-y-1/2 w-5 h-5 text-dark-500" />
                    <input
                      type="password"
                      value={password}
                      onChange={(e) => setPassword(e.target.value)}
                      placeholder="Enter your password"
                      className="w-full pl-12 pr-4 py-3 rounded-xl bg-dark-900 border border-dark-600 text-white placeholder-dark-500 focus:outline-none focus:border-accent-500 transition-colors"
                    />
                  </div>
                </div>

                {!isLogin && (
                  <div>
                    <label className="block text-sm font-medium text-dark-300 mb-2">
                      Confirm Password
                    </label>
                    <div className="relative">
                      <Lock className="absolute left-4 top-1/2 -translate-y-1/2 w-5 h-5 text-dark-500" />
                      <input
                        type="password"
                        value={confirmPassword}
                        onChange={(e) => setConfirmPassword(e.target.value)}
                        placeholder="Confirm your password"
                        className="w-full pl-12 pr-4 py-3 rounded-xl bg-dark-900 border border-dark-600 text-white placeholder-dark-500 focus:outline-none focus:border-accent-500 transition-colors"
                      />
                    </div>
                  </div>
                )}
              </>
            )}

            {error && (
              <div className={`text-sm ${error.includes('successful') ? 'text-green-400' : 'text-red-400'}`}>
                {error}
              </div>
            )}

            <button
              type="submit"
              disabled={loading}
              className="w-full py-3 rounded-xl bg-gradient-to-r from-accent-500 to-accent-600 text-white font-medium hover:opacity-90 transition-opacity disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {loading ? 'Loading...' : isForgotPassword ? 'Send Reset Link' : (isLogin ? 'Sign In' : 'Sign Up')}
            </button>
          </form>

          <div className="mt-6 text-center">
            {isForgotPassword ? (
              <button
                onClick={() => {
                  setIsForgotPassword(false)
                  setError('')
                  setEmail('')
                }}
                className="text-accent-500 hover:text-accent-400 transition-colors flex items-center gap-1 mx-auto"
              >
                <ArrowLeft className="w-4 h-4" />
                Back to login
              </button>
            ) : (
              <>
                {isLogin && (
                  <p className="text-dark-400 text-sm mb-2">
                    <button
                      onClick={() => {
                        setIsForgotPassword(true)
                        setError('')
                        setUsername('')
                        setPassword('')
                      }}
                      className="text-accent-500 hover:text-accent-400 transition-colors"
                    >
                      Forgot password?
                    </button>
                  </p>
                )}
                <p className="text-dark-400 text-sm">
                  {isLogin ? "Don't have an account? " : 'Already have an account? '}
                  <button
                    onClick={() => {
                      setIsLogin(!isLogin)
                      setError('')
                      setUsername('')
                      setEmail('')
                      setPassword('')
                      setConfirmPassword('')
                    }}
                    className="text-accent-500 hover:text-accent-400 transition-colors"
                  >
                    {isLogin ? 'Sign up' : 'Sign in'}
                  </button>
                </p>
              </>
            )}
          </div>
        </div>
      </div>
    </div>
  )
}
