import { Play, Clock, Activity, Layers, Target, Eye } from 'lucide-react';

export function VideoResultCard({ results }) {
  if (!results) return null;

  const {
    total_frames,
    processed_frames,
    frame_interval,
    fps,
    duration_seconds,
    video_resolution,
    total_signs,
    total_lights,
    key_frames,
    annotated_video_url,
  } = results;

  const hasVideo = annotated_video_url;
  const hasKeyFrames = key_frames && key_frames.length > 0;

  const formatDuration = (seconds) => {
    const mins = Math.floor(seconds / 60);
    const secs = Math.floor(seconds % 60);
    return `${mins}:${secs.toString().padStart(2, '0')}`;
  };

  return (
    <div className="mt-3 bg-dark-700 rounded-xl border border-dark-600 overflow-hidden">
      <div className="bg-dark-800 px-4 py-3 border-b border-dark-600">
        <div className="flex items-center gap-2">
          <Play className="w-4 h-4 text-accent-500" />
          <span className="text-white font-medium text-sm">视频检测结果</span>
        </div>
      </div>

      <div className="p-4">
        <div className="grid grid-cols-2 md:grid-cols-4 gap-3 mb-4">
          <div className="bg-dark-800 rounded-lg p-3">
            <div className="flex items-center gap-2 mb-1">
              <Clock className="w-4 h-4 text-accent-500" />
              <span className="text-dark-400 text-xs">时长</span>
            </div>
            <span className="text-white font-medium">{formatDuration(duration_seconds || 0)}</span>
          </div>
          <div className="bg-dark-800 rounded-lg p-3">
            <div className="flex items-center gap-2 mb-1">
              <Activity className="w-4 h-4 text-accent-500" />
              <span className="text-dark-400 text-xs">FPS</span>
            </div>
            <span className="text-white font-medium">{fps || 30}</span>
          </div>
          <div className="bg-dark-800 rounded-lg p-3">
            <div className="flex items-center gap-2 mb-1">
              <Layers className="w-4 h-4 text-accent-500" />
              <span className="text-dark-400 text-xs">采样帧</span>
            </div>
            <span className="text-white font-medium">{processed_frames || 0} / {total_frames || '?'}</span>
          </div>
          <div className="bg-dark-800 rounded-lg p-3">
            <div className="flex items-center gap-2 mb-1">
              <Target className="w-4 h-4 text-accent-500" />
              <span className="text-dark-400 text-xs">检测目标</span>
            </div>
            <span className="text-white font-medium">
              🚦{total_signs || 0} 🔴{total_lights || 0}
            </span>
          </div>
        </div>

        <div className="flex items-center gap-2 text-xs text-dark-400 mb-4">
          <span>分辨率: {video_resolution?.width || '?'}×{video_resolution?.height || '?'}</span>
          <span className="text-dark-500">|</span>
          <span>帧间隔: {frame_interval}帧</span>
        </div>

        {hasVideo ? (
          <div className="relative rounded-lg overflow-hidden bg-dark-900">
            <video
              src={annotated_video_url}
              controls
              className="w-full"
              style={{ maxHeight: '400px' }}
            />
            <div className="absolute bottom-2 right-2 bg-black/60 text-white text-xs px-2 py-1 rounded">
              标注视频
            </div>
          </div>
        ) : hasKeyFrames ? (
          <div>
            <div className="flex items-center gap-2 mb-3">
              <Eye className="w-4 h-4 text-accent-500" />
              <span className="text-dark-400 text-sm">关键帧缩略图</span>
            </div>
            <div className="grid grid-cols-2 md:grid-cols-3 gap-2">
              {key_frames.slice(0, 6).map((frame, idx) => (
                <div
                  key={idx}
                  className="relative group rounded-lg overflow-hidden bg-dark-800"
                >
                  {frame.annotated_image_base64 ? (
                    <img
                      src={`data:image/jpeg;base64,${frame.annotated_image_base64}`}
                      alt={`关键帧 ${idx + 1}`}
                      className="w-full h-24 object-cover"
                    />
                  ) : (
                    <div className="w-full h-24 flex items-center justify-center text-dark-500">
                      <span className="text-xs">无缩略图</span>
                    </div>
                  )}
                  <div className="absolute bottom-0 left-0 right-0 bg-black/70 text-white text-xs px-2 py-1">
                    <div className="flex justify-between">
                      <span>帧 {frame.frame_index}</span>
                      <span>{frame.timestamp}秒</span>
                    </div>
                    <div className="flex justify-between mt-1">
                      <span className="text-accent-500">🚦{frame.sign_count || 0}</span>
                      <span className="text-red-400">🔴{frame.light_count || 0}</span>
                    </div>
                  </div>
                </div>
              ))}
            </div>
          </div>
        ) : (
          <div className="text-center py-8 text-dark-400">
            <Eye className="w-8 h-8 mx-auto mb-2 opacity-50" />
            <span className="text-sm">无可用的标注视频或关键帧</span>
          </div>
        )}
      </div>
    </div>
  );
}
