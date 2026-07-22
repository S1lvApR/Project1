import {
  CheckCircle2,
  CircleGauge,
  Clock3,
  Download,
  Film,
  Loader2,
  MonitorCog,
  ScanLine,
  XCircle,
} from 'lucide-react'

import { getSignDisplayName } from '../utils/tt100kLabels'


const STATUS = {
  pending: { label: '等待处理', icon: Clock3, color: 'text-dark-300' },
  processing: { label: '处理中', icon: Loader2, color: 'text-accent-300' },
  completed: { label: '检测完成', icon: CheckCircle2, color: 'text-green-400' },
  failed: { label: '检测失败', icon: XCircle, color: 'text-red-400' },
}

function confidenceText(value) {
  const number = Number(value) || 0
  const percentage = number <= 1 ? number * 100 : number
  return `${percentage.toFixed(percentage % 1 === 0 ? 0 : 1)}%`
}


function timestampText(seconds) {
  const value = Number(seconds) || 0
  const minutes = Math.floor(value / 60)
  return `${minutes}:${(value % 60).toFixed(1).padStart(4, '0')}`
}


function versionedPreviewUrl(url, version) {
  if (!url) return null
  const separator = url.includes('?') ? '&' : '?'
  return `${url}${separator}v=${encodeURIComponent(version || 0)}`
}


export function VideoDetectionResult({ data }) {
  const status = STATUS[data?.status] || STATUS.pending
  const StatusIcon = status.icon
  const progress = Math.max(0, Math.min(100, Number(data?.progress) || 0))
  const metadata = data?.metadata || {}
  const keyFrames = data?.key_frames || []
  const inferenceFrames = data?.inference_frames ?? data?.sampled_frames ?? 0
  const isWorking = data?.status === 'pending' || data?.status === 'processing'
  const isFinalizing = data?.status === 'processing' && data?.stage === 'finalizing'
  const previewUrl = versionedPreviewUrl(
    data?.preview_frame_url,
    data?.preview_version,
  )
  const videoUrl = data?.status === 'completed'
    ? data?.annotated_video_url
    : null
  const downloadUrl = data?.download_url || videoUrl
  const classCounts = keyFrames.reduce((counts, frame) => {
    ;(frame.traffic_signs || []).forEach((sign) => {
      const label = getSignDisplayName(sign)
      counts[label] = (counts[label] || 0) + 1
    })
    return counts
  }, {})

  return (
    <section className="w-full max-w-3xl space-y-4 rounded-lg bg-dark-800 p-4 text-white">
      <header className="flex flex-wrap items-center justify-between gap-3 border-b border-dark-600 pb-3">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <Film className="h-4 w-4 shrink-0 text-accent-400" />
            <h3 className="truncate text-sm font-medium">
              {data?.filename || '视频检测'}
            </h3>
          </div>
          <p className="mt-1 text-xs text-dark-400">
            任务 ID：{data?.task_id || '创建中'}
          </p>
        </div>
        <span className={`flex items-center gap-2 text-sm ${status.color}`}>
          <StatusIcon
            className={`h-4 w-4 ${data?.status === 'processing' ? 'animate-spin' : ''}`}
          />
          {status.label}
        </span>
      </header>

      {isWorking && (
        <div className="space-y-2">
          <div className="flex items-center justify-between gap-3 text-xs text-dark-300">
            <span className="min-w-0">
              已读取 {data?.processed_frames || 0} 帧，已推理 {inferenceFrames} 帧
            </span>
            <span className="shrink-0">{progress}%</span>
          </div>
          <div className="h-2 overflow-hidden rounded bg-dark-600">
            <div
              className="h-full bg-accent-500 transition-[width] duration-300"
              style={{ width: `${progress}%` }}
            />
          </div>
        </div>
      )}

      {data?.error && (
        <p className="rounded-md border border-red-500/30 bg-red-500/10 px-3 py-2 text-sm text-red-300">
          {data.error}
        </p>
      )}

      {(isWorking || videoUrl) && (
        <div className="space-y-2">
          <div className="flex items-center justify-between gap-3 text-xs text-dark-300">
            <span className="flex items-center gap-2">
              {isFinalizing ? (
                <Loader2 className="h-4 w-4 animate-spin text-accent-400" />
              ) : (
                <ScanLine className="h-4 w-4 text-accent-400" />
              )}
              {isFinalizing
                ? '正在生成可播放视频'
                : videoUrl
                  ? '带框检测视频'
                  : '实时检测画面'}
            </span>
            {videoUrl && downloadUrl && (
              <a
                href={downloadUrl}
                download
                className="flex shrink-0 items-center gap-1.5 text-accent-300 hover:text-accent-200"
              >
                <Download className="h-4 w-4" />
                下载带框视频
              </a>
            )}
          </div>
          <div className="aspect-video w-full overflow-hidden rounded-md border border-dark-600 bg-black">
            {videoUrl ? (
              <video
                className="h-full w-full object-contain"
                src={videoUrl}
                controls
                playsInline
                preload="metadata"
              />
            ) : previewUrl ? (
              <img
                src={previewUrl}
                alt="视频实时检测画面"
                className="h-full w-full object-contain"
              />
            ) : (
              <div className="flex h-full w-full items-center justify-center text-dark-400">
                <MonitorCog className="h-6 w-6" />
              </div>
            )}
          </div>
        </div>
      )}

      {(data?.status === 'completed' || keyFrames.length > 0) && (
        <>
          <div className="grid grid-cols-2 gap-x-4 gap-y-3 border-b border-dark-600 pb-4 text-sm md:grid-cols-4">
            <div>
              <p className="text-xs text-dark-400">分辨率</p>
              <p className="mt-1">{metadata.width || 0} × {metadata.height || 0}</p>
            </div>
            <div>
              <p className="text-xs text-dark-400">时长 / 帧率</p>
              <p className="mt-1">
                {Number(metadata.duration || 0).toFixed(1)} s / {metadata.fps || 0} FPS
              </p>
            </div>
            <div>
              <p className="text-xs text-dark-400">目标 / 关键帧</p>
              <p className="mt-1">{data?.total_objects || 0} / {keyFrames.length}</p>
            </div>
            <div>
              <p className="text-xs text-dark-400">设备 / 平均推理</p>
              <p className="mt-1">
                {data?.device || '-'} / {Number(data?.average_inference_time || 0).toFixed(1)} ms
              </p>
            </div>
          </div>

          {Object.keys(classCounts).length > 0 && (
            <div className="flex flex-wrap items-center gap-2 text-xs">
              <CircleGauge className="h-4 w-4 text-dark-400" />
              {Object.entries(classCounts).map(([label, count]) => (
                <span key={label} className="rounded bg-dark-700 px-2 py-1 text-dark-200">
                  {label} × {count}
                </span>
              ))}
            </div>
          )}

          {keyFrames.length > 0 && (
            <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
              {keyFrames.map((frame) => (
                <figure
                  key={frame.frame_index}
                  className="overflow-hidden rounded-md border border-dark-600 bg-dark-700"
                >
                  <img
                    src={frame.annotated_image_url}
                    alt={`视频第 ${frame.frame_index} 帧`}
                    className="aspect-video w-full bg-black object-contain"
                  />
                  <figcaption className="space-y-2 p-3">
                    <div className="flex items-center justify-between gap-2 text-xs text-dark-300">
                      <span>第 {frame.frame_index} 帧</span>
                      <span>{timestampText(frame.timestamp)}</span>
                    </div>
                    <ul className="space-y-1 text-sm">
                      {(frame.traffic_signs || []).map((sign, index) => (
                        <li
                          key={`${sign.class_name || sign.type}-${index}`}
                          className="flex items-center justify-between gap-3"
                        >
                          <span className="truncate">{getSignDisplayName(sign)}</span>
                          <span className="shrink-0 text-accent-300">
                            {confidenceText(sign.confidence)}
                          </span>
                        </li>
                      ))}
                    </ul>
                  </figcaption>
                </figure>
              ))}
            </div>
          )}
        </>
      )}

      {data?.status === 'completed' && !videoUrl && keyFrames.length === 0 && (
        <div className="flex items-center gap-2 text-sm text-dark-400">
          <MonitorCog className="h-4 w-4" />
          视频处理完成，未检测到交通标志
        </div>
      )}
    </section>
  )
}
