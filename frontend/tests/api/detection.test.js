import { beforeEach, describe, expect, it, vi } from 'vitest'

import {
  getCameraWebSocketUrl,
  pollVideoStatus,
  uploadVideo,
} from '@/api/detection'


describe('detection API', () => {
  beforeEach(() => {
    localStorage.clear()
    vi.restoreAllMocks()
  })

  it('uploads a video with auth and inference options', async () => {
    localStorage.setItem('token', 'jwt-token')
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue({
      ok: true,
      json: async () => ({
        success: true,
        data: { task_id: 12, status: 'pending', progress: 0 },
      }),
    })
    const file = new File(['video'], 'road.mp4', { type: 'video/mp4' })

    const result = await uploadVideo(file, {
      confidence: 0.3,
      iou: 0.5,
      imageSize: 640,
      sampleRate: 2,
      maxFrames: 20,
    })

    expect(result.task_id).toBe(12)
    const [url, options] = fetchMock.mock.calls[0]
    expect(url).toBe('/api/detection/video')
    expect(options.headers.Authorization).toBe('Bearer jwt-token')
    expect(options.body).toBeInstanceOf(FormData)
    expect(options.body.get('video')).toBe(file)
    expect(options.body.get('sample_rate')).toBe('2')
    expect(options.body.get('max_frames')).toBe('20')
  })

  it('polls progress until the task reaches a terminal state', async () => {
    const responses = [
      { status: 'processing', progress: 35 },
      { status: 'completed', progress: 100, key_frames: [] },
    ]
    vi.spyOn(globalThis, 'fetch').mockImplementation(async () => ({
      ok: true,
      json: async () => ({ success: true, data: responses.shift() }),
    }))
    const updates = []

    const result = await pollVideoStatus(7, {
      interval: 0,
      timeout: 1000,
      onProgress: (status) => updates.push(status.progress),
      sleep: async () => {},
    })

    expect(updates).toEqual([35, 100])
    expect(result.status).toBe('completed')
  })

  it('builds an authenticated WebSocket URL', () => {
    localStorage.setItem('token', 'camera token')

    const url = getCameraWebSocketUrl()

    expect(new URL(url).searchParams.get('token')).toBe('camera token')
    expect(url).toContain('/api/detection/camera?token=')
    expect(url.startsWith('ws://') || url.startsWith('wss://')).toBe(true)
  })
})
