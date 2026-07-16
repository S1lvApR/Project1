import { describe, expect, it, vi } from 'vitest'

import { CameraDetectionClient } from '@/api/cameraClient'


class FakeWebSocket {
  constructor(url) {
    this.url = url
    this.readyState = FakeWebSocket.OPEN
    this.sent = []
  }

  send(message) {
    this.sent.push(JSON.parse(message))
  }

  close() {
    this.readyState = 3
    this.onclose?.({ code: 1000 })
  }

  emitOpen() {
    this.onopen?.()
  }

  emitMessage(message) {
    this.onmessage?.({ data: JSON.stringify(message) })
  }
}

FakeWebSocket.OPEN = 1


describe('CameraDetectionClient', () => {
  it('uses response-driven backpressure for camera frames', () => {
    const messages = []
    const client = new CameraDetectionClient({
      url: 'ws://localhost/api/detection/camera?token=x',
      WebSocketImpl: FakeWebSocket,
      onMessage: (message) => messages.push(message),
    })
    const socket = client.connect({ mode: 'gpu', conf: 0.3, iou: 0.45 })
    socket.emitOpen()

    expect(socket.sent[0]).toEqual({
      type: 'config',
      mode: 'gpu',
      conf: 0.3,
      iou: 0.45,
    })
    socket.emitMessage({ type: 'config_ok', device: '0' })
    expect(client.sendFrame('frame-1')).toBe(true)
    expect(client.sendFrame('frame-2')).toBe(false)
    expect(socket.sent.at(-1)).toEqual({ type: 'frame', data: 'frame-1' })

    socket.emitMessage({ type: 'result', frame_count: 1 })
    expect(client.sendFrame('frame-2')).toBe(true)
    expect(messages.at(-1).frame_count).toBe(1)
  })

  it('reports protocol errors and closes cleanly', () => {
    const onError = vi.fn()
    const client = new CameraDetectionClient({
      url: 'ws://localhost/camera',
      WebSocketImpl: FakeWebSocket,
      onError,
    })
    const socket = client.connect({ mode: 'cpu' })
    socket.emitOpen()
    socket.emitMessage({ type: 'config_ok' })
    client.sendFrame('frame')
    socket.emitMessage({ type: 'error', message: 'bad frame' })

    expect(onError).toHaveBeenCalledWith('bad frame')
    expect(client.awaitingResponse).toBe(false)
    client.close()
    expect(socket.readyState).toBe(3)
  })

  it('cancels a connecting socket and ignores its late callbacks', () => {
    const onOpen = vi.fn()
    const client = new CameraDetectionClient({
      url: 'ws://localhost/camera',
      WebSocketImpl: FakeWebSocket,
      onOpen,
    })
    const socket = client.connect({ mode: 'auto' })
    socket.readyState = 0

    client.close()
    socket.emitOpen()

    expect(socket.readyState).toBe(3)
    expect(onOpen).not.toHaveBeenCalled()
    expect(socket.sent).toEqual([])
  })
})
