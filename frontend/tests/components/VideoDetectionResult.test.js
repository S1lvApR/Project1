import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'

import { VideoDetectionResult } from '@/components/VideoDetectionResult.jsx'


describe('VideoDetectionResult', () => {
  it('renders live processing progress', () => {
    const html = renderToStaticMarkup(
      createElement(VideoDetectionResult, {
        data: {
          task_id: 19,
          filename: 'road.mp4',
          status: 'processing',
          progress: 42,
          processed_frames: 21,
          sampled_frames: 4,
          key_frames: [],
        },
      }),
    )

    expect(html).toContain('road.mp4')
    expect(html).toContain('42%')
    expect(html).toContain('处理中')
    expect(html).toContain('21')
  })

  it('renders video metadata and Chinese key-frame detections', () => {
    const html = renderToStaticMarkup(
      createElement(VideoDetectionResult, {
        data: {
          task_id: 20,
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
              annotated_image_url: '/uploads/detections/20/frame.jpg',
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

    expect(html).toContain('检测完成')
    expect(html).toContain('1280 × 720')
    expect(html).toContain('/uploads/detections/20/frame.jpg')
    expect(html).toContain('最高限速 60 km/h')
    expect(html).toContain('92%')
  })
})
