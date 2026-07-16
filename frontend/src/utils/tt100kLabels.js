const TT100K_LABELS_ZH = {
  i2: '非机动车行驶',
  i4: '机动车行驶',
  i5: '靠右侧道路行驶',
  il100: '最低限速 100 km/h',
  il60: '最低限速 60 km/h',
  il80: '最低限速 80 km/h',
  io: '其他指示标志',
  ip: '人行横道',
  p10: '禁止小型客车驶入',
  p11: '禁止鸣喇叭',
  p12: '禁止摩托车驶入',
  p19: '禁止向右转弯',
  p23: '禁止向左转弯',
  p26: '禁止载货汽车驶入',
  p27: '禁止运输危险物品车辆驶入',
  p3: '禁止大型客车驶入',
  p5: '禁止掉头',
  p6: '禁止非机动车进入',
  pg: '减速让行',
  ph4: '限制高度 4 m',
  'ph4.5': '限制高度 4.5 m',
  ph5: '限制高度 5 m',
  pl100: '最高限速 100 km/h',
  pl120: '最高限速 120 km/h',
  pl20: '最高限速 20 km/h',
  pl30: '最高限速 30 km/h',
  pl40: '最高限速 40 km/h',
  pl5: '最高限速 5 km/h',
  pl50: '最高限速 50 km/h',
  pl60: '最高限速 60 km/h',
  pl70: '最高限速 70 km/h',
  pl80: '最高限速 80 km/h',
  pm20: '限制质量 20 t',
  pm30: '限制质量 30 t',
  pm55: '限制质量 55 t',
  pn: '禁止停放车辆',
  pne: '禁止驶入',
  po: '其他禁令标志',
  pr40: '解除最高限速 40 km/h',
  w13: '十字交叉路口',
  w32: '道路施工',
  w55: '注意儿童',
  w57: '注意行人',
  w59: '右侧合流',
  wo: '其他警告标志',
}

const TT100K_ALIASES = {
  i160: 'il60',
  'pó': 'p6',
  pL80: 'pl80',
}

export function tt100kLabelZh(className) {
  if (typeof className !== 'string') return null
  const normalized = className.trim()
  const canonical = TT100K_ALIASES[normalized] || normalized
  return TT100K_LABELS_ZH[canonical] || null
}

export function getSignDisplayName(sign) {
  if (!sign) return 'unknown'
  return (
    sign.display_name ||
    sign.class_name_cn ||
    tt100kLabelZh(sign.class_name || sign.type) ||
    sign.class_name ||
    sign.type ||
    'unknown'
  )
}
