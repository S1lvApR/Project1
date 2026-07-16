const VIDEO_ENDPOINT = '/api/detection/video'


function authHeaders() {
  const token = localStorage.getItem('token')
  return token ? { Authorization: `Bearer ${token}` } : {}
}


async function readResponse(response) {
  const payload = await response.json()
  if (!response.ok) {
    throw new Error(payload.detail || payload.message || '请求失败')
  }
  return payload.data
}


export async function uploadVideo(file, options = {}) {
  const formData = new FormData()
  formData.append('video', file)
  const fields = {
    confidence: options.confidence,
    iou: options.iou,
    image_size: options.imageSize,
    sample_rate: options.sampleRate,
    max_frames: options.maxFrames,
  }
  Object.entries(fields).forEach(([key, value]) => {
    if (value !== undefined && value !== null) {
      formData.append(key, String(value))
    }
  })
  const response = await fetch(VIDEO_ENDPOINT, {
    method: 'POST',
    headers: authHeaders(),
    body: formData,
  })
  return readResponse(response)
}


export async function getVideoStatus(taskId, { signal } = {}) {
  const response = await fetch(`${VIDEO_ENDPOINT}/status/${taskId}`, {
    headers: authHeaders(),
    signal,
  })
  return readResponse(response)
}


const defaultSleep = (milliseconds) => new Promise(
  (resolve) => setTimeout(resolve, milliseconds),
)


export async function pollVideoStatus(taskId, options = {}) {
  const {
    interval = 1000,
    timeout = 10 * 60 * 1000,
    onProgress,
    signal,
    sleep = defaultSleep,
  } = options
  const startedAt = Date.now()
  while (Date.now() - startedAt <= timeout) {
    if (signal?.aborted) throw new DOMException('Aborted', 'AbortError')
    const status = await getVideoStatus(taskId, { signal })
    onProgress?.(status)
    if (status.status === 'completed' || status.status === 'failed') {
      return status
    }
    await sleep(interval)
  }
  throw new Error('视频检测超时，请稍后查看任务记录')
}


export function getCameraWebSocketUrl(token = localStorage.getItem('token')) {
  const url = new URL('/api/detection/camera', window.location.href)
  url.protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
  if (token) url.searchParams.set('token', token)
  return url.toString()
}
