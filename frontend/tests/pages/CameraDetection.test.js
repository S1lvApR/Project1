import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { MemoryRouter } from 'react-router-dom'
import { describe, expect, it } from 'vitest'

import CameraDetection from '@/pages/CameraDetection.jsx'


describe('CameraDetection page', () => {
  it('renders camera mode, confidence, transport, and statistics controls', () => {
    const html = renderToStaticMarkup(
      createElement(
        MemoryRouter,
        null,
        createElement(CameraDetection),
      ),
    )

    expect(html).toContain('摄像头实时检测')
    expect(html).toContain('自动')
    expect(html).toContain('GPU')
    expect(html).toContain('CPU')
    expect(html).toContain('置信度')
    expect(html).toContain('开始检测')
    expect(html).toContain('实时统计')
    expect(html).toContain('当前检测结果')
  })
})
