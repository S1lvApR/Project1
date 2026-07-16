import { useCallback, useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import {
  ArrowLeft,
  Camera,
  CircleGauge,
  Cpu,
  Gauge,
  Loader2,
  Play,
  ScanLine,
  Square,
  Timer,
  VideoOff,
} from 'lucide-react'

import { CameraDetectionClient } from '../api/cameraClient'


const MODES = [
  { value: 'auto', label: '自动' },
  { value: 'gpu', label: 'GPU' },
  { value: 'cpu', label: 'CPU' },
]


export default function CameraDetection() {
  const navigate = useNavigate()
  const videoRef = useRef(null)
  const canvasRef = useRef(null)
  const streamRef = useRef(null)
  const clientRef = useRef(null)
  const captureTimerRef = useRef(null)
  const activeRef = useRef(false)
  const sessionRef = useRef(0)
  const sendWidthRef = useRef(640)
  const [mode, setMode] = useState('auto')
  const [confidence, setConfidence] = useState(0.25)
  const [connection, setConnection] = useState('idle')
  const [device, setDevice] = useState('-')
  const [stats, setStats] = useState({ fps: 0, inference: 0, frames: 0 })
  const [detections, setDetections] = useState([])
  const [error, setError] = useState('')

  const scheduleCapture = useCallback((callback, delay = 0) => {
    clearTimeout(captureTimerRef.current)
    captureTimerRef.current = setTimeout(callback, delay)
  }, [])

  const captureFrame = useCallback(() => {
    if (!activeRef.current || !clientRef.current || !videoRef.current) return
    const video = videoRef.current
    if (!video.videoWidth || !video.videoHeight) {
      scheduleCapture(captureFrame, 100)
      return
    }
    const capture = document.createElement('canvas')
    const width = sendWidthRef.current
    capture.width = width
    capture.height = Math.max(1, Math.round(width * video.videoHeight / video.videoWidth))
    capture.getContext('2d').drawImage(video, 0, 0, capture.width, capture.height)
    const encoded = capture.toDataURL('image/jpeg', 0.72).split(',', 2)[1]
    if (!clientRef.current.sendFrame(encoded)) {
      scheduleCapture(captureFrame, 30)
    }
  }, [scheduleCapture])

  const drawResult = useCallback((encodedFrame) => {
    return new Promise((resolve) => {
      const image = new Image()
      image.onload = () => {
        const canvas = canvasRef.current
        if (canvas) {
          canvas.width = image.naturalWidth
          canvas.height = image.naturalHeight
          canvas.getContext('2d').drawImage(image, 0, 0)
        }
        resolve()
      }
      image.onerror = resolve
      image.src = `data:image/jpeg;base64,${encodedFrame}`
    })
  }, [])

  const releaseMedia = useCallback(() => {
    streamRef.current?.getTracks().forEach((track) => track.stop())
    streamRef.current = null
    if (videoRef.current) videoRef.current.srcObject = null
  }, [])

  const stopDetection = useCallback(() => {
    sessionRef.current += 1
    activeRef.current = false
    clearTimeout(captureTimerRef.current)
    clientRef.current?.close()
    clientRef.current = null
    releaseMedia()
    setConnection('idle')
  }, [releaseMedia])

  const startDetection = useCallback(async () => {
    setError('')
    if (!localStorage.getItem('token')) {
      setError('请先登录后再使用摄像头检测')
      return
    }
    if (!navigator.mediaDevices?.getUserMedia) {
      setError('当前浏览器不支持摄像头访问')
      return
    }
    stopDetection()
    const session = sessionRef.current
    setConnection('requesting')
    setStats({ fps: 0, inference: 0, frames: 0 })
    setDetections([])
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: 'environment', width: { ideal: 1280 }, height: { ideal: 720 } },
        audio: false,
      })
      if (session !== sessionRef.current) {
        stream.getTracks().forEach((track) => track.stop())
        return
      }
      streamRef.current = stream
      if (!videoRef.current) {
        stream.getTracks().forEach((track) => track.stop())
        return
      }
      videoRef.current.srcObject = stream
      await videoRef.current.play()
      if (session !== sessionRef.current) {
        stream.getTracks().forEach((track) => track.stop())
        if (streamRef.current === stream) streamRef.current = null
        if (videoRef.current?.srcObject === stream) {
          videoRef.current.srcObject = null
        }
        return
      }
      setConnection('connecting')
      const client = new CameraDetectionClient({
        onMessage: async (message) => {
          if (session !== sessionRef.current) return
          if (message.type === 'config_ok') {
            setDevice(message.device)
            sendWidthRef.current = message.image_size || 640
            activeRef.current = true
            setConnection('active')
            scheduleCapture(captureFrame)
          } else if (message.type === 'result') {
            setStats({
              fps: message.fps || 0,
              inference: message.inference_time || 0,
              frames: message.frame_count || 0,
            })
            setDetections(message.detections || [])
            await drawResult(message.annotated_frame)
            if (session === sessionRef.current && activeRef.current) {
              scheduleCapture(captureFrame, message.device === 'cpu' ? 120 : 20)
            }
          }
        },
        onError: (message) => {
          if (session !== sessionRef.current) return
          setError(message)
          if (activeRef.current) scheduleCapture(captureFrame, 150)
        },
        onClose: () => {
          if (session !== sessionRef.current) return
          sessionRef.current += 1
          activeRef.current = false
          clearTimeout(captureTimerRef.current)
          clientRef.current = null
          releaseMedia()
          setConnection('idle')
        },
      })
      clientRef.current = client
      client.connect({ mode, conf: confidence, iou: 0.45 })
    } catch (reason) {
      if (session !== sessionRef.current) return
      stopDetection()
      setError(reason?.message || '无法启动摄像头')
    }
  }, [captureFrame, confidence, drawResult, mode, releaseMedia, scheduleCapture, stopDetection])

  useEffect(() => () => {
    sessionRef.current += 1
    activeRef.current = false
    clearTimeout(captureTimerRef.current)
    clientRef.current?.close()
    clientRef.current = null
    releaseMedia()
  }, [releaseMedia])

  const isStarting = connection === 'requesting' || connection === 'connecting'
  const isActive = connection === 'active'

  return (
    <div className="flex min-h-screen flex-col bg-dark-900 text-white">
      <header className="flex min-h-14 flex-wrap items-center gap-3 border-b border-dark-600 bg-dark-800 px-4 py-2">
        <button
          onClick={() => navigate('/')}
          className="flex h-9 w-9 items-center justify-center rounded-lg text-dark-300 hover:bg-dark-700 hover:text-white"
          title="返回对话"
        >
          <ArrowLeft className="h-4 w-4" />
        </button>
        <div className="min-w-36 flex-1">
          <h1 className="whitespace-nowrap text-base font-semibold">摄像头实时检测</h1>
          <p className="text-xs text-dark-400">{isActive ? `设备 ${device}` : '摄像头未连接'}</p>
        </div>

        <div className="flex rounded-lg border border-dark-600 bg-dark-900 p-1" aria-label="推理模式">
          {MODES.map((item) => (
            <button
              key={item.value}
              onClick={() => setMode(item.value)}
              disabled={isActive || isStarting}
              className={`min-w-14 rounded-md px-3 py-1.5 text-xs transition-colors ${
                mode === item.value
                  ? 'bg-accent-500 text-white'
                  : 'text-dark-300 hover:bg-dark-700 hover:text-white'
              } disabled:opacity-50`}
            >
              {item.label}
            </button>
          ))}
        </div>

        <label className="flex min-w-48 items-center gap-3 text-xs text-dark-300">
          <Gauge className="h-4 w-4" />
          <span>置信度 {Math.round(confidence * 100)}%</span>
          <input
            type="range"
            min="0.1"
            max="0.9"
            step="0.05"
            value={confidence}
            disabled={isActive || isStarting}
            onChange={(event) => setConfidence(Number(event.target.value))}
            className="w-24 accent-violet-500"
          />
        </label>

        {isActive || isStarting ? (
          <button
            onClick={stopDetection}
            className="flex h-9 items-center gap-2 rounded-lg bg-red-500 px-3 text-sm text-white hover:bg-red-400"
          >
            <Square className="h-4 w-4" />
            停止检测
          </button>
        ) : (
          <button
            onClick={startDetection}
            className="flex h-9 items-center gap-2 rounded-lg bg-accent-500 px-3 text-sm text-white hover:bg-accent-400"
          >
            <Play className="h-4 w-4" />
            开始检测
          </button>
        )}
      </header>

      {error && (
        <div className="border-b border-red-500/30 bg-red-500/10 px-4 py-2 text-sm text-red-300">
          {error}
        </div>
      )}

      <main className="grid min-h-0 flex-1 grid-cols-1 lg:grid-cols-[minmax(0,1fr)_300px]">
        <section className="relative flex min-h-[420px] items-center justify-center overflow-hidden bg-black lg:min-h-0">
          <video ref={videoRef} muted playsInline className="hidden" />
          <canvas ref={canvasRef} className="max-h-full max-w-full object-contain" />
          {!isActive && (
            <div className="absolute inset-0 flex items-center justify-center bg-dark-900 text-dark-400">
              {isStarting ? (
                <Loader2 className="h-9 w-9 animate-spin text-accent-400" aria-label="正在连接摄像头" />
              ) : (
                <VideoOff className="h-10 w-10" aria-label="摄像头未启动" />
              )}
            </div>
          )}
          {isActive && (
            <div className="absolute left-3 top-3 flex items-center gap-2 rounded bg-black/70 px-2 py-1 text-xs">
              <span className="h-2 w-2 rounded-full bg-green-400" />
              LIVE
            </div>
          )}
        </section>

        <aside className="overflow-y-auto border-l border-dark-600 bg-dark-800">
          <section className="border-b border-dark-600 p-4">
            <h2 className="mb-4 flex items-center gap-2 text-sm font-medium">
              <CircleGauge className="h-4 w-4 text-accent-400" />
              实时统计
            </h2>
            <dl className="grid grid-cols-2 gap-4 text-sm">
              <div>
                <dt className="flex items-center gap-1 text-xs text-dark-400"><ScanLine className="h-3.5 w-3.5" />帧率</dt>
                <dd className="mt-1 text-lg">{stats.fps.toFixed(1)} FPS</dd>
              </div>
              <div>
                <dt className="flex items-center gap-1 text-xs text-dark-400"><Timer className="h-3.5 w-3.5" />推理耗时</dt>
                <dd className="mt-1 text-lg">{stats.inference.toFixed(1)} ms</dd>
              </div>
              <div>
                <dt className="flex items-center gap-1 text-xs text-dark-400"><Camera className="h-3.5 w-3.5" />处理帧数</dt>
                <dd className="mt-1 text-lg">{stats.frames}</dd>
              </div>
              <div>
                <dt className="flex items-center gap-1 text-xs text-dark-400"><Cpu className="h-3.5 w-3.5" />设备</dt>
                <dd className="mt-1 truncate text-lg">{device}</dd>
              </div>
            </dl>
          </section>

          <section className="p-4">
            <h2 className="mb-3 text-sm font-medium">当前检测结果</h2>
            {detections.length > 0 ? (
              <ul className="space-y-2">
                {detections.map((detection, index) => (
                  <li key={`${detection.class_name}-${index}`} className="flex items-center justify-between gap-3 rounded-md bg-dark-700 px-3 py-2 text-sm">
                    <span className="min-w-0 truncate">{detection.display_name || detection.class_name}</span>
                    <span className="shrink-0 text-accent-300">{(Number(detection.confidence || 0) * 100).toFixed(1)}%</span>
                  </li>
                ))}
              </ul>
            ) : (
              <p className="text-sm text-dark-400">当前帧未检测到交通标志</p>
            )}
          </section>
        </aside>
      </main>
    </div>
  )
}
