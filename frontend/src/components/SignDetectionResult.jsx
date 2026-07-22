import { AlertCircle, CheckCircle2, ImageOff } from 'lucide-react'
import { getSignDisplayName } from '../utils/tt100kLabels'

export function SignDetectionResult({ data }) {
  const results = data?.results || []

  return (
    <div className="w-full max-w-3xl space-y-4 rounded-2xl bg-dark-800 p-4 text-white">
      <div className="flex items-center justify-between gap-4 border-b border-dark-600 pb-3">
        <div>
          <p className="font-medium">交通标志识别结果</p>
          <p className="mt-1 text-xs text-dark-400">
            任务 ID：{data?.task_id || '未记录'}
          </p>
        </div>
        {data?.recognition_mode && (
          <span className="rounded-md bg-dark-700 px-2 py-1 text-xs text-dark-300">
            Mode: {data.recognition_mode}
          </span>
        )}
        {data?.model?.device && (
          <span className="rounded-md bg-dark-700 px-2 py-1 text-xs text-accent-400">
            设备 {data.model.device}
          </span>
        )}
      </div>

      <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
        {results.map((result, index) => {
          const signs = result.traffic_signs || []
          const failed = result.success === false
          return (
            <figure key={`${result.filename || 'image'}-${index}`} className="overflow-hidden rounded-xl border border-dark-600 bg-dark-700">
              {result.annotated_image_url ? (
                <img
                  src={result.annotated_image_url}
                  alt={result.filename || `识别图片 ${index + 1}`}
                  className="aspect-video w-full object-contain bg-black"
                />
              ) : (
                <div className="flex aspect-video items-center justify-center bg-dark-900 text-dark-500">
                  <ImageOff className="h-8 w-8" aria-label="无标注图" />
                </div>
              )}
              <figcaption className="space-y-3 p-3">
                <div className="flex items-center justify-between gap-2">
                  <span className="truncate text-sm font-medium">{result.filename || `图片 ${index + 1}`}</span>
                  {failed ? (
                    <AlertCircle className="h-4 w-4 shrink-0 text-red-400" aria-label="识别失败" />
                  ) : (
                    <CheckCircle2 className="h-4 w-4 shrink-0 text-green-400" aria-label="识别完成" />
                  )}
                </div>
                {failed ? (
                  <p className="text-sm text-red-300">{result.error || '识别失败'}</p>
                ) : signs.length > 0 ? (
                  <ul className="space-y-2">
                    {signs.map((sign, signIndex) => (
                      <li key={`${sign.type || sign.class_name}-${signIndex}`} className="flex items-center justify-between gap-3 rounded-md bg-dark-800 px-3 py-2 text-sm">
                        <span>{getSignDisplayName(sign)}</span>
                        <span className="text-accent-300">{sign.confidence ?? 0}%</span>
                      </li>
                    ))}
                  </ul>
                ) : (
                  <p className="text-sm text-dark-400">未识别到交通标志</p>
                )}
              </figcaption>
            </figure>
          )
        })}
      </div>
    </div>
  )
}
