import { beforeEach, describe, expect, it, vi } from 'vitest'

const { uploadVideoMock, pollVideoStatusMock } = vi.hoisted(() => ({
  uploadVideoMock: vi.fn(),
  pollVideoStatusMock: vi.fn(),
}))

vi.mock('@/api/detection', () => ({
  uploadVideo: uploadVideoMock,
  pollVideoStatus: pollVideoStatusMock,
}))

import { useStore } from '@/store/useStore'

const originalSaveMessage = useStore.getState().saveMessage

describe('video detection store flow', () => {
  beforeEach(() => {
    localStorage.clear()
    uploadVideoMock.mockReset()
    pollVideoStatusMock.mockReset()
    useStore.setState({
      conversations: [
        {
          id: 'local-1',
          title: 'New Conversation',
          messages: [],
          createdAt: new Date(),
          persisted: false,
        },
      ],
      activeConversationId: 'local-1',
      error: null,
      saveMessage: originalSaveMessage,
    })
  })

  it('updates one result message from upload through completion', async () => {
    uploadVideoMock.mockResolvedValue({ task_id: 33, status: 'pending', progress: 0 })
    pollVideoStatusMock.mockImplementation(async (_taskId, options) => {
      options.onProgress({
        task_id: 33,
        filename: 'road.mp4',
        status: 'processing',
        progress: 45,
        key_frames: [],
      })
      return {
        task_id: 33,
        filename: 'road.mp4',
        status: 'completed',
        progress: 100,
        total_objects: 1,
        key_frames: [{ frame_index: 0, traffic_signs: [] }],
      }
    })
    const file = new File(['video'], 'road.mp4', { type: 'video/mp4' })

    const result = await useStore.getState().detectVideo('local-1', file)

    const conversation = useStore.getState().conversations[0]
    expect(result.status).toBe('completed')
    expect(conversation.title).toBe('视频交通标志检测')
    expect(conversation.messages).toHaveLength(2)
    expect(conversation.messages[0].content).toContain('road.mp4')
    expect(conversation.messages[1].type).toBe('video_result')
    expect(conversation.messages[1].resultData.status).toBe('completed')
    expect(conversation.messages[1].resultData.total_objects).toBe(1)
    expect(pollVideoStatusMock).toHaveBeenCalledWith(
      33,
      expect.objectContaining({ onProgress: expect.any(Function) }),
    )
  })

  it('persists a failed terminal task as failure instead of completion', async () => {
    const saveMessage = vi.fn()
    useStore.setState({ saveMessage })
    uploadVideoMock.mockResolvedValue({ task_id: 34, status: 'pending', progress: 0 })
    pollVideoStatusMock.mockResolvedValue({
      task_id: 34,
      filename: 'broken.mp4',
      status: 'failed',
      progress: 100,
      error: '视频元数据无效，无法开始检测',
      key_frames: [],
    })
    const file = new File(['video'], 'broken.mp4', { type: 'video/mp4' })

    const result = await useStore.getState().detectVideo('local-1', file)

    expect(result.status).toBe('failed')
    expect(saveMessage).toHaveBeenLastCalledWith(
      'local-1',
      'assistant',
      expect.stringContaining('视频检测失败'),
    )
    expect(saveMessage.mock.calls.at(-1)[2]).not.toContain('视频检测完成')
  })
})
