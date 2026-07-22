import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'

import { VideoDetectionResult } from '@/components/VideoDetectionResult.jsx'


describe('VideoDetectionResult', () => {
  it('renders a cache-busted live preview while detecting', () => {
    const html = renderToStaticMarkup(
      createElement(VideoDetectionResult, {
        data: {
          task_id: 19,
          filename: 'road.mp4',
          status: 'processing',
          stage: 'detecting',
          progress: 42,
          processed_frames: 211,
          inference_frames: 211,
          preview_frame_url: '/uploads/detections/19/preview.jpg',
          preview_version: 210,
          key_frames: [],
        },
      }),
    )

    expect(html).toContain('road.mp4')
    expect(html).toContain('42%')
    expect(html).toContain('处理中')
    expect(html).toContain('实时检测画面')
    expect(html).toContain('/uploads/detections/19/preview.jpg?v=210')
    expect(html).toContain('211')
  })

  it('renders finalization without showing a completed player', () => {
    const html = renderToStaticMarkup(
      createElement(VideoDetectionResult, {
        data: {
          task_id: 19,
          filename: 'road.mp4',
          status: 'processing',
          stage: 'finalizing',
          progress: 96,
          key_frames: [],
        },
      }),
    )

    expect(html).toContain('正在生成可播放视频')
    expect(html).not.toContain('<video')
  })

  it('renders completed video playback and download', () => {
    const videoUrl = '/uploads/detections/20/road_annotated.mp4'
    const html = renderToStaticMarkup(
      createElement(VideoDetectionResult, {
        data: {
          task_id: 20,
          filename: 'road.mp4',
          status: 'completed',
          stage: 'completed',
          progress: 100,
          annotated_video_url: videoUrl,
          download_url: videoUrl,
          key_frames: [],
        },
      }),
    )

    expect(html).toContain('检测完成')
    expect(html).toContain('<video')
    expect(html).toContain('controls=""')
    expect(html).toContain(videoUrl)
    expect(html).toContain('下载带框视频')
    expect(html).toContain('download=""')
  })

  it('keeps rendering metadata and Chinese key frames for legacy tasks', () => {
    const html = renderToStaticMarkup(
      createElement(VideoDetectionResult, {
        data: {
          task_id: 21,
          filename: 'street.mp4',
          status: 'completed',
          progress: 100,
          total_objects: 1,
          average_inference_time: 12.5,
          device: '0',
          metadata: {
            total_frames: 100,
            fps: 25,
            duration: 4,
            width: 1280,
            height: 720,
          },
          key_frames: [
            {
              frame_index: 10,
              timestamp: 0.4,
              annotated_image_url: '/uploads/detections/21/frame.jpg',
              traffic_signs: [
                {
                  class_name: 'pl60',
                  display_name: '最高限速 60 km/h',
                  confidence: 92,
                },
              ],
            },
          ],
        },
      }),
    )

    expect(html).not.toContain('<video')
    expect(html).toContain('1280 × 720')
    expect(html).toContain('/uploads/detections/21/frame.jpg')
    expect(html).toContain('最高限速 60 km/h')
    expect(html).toContain('92%')
  })
})
