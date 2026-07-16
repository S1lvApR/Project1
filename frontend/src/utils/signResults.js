import { getSignDisplayName } from './tt100kLabels'

export function formatSignResult(data) {
  if (!data) return '识别完成'

  const images = data.results || []
  const totalImages = data.total_images ?? images.length
  const totalSigns = data.total_signs ?? images.reduce(
    (total, image) => total + (image.traffic_signs?.length || 0),
    0,
  )
  const totalLights = data.total_lights ?? images.reduce(
    (total, image) => total + (image.traffic_lights?.length || 0),
    0,
  )

  let result = `识别时间：${data.time || '未知'}\n\n`
  result += `任务 ID：${data.task_id || '未记录'}\n`
  result += `共识别 ${totalImages} 张图片`
  if (data.model?.device) result += `，设备 ${data.model.device}`
  if (data.recognition_mode) result += `Mode: ${data.recognition_mode}\n`
  result += '\n'

  if (totalSigns > 0) {
    result += `\n交通标志（共 ${totalSigns} 个）：\n`
    images.forEach((image, index) => {
      if (!image.traffic_signs?.length) return
      result += `\n图片 ${image.filename || index + 1}：\n`
      image.traffic_signs.forEach((sign) => {
        const label = getSignDisplayName(sign)
        result += `- ${label}：${sign.value || '无'}，置信度 ${sign.confidence ?? 0}%\n`
      })
    })
  }

  if (totalLights > 0) {
    result += `\n交通信号灯（共 ${totalLights} 个）：\n`
    images.forEach((image, index) => {
      if (!image.traffic_lights?.length) return
      result += `\n图片 ${image.filename || index + 1}：\n`
      image.traffic_lights.forEach((light) => {
        const statusText = { red: '红灯', green: '绿灯', yellow: '黄灯' }
        result += `- 信号灯：${statusText[light.status] || light.status}，置信度 ${light.confidence ?? 0}%\n`
      })
    })
  }

  if (totalSigns === 0 && totalLights === 0) {
    result += '\n未识别到交通标志和信号灯'
  }

  return result
}
