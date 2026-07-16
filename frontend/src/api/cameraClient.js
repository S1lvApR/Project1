import { getCameraWebSocketUrl } from './detection'


export class CameraDetectionClient {
  constructor({
    url = getCameraWebSocketUrl(),
    WebSocketImpl = globalThis.WebSocket,
    onMessage = () => {},
    onError = () => {},
    onOpen = () => {},
    onClose = () => {},
  } = {}) {
    this.url = url
    this.WebSocketImpl = WebSocketImpl
    this.onMessage = onMessage
    this.onError = onError
    this.onOpen = onOpen
    this.onClose = onClose
    this.socket = null
    this.configured = false
    this.awaitingResponse = false
    this.generation = 0
  }

  connect(config) {
    if (!this.WebSocketImpl) throw new Error('当前浏览器不支持 WebSocket')
    if (this.socket) this.close()
    const generation = ++this.generation
    const socket = new this.WebSocketImpl(this.url)
    this.socket = socket
    socket.onopen = () => {
      if (generation !== this.generation) return
      socket.send(JSON.stringify({ type: 'config', ...config }))
      this.onOpen()
    }
    socket.onmessage = (event) => {
      if (generation !== this.generation) return
      let message
      try {
        message = JSON.parse(event.data)
      } catch {
        this.awaitingResponse = false
        this.onError('摄像头服务返回了无效消息')
        return
      }
      if (message.type === 'config_ok') {
        this.configured = true
        this.awaitingResponse = false
      } else if (message.type === 'result') {
        this.awaitingResponse = false
      } else if (message.type === 'error') {
        this.awaitingResponse = false
        this.onError(message.message || '摄像头检测失败')
      }
      this.onMessage(message)
    }
    socket.onerror = () => {
      if (generation !== this.generation) return
      this.awaitingResponse = false
      this.onError('摄像头 WebSocket 连接失败')
    }
    socket.onclose = (event) => {
      if (generation !== this.generation) return
      this.configured = false
      this.awaitingResponse = false
      this.onClose(event)
    }
    return socket
  }

  sendFrame(data) {
    const openState = this.WebSocketImpl?.OPEN ?? 1
    if (
      !this.socket ||
      this.socket.readyState !== openState ||
      !this.configured ||
      this.awaitingResponse
    ) {
      return false
    }
    this.awaitingResponse = true
    this.socket.send(JSON.stringify({ type: 'frame', data }))
    return true
  }

  close() {
    if (!this.socket) return
    const socket = this.socket
    this.socket = null
    this.generation += 1
    const openState = this.WebSocketImpl?.OPEN ?? 1
    const connectingState = this.WebSocketImpl?.CONNECTING ?? 0
    if (socket.readyState === openState) {
      socket.send(JSON.stringify({ type: 'close' }))
      socket.close(1000)
    } else if (socket.readyState === connectingState) {
      socket.close(1000)
    }
    this.configured = false
    this.awaitingResponse = false
  }
}
