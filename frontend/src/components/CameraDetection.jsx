import { useState, useEffect, useRef, useCallback } from 'react'
import { Camera, Play, Pause, RotateCcw, Settings, AlertCircle, Zap, Clock, ArrowLeft } from 'lucide-react'
import { useStore } from '../store/useStore'

export function CameraDetection() {
  const { user, theme } = useStore()
  const [isConnected, setIsConnected] = useState(false)
  const [isDetecting, setIsDetecting] = useState(false)
  const [annotatedFrame, setAnnotatedFrame] = useState(null)
  const [detections, setDetections] = useState([])
  const [fps, setFps] = useState(0)
  const [inferenceTime, setInferenceTime] = useState(0)
  const [error, setError] = useState(null)
  const [cameraAccess, setCameraAccess] = useState(false)
  const [config, setConfig] = useState({
    mode: 'cpu',
    conf: 0.25,
    scene_id: 1,
  })
  const [showConfig, setShowConfig] = useState(false)

  const videoRef = useRef(null)
  const canvasRef = useRef(null)
  const wsRef = useRef(null)
  const intervalRef = useRef(null)

  const wsUrl = window.location.protocol === 'https:' 
    ? `wss://${window.location.host}/ws/camera-detection`
    : `ws://${window.location.host}/ws/camera-detection`

  const connectWebSocket = useCallback(() => {
    if (!user?.token) {
      setError('请先登录')
      return
    }

    const ws = new WebSocket(`${wsUrl}?token=${user.token}`)

    ws.onopen = () => {
      setIsConnected(true)
      setError(null)
      ws.send(JSON.stringify({ type: 'config', ...config }))
    }

    ws.onmessage = (event) => {
      try {
        const data = JSON.parse(event.data)
        if (data.type === 'result') {
          setAnnotatedFrame(data.annotated_frame)
          setDetections(data.detections || [])
          setFps(data.fps || 0)
          setInferenceTime(data.inference_time || 0)
        } else if (data.type === 'error') {
          setError(data.message)
        } else if (data.type === 'config_ok') {
          setError(null)
        }
      } catch (e) {
        console.error('WebSocket消息解析失败:', e)
      }
    }

    ws.onerror = (event) => {
      setError('WebSocket连接错误')
      setIsConnected(false)
    }

    ws.onclose = () => {
      setIsConnected(false)
      setIsDetecting(false)
    }

    wsRef.current = ws
  }, [user, config, wsUrl])

  const disconnectWebSocket = useCallback(() => {
    if (wsRef.current) {
      wsRef.current.send(JSON.stringify({ type: 'close' }))
      wsRef.current.close()
      wsRef.current = null
    }
    setIsConnected(false)
    setIsDetecting(false)
  }, [])

  const startCamera = useCallback(async () => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        video: {
          facingMode: 'environment',
          width: { ideal: 1280 },
          height: { ideal: 720 },
        },
      })
      if (videoRef.current) {
        videoRef.current.srcObject = stream
        videoRef.current.play()
        setCameraAccess(true)
        setError(null)
      }
    } catch (e) {
      setError('无法访问摄像头，请检查权限设置')
      console.error('摄像头访问失败:', e)
    }
  }, [])

  const stopCamera = useCallback(() => {
    if (videoRef.current?.srcObject) {
      const stream = videoRef.current.srcObject
      stream.getTracks().forEach((track) => track.stop())
      videoRef.current.srcObject = null
      setCameraAccess(false)
    }
  }, [])

  const sendFrame = useCallback(() => {
    if (!wsRef.current || wsRef.current.readyState !== WebSocket.OPEN) return
    if (!videoRef.current || !canvasRef.current) return

    const canvas = canvasRef.current
    const ctx = canvas.getContext('2d')
    canvas.width = videoRef.current.videoWidth
    canvas.height = videoRef.current.videoHeight
    ctx.drawImage(videoRef.current, 0, 0)

    const dataUrl = canvas.toDataURL('image/jpeg', 0.7)
    const base64Data = dataUrl.split(',')[1]

    wsRef.current.send(JSON.stringify({
      type: 'frame',
      data: base64Data,
    }))
  }, [])

  const startDetection = useCallback(() => {
    if (!cameraAccess) {
      startCamera()
    }
    if (!isConnected) {
      connectWebSocket()
    }
    setIsDetecting(true)
    intervalRef.current = setInterval(sendFrame, 200)
  }, [cameraAccess, isConnected, connectWebSocket, sendFrame, startCamera])

  const stopDetection = useCallback(() => {
    setIsDetecting(false)
    if (intervalRef.current) {
      clearInterval(intervalRef.current)
      intervalRef.current = null
    }
    disconnectWebSocket()
  }, [disconnectWebSocket])

  useEffect(() => {
    return () => {
      stopDetection()
      stopCamera()
    }
  }, [stopDetection, stopCamera])

  const handleConfigChange = (key, value) => {
    setConfig(prev => ({ ...prev, [key]: value }))
  }

  const applyConfig = () => {
    if (wsRef.current && wsRef.current.readyState === WebSocket.OPEN) {
      wsRef.current.send(JSON.stringify({ type: 'config', ...config }))
    }
    setShowConfig(false)
  }

  const goBack = () => {
    stopDetection()
    stopCamera()
    window.dispatchEvent(new CustomEvent('closeCameraDetection'))
  }

  const isLight = theme === 'light'

  return (
    <div className={`h-full flex flex-col ${isLight ? 'bg-gray-50' : 'bg-dark-900'}`}>
      <div className={`flex items-center justify-between px-6 py-4 border-b ${isLight ? 'border-gray-200 bg-white' : 'border-dark-700 bg-dark-800'}`}>
        <div className="flex items-center gap-3">
          <button
            onClick={goBack}
            className={`p-2 rounded-lg hover:bg-opacity-20 transition-colors ${isLight ? 'hover:bg-gray-100 text-gray-600' : 'hover:bg-dark-700 text-dark-300'}`}
          >
            <ArrowLeft className="w-5 h-5" />
          </button>
          <div className="p-2 rounded-lg bg-accent-500/20">
            <Camera className="w-6 h-6 text-accent-500" />
          </div>
          <div>
            <h1 className={`text-xl font-semibold ${isLight ? 'text-gray-900' : 'text-white'}`}>摄像头检测</h1>
            <p className={`text-sm ${isLight ? 'text-gray-500' : 'text-dark-400'}`}>实时交通标志与信号灯识别</p>
          </div>
        </div>
        <div className="flex items-center gap-3">
          <button
            onClick={() => setShowConfig(!showConfig)}
            className={`flex items-center gap-2 px-4 py-2 rounded-lg transition-colors ${isLight ? 'bg-gray-100 text-gray-700 hover:bg-gray-200' : 'bg-dark-700 text-dark-300 hover:bg-dark-600'}`}
          >
            <Settings className="w-4 h-4" />
            <span className="text-sm">设置</span>
          </button>
          {isConnected ? (
            <div className="flex items-center gap-2 px-3 py-1.5 rounded-full bg-green-500/20 text-green-500">
              <div className="w-2 h-2 rounded-full bg-green-500 animate-pulse" />
              <span className="text-sm">已连接</span>
            </div>
          ) : (
            <div className="flex items-center gap-2 px-3 py-1.5 rounded-full bg-red-500/20 text-red-500">
              <div className="w-2 h-2 rounded-full bg-red-500" />
              <span className="text-sm">未连接</span>
            </div>
          )}
        </div>
      </div>

      {showConfig && (
        <div className={`px-6 py-4 border-b ${isLight ? 'border-gray-200 bg-gray-50' : 'border-dark-700 bg-dark-800'}`}>
          <div className="grid grid-cols-3 gap-6">
            <div>
              <label className={`block text-sm mb-2 ${isLight ? 'text-gray-600' : 'text-dark-400'}`}>推理模式</label>
              <select
                value={config.mode}
                onChange={(e) => handleConfigChange('mode', e.target.value)}
                className={`w-full px-4 py-2 rounded-lg border focus:outline-none focus:border-accent-500 transition-colors ${isLight ? 'bg-white border-gray-300 text-gray-900' : 'bg-dark-700 border-dark-600 text-white'}`}
              >
                <option value="cpu">CPU</option>
                <option value="gpu">GPU</option>
              </select>
            </div>
            <div>
              <label className={`block text-sm mb-2 ${isLight ? 'text-gray-600' : 'text-dark-400'}`}>置信度阈值</label>
              <input
                type="number"
                value={config.conf}
                onChange={(e) => handleConfigChange('conf', parseFloat(e.target.value))}
                min="0"
                max="1"
                step="0.05"
                className={`w-full px-4 py-2 rounded-lg border focus:outline-none focus:border-accent-500 transition-colors ${isLight ? 'bg-white border-gray-300 text-gray-900' : 'bg-dark-700 border-dark-600 text-white'}`}
              />
            </div>
            <div>
              <label className={`block text-sm mb-2 ${isLight ? 'text-gray-600' : 'text-dark-400'}`}>场景ID</label>
              <input
                type="number"
                value={config.scene_id}
                onChange={(e) => handleConfigChange('scene_id', parseInt(e.target.value))}
                min="1"
                className={`w-full px-4 py-2 rounded-lg border focus:outline-none focus:border-accent-500 transition-colors ${isLight ? 'bg-white border-gray-300 text-gray-900' : 'bg-dark-700 border-dark-600 text-white'}`}
              />
            </div>
          </div>
          <div className="mt-4 flex justify-end">
            <button
              onClick={applyConfig}
              className="px-4 py-2 rounded-lg bg-accent-500 text-white hover:bg-accent-600 transition-colors"
            >
              应用设置
            </button>
          </div>
        </div>
      )}

      <div className="flex-1 flex flex-col lg:flex-row p-6 gap-6 overflow-hidden">
        <div className={`flex-1 relative rounded-xl overflow-hidden border ${isLight ? 'bg-white border-gray-200' : 'bg-dark-800 border-dark-700'}`}>
          {annotatedFrame ? (
            <img
              src={`data:image/jpeg;base64,${annotatedFrame}`}
              alt="标注画面"
              className="w-full h-full object-cover"
            />
          ) : cameraAccess ? (
            <video
              ref={videoRef}
              className="w-full h-full object-cover"
              autoPlay
              playsInline
              muted
            />
          ) : (
            <div className={`w-full h-full flex flex-col items-center justify-center ${isLight ? 'text-gray-400' : 'text-dark-500'}`}>
              <Camera className="w-16 h-16 mb-4 opacity-50" />
              <p className="text-lg">点击开始检测以访问摄像头</p>
            </div>
          )}

          <div className="absolute top-4 left-4 flex flex-col gap-2">
            <div className="px-3 py-1.5 rounded-lg bg-black/60 text-white text-sm">
              <span className="text-dark-400">FPS: </span>
              <span className={fps >= 5 ? 'text-green-500' : fps >= 3 ? 'text-yellow-500' : 'text-red-500'}>
                {fps.toFixed(1)}
              </span>
            </div>
            <div className="px-3 py-1.5 rounded-lg bg-black/60 text-white text-sm">
              <span className="text-dark-400">延迟: </span>
              <span>{inferenceTime.toFixed(1)}ms</span>
            </div>
          </div>

          {error && (
            <div className="absolute top-4 right-4 flex items-center gap-2 px-4 py-2 rounded-lg bg-red-500/90 text-white">
              <AlertCircle className="w-4 h-4" />
              <span className="text-sm">{error}</span>
            </div>
          )}

          <canvas ref={canvasRef} className="hidden" />
        </div>

        <div className="w-full lg:w-80 flex flex-col gap-4">
          <div className="grid grid-cols-2 gap-4">
            <div className={`p-4 rounded-xl border ${isLight ? 'bg-white border-gray-200' : 'bg-dark-800 border-dark-700'}`}>
              <div className="flex items-center gap-2 mb-2">
                <Zap className="w-4 h-4 text-accent-500" />
                <span className={`text-sm ${isLight ? 'text-gray-500' : 'text-dark-400'}`}>检测目标</span>
              </div>
              <p className={`text-2xl font-semibold ${isLight ? 'text-gray-900' : 'text-white'}`}>{detections.length}</p>
            </div>
            <div className={`p-4 rounded-xl border ${isLight ? 'bg-white border-gray-200' : 'bg-dark-800 border-dark-700'}`}>
              <div className="flex items-center gap-2 mb-2">
                <Clock className="w-4 h-4 text-accent-500" />
                <span className={`text-sm ${isLight ? 'text-gray-500' : 'text-dark-400'}`}>推理耗时</span>
              </div>
              <p className={`text-2xl font-semibold ${isLight ? 'text-gray-900' : 'text-white'}`}>{inferenceTime.toFixed(1)}ms</p>
            </div>
          </div>

          <div className={`flex-1 rounded-xl border overflow-hidden flex flex-col ${isLight ? 'bg-white border-gray-200' : 'bg-dark-800 border-dark-700'}`}>
            <div className={`px-4 py-3 border-b ${isLight ? 'border-gray-200' : 'border-dark-700'}`}>
              <h3 className={`text-sm font-medium ${isLight ? 'text-gray-700' : 'text-dark-300'}`}>检测结果</h3>
            </div>
            <div className="flex-1 overflow-y-auto p-4">
              {detections.length > 0 ? (
                <div className="space-y-3">
                  {detections.map((det, idx) => (
                    <div
                      key={idx}
                      className={`p-3 rounded-lg border ${isLight ? 'bg-gray-50 border-gray-200' : 'bg-dark-700 border-dark-600'}`}
                    >
                      <div className="flex items-center justify-between mb-2">
                        <span className={`text-sm font-medium ${isLight ? 'text-gray-900' : 'text-white'}`}>{det.class_name}</span>
                        <span className={`text-xs px-2 py-0.5 rounded-full ${
                          det.confidence >= 0.7 ? 'bg-green-500/20 text-green-500' :
                          det.confidence >= 0.5 ? 'bg-yellow-500/20 text-yellow-500' :
                          'bg-red-500/20 text-red-500'
                        }`}>
                          {(det.confidence * 100).toFixed(0)}%
                        </span>
                      </div>
                      <div className={`text-xs ${isLight ? 'text-gray-500' : 'text-dark-400'}`}>
                        <span>位置: </span>
                        <span>[{det.bbox.map(b => Math.round(b)).join(', ')}]</span>
                      </div>
                    </div>
                  ))}
                </div>
              ) : (
                <div className={`flex flex-col items-center justify-center h-full ${isLight ? 'text-gray-400' : 'text-dark-500'}`}>
                  <div className={`w-12 h-12 rounded-full flex items-center justify-center mb-3 ${isLight ? 'bg-gray-100' : 'bg-dark-700'}`}>
                    <Camera className="w-6 h-6" />
                  </div>
                  <p className="text-sm">等待检测结果...</p>
                </div>
              )}
            </div>
          </div>

          <div className="flex gap-3">
            {!isDetecting ? (
              <button
                onClick={startDetection}
                className="flex-1 flex items-center justify-center gap-2 px-6 py-3 rounded-xl bg-accent-500 text-white hover:bg-accent-600 transition-colors font-medium"
              >
                <Play className="w-5 h-5" />
                <span>开始检测</span>
              </button>
            ) : (
              <button
                onClick={stopDetection}
                className="flex-1 flex items-center justify-center gap-2 px-6 py-3 rounded-xl bg-red-500 text-white hover:bg-red-600 transition-colors font-medium"
              >
                <Pause className="w-5 h-5" />
                <span>停止检测</span>
              </button>
            )}
            <button
              onClick={() => {
                stopDetection()
                stopCamera()
                setAnnotatedFrame(null)
                setDetections([])
                setFps(0)
                setInferenceTime(0)
                setError(null)
              }}
              className={`p-3 rounded-xl transition-colors ${isLight ? 'bg-gray-100 text-gray-600 hover:bg-gray-200' : 'bg-dark-700 text-dark-300 hover:bg-dark-600'}`}
              title="重置"
            >
              <RotateCcw className="w-5 h-5" />
            </button>
          </div>
        </div>
      </div>
    </div>
  )
}
