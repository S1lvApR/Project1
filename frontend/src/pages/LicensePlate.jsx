import { useState, useRef } from 'react'
import { Upload, FolderOpen, Image, Trash2, CheckCircle, AlertCircle, Loader2 } from 'lucide-react'

export default function LicensePlate() {
  const [images, setImages] = useState([])
  const [isRecognizing, setIsRecognizing] = useState(false)
  const [results, setResults] = useState([])
  const [totalPlates, setTotalPlates] = useState(0)
  const [error, setError] = useState('')
  const fileInputRef = useRef(null)
  const folderInputRef = useRef(null)

  const handleFileSelect = (e) => {
    const files = Array.from(e.target.files)
    if (files.length === 0) return

    const validFiles = files.filter(file => 
      file.type.startsWith('image/')
    )

    if (validFiles.length !== files.length) {
      setError('部分文件不是图片格式，已自动过滤')
      setTimeout(() => setError(''), 3000)
    }

    const newImages = validFiles.map((file, index) => ({
      id: Date.now() + index,
      file,
      url: URL.createObjectURL(file),
      name: file.name,
      size: (file.size / 1024).toFixed(1) + ' KB'
    }))

    setImages(prev => [...prev, ...newImages])
    e.target.value = ''
  }

  const handleFolderSelect = (e) => {
    const files = Array.from(e.target.files)
    if (files.length === 0) return

    const validFiles = files.filter(file => 
      file.type.startsWith('image/')
    )

    const newImages = validFiles.map((file, index) => ({
      id: Date.now() + index,
      file,
      url: URL.createObjectURL(file),
      name: file.name,
      size: (file.size / 1024).toFixed(1) + ' KB'
    }))

    setImages(prev => [...prev, ...newImages])
    e.target.value = ''
  }

  const removeImage = (id) => {
    const image = images.find(img => img.id === id)
    if (image) {
      URL.revokeObjectURL(image.url)
    }
    setImages(prev => prev.filter(img => img.id !== id))
    setResults(prev => prev.filter(r => r.imageId !== id))
  }

  const clearAll = () => {
    images.forEach(img => URL.revokeObjectURL(img.url))
    setImages([])
    setResults([])
    setTotalPlates(0)
  }

  const handleRecognize = async () => {
    if (images.length === 0) {
      setError('请先选择图片')
      setTimeout(() => setError(''), 3000)
      return
    }

    setIsRecognizing(true)
    setError('')
    setResults([])
    setTotalPlates(0)

    try {
      const formData = new FormData()
      images.forEach(img => {
        formData.append('images', img.file)
      })

      const token = localStorage.getItem('token')
      const headers = {}
      if (token) {
        headers['Authorization'] = `Bearer ${token}`
      }

      const response = await fetch('/api/license-plate/batch', {
        method: 'POST',
        headers,
        body: formData
      })

      const data = await response.json()

      if (!data.success) {
        setError(data.message || '识别失败')
        return
      }

      const newResults = data.data.results.map((result, index) => ({
        imageId: images[index]?.id,
        imageName: images[index]?.name,
        imageUrl: images[index]?.url,
        success: result.success,
        error: result.error,
        plates: result.plates
      }))

      setResults(newResults)
      setTotalPlates(data.data.total_plates)
    } catch (err) {
      setError('网络请求失败，请稍后重试')
    } finally {
      setIsRecognizing(false)
    }
  }

  const handleSingleRecognize = async (imageId) => {
    const image = images.find(img => img.id === imageId)
    if (!image) return

    setIsRecognizing(true)
    setError('')

    try {
      const formData = new FormData()
      formData.append('image', image.file)

      const token = localStorage.getItem('token')
      const headers = {}
      if (token) {
        headers['Authorization'] = `Bearer ${token}`
      }

      const response = await fetch('/api/license-plate/recognize', {
        method: 'POST',
        headers,
        body: formData
      })

      const data = await response.json()

      if (!data.success) {
        setError(data.message || '识别失败')
        return
      }

      setResults(prev => {
        const existingIndex = prev.findIndex(r => r.imageId === imageId)
        const newResult = {
          imageId: image.id,
          imageName: image.name,
          imageUrl: image.url,
          success: true,
          error: null,
          plates: data.data.plates
        }
        
        if (existingIndex >= 0) {
          const updated = [...prev]
          updated[existingIndex] = newResult
          return updated
        }
        return [...prev, newResult]
      })

      setTotalPlates(prev => prev + data.data.plate_count)
    } catch (err) {
      setError('网络请求失败')
    } finally {
      setIsRecognizing(false)
    }
  }

  return (
    <div className="min-h-screen bg-dark-900 p-8">
      <div className="max-w-6xl mx-auto">
        <div className="mb-8">
          <h1 className="text-3xl font-bold text-white mb-2">车牌识别</h1>
          <p className="text-dark-400">上传图片或选择文件夹，识别图片中的车牌号码</p>
        </div>

        {error && (
          <div className="mb-6 p-4 rounded-xl bg-red-500/10 border border-red-500/30 text-red-400">
            {error}
          </div>
        )}

        <div className="bg-dark-800 rounded-2xl border border-dark-600 p-8 mb-8">
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            <button
              onClick={() => fileInputRef.current?.click()}
              className="flex flex-col items-center justify-center p-8 rounded-xl border-2 border-dashed border-dark-500 hover:border-accent-500 hover:bg-dark-700 transition-all group"
            >
              <div className="w-16 h-16 rounded-full bg-accent-500/10 flex items-center justify-center mb-4 group-hover:bg-accent-500/20 transition-colors">
                <Upload className="w-8 h-8 text-accent-500" />
              </div>
              <span className="text-white font-medium">上传图片</span>
              <span className="text-dark-500 text-sm mt-1">支持 JPG、PNG、BMP 格式</span>
            </button>

            <button
              onClick={() => folderInputRef.current?.click()}
              className="flex flex-col items-center justify-center p-8 rounded-xl border-2 border-dashed border-dark-500 hover:border-accent-500 hover:bg-dark-700 transition-all group"
            >
              <div className="w-16 h-16 rounded-full bg-accent-500/10 flex items-center justify-center mb-4 group-hover:bg-accent-500/20 transition-colors">
                <FolderOpen className="w-8 h-8 text-accent-500" />
              </div>
              <span className="text-white font-medium">选择文件夹</span>
              <span className="text-dark-500 text-sm mt-1">批量读取文件夹中的图片</span>
            </button>
          </div>

          <input
            ref={fileInputRef}
            type="file"
            multiple
            accept="image/*"
            onChange={handleFileSelect}
            className="hidden"
          />

          <input
            ref={folderInputRef}
            type="file"
            multiple
            webkitdirectory="true"
            directory="true"
            accept="image/*"
            onChange={handleFolderSelect}
            className="hidden"
          />
        </div>

        {images.length > 0 && (
          <>
            <div className="flex items-center justify-between mb-6">
              <div className="text-dark-400">
                已选择 <span className="text-accent-500 font-semibold">{images.length}</span> 张图片
              </div>
              <div className="flex gap-3">
                <button
                  onClick={clearAll}
                  className="flex items-center gap-2 px-4 py-2 rounded-lg text-dark-400 hover:text-white hover:bg-dark-700 transition-colors"
                >
                  <Trash2 className="w-4 h-4" />
                  清空全部
                </button>
                <button
                  onClick={handleRecognize}
                  disabled={isRecognizing}
                  className="flex items-center gap-2 px-6 py-2 rounded-lg bg-gradient-to-r from-accent-500 to-accent-600 text-white font-medium hover:opacity-90 transition-opacity disabled:opacity-50"
                >
                  {isRecognizing ? (
                    <>
                      <Loader2 className="w-4 h-4 animate-spin" />
                      识别中...
                    </>
                  ) : (
                    <>
                      <Image className="w-4 h-4" />
                      开始识别
                    </>
                  )}
                </button>
              </div>
            </div>

            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
              {images.map(image => {
                const result = results.find(r => r.imageId === image.id)
                const hasPlates = result?.plates?.length > 0

                return (
                  <div
                    key={image.id}
                    className="bg-dark-800 rounded-xl border border-dark-600 overflow-hidden"
                  >
                    <div className="relative">
                      <img
                        src={image.url}
                        alt={image.name}
                        className="w-full h-48 object-cover"
                      />
                      <button
                        onClick={() => removeImage(image.id)}
                        className="absolute top-2 right-2 w-8 h-8 rounded-lg bg-black/50 hover:bg-black/70 flex items-center justify-center text-white transition-colors"
                      >
                        <Trash2 className="w-4 h-4" />
                      </button>
                      {result && (
                        <div className={`absolute top-2 left-2 px-3 py-1 rounded-lg text-sm font-medium ${
                          hasPlates ? 'bg-green-500/90 text-white' : 'bg-red-500/90 text-white'
                        }`}>
                          {hasPlates ? `${result.plates.length} 个车牌` : '未识别到'}
                        </div>
                      )}
                    </div>

                    <div className="p-4">
                      <div className="flex items-center justify-between mb-3">
                        <span className="text-white font-medium truncate flex-1 mr-2">
                          {image.name}
                        </span>
                        <span className="text-dark-500 text-sm whitespace-nowrap">
                          {image.size}
                        </span>
                      </div>

                      {result && result.plates?.length > 0 && (
                        <div className="space-y-2">
                          {result.plates.map((plate, index) => (
                            <div
                              key={index}
                              className="flex items-center gap-3 p-3 rounded-lg bg-dark-700"
                            >
                              <CheckCircle className="w-5 h-5 text-green-500 flex-shrink-0" />
                              <div className="flex-1">
                                <div className="text-white font-mono font-semibold">
                                  {plate.plate_number || '未知'}
                                </div>
                                <div className="text-dark-400 text-xs">
                                  颜色: {plate.plate_color || '未知'} | 置信度: {plate.confidence}%
                                </div>
                              </div>
                            </div>
                          ))}
                        </div>
                      )}

                      {result && !hasPlates && (
                        <div className="flex items-center gap-2 text-red-400 text-sm">
                          <AlertCircle className="w-4 h-4" />
                          {result.error || '未识别到车牌'}
                        </div>
                      )}

                      {!result && (
                        <button
                          onClick={() => handleSingleRecognize(image.id)}
                          disabled={isRecognizing}
                          className="w-full py-2 rounded-lg bg-dark-700 text-dark-300 hover:bg-dark-600 hover:text-white transition-colors disabled:opacity-50"
                        >
                          单独识别
                        </button>
                      )}
                    </div>
                  </div>
                )
              })}
            </div>

            {results.length > 0 && (
              <div className="mt-8 p-6 rounded-xl bg-accent-500/10 border border-accent-500/30">
                <div className="flex items-center justify-between">
                  <div>
                    <h3 className="text-white font-semibold text-lg">识别统计</h3>
                    <p className="text-dark-400 mt-1">共处理 {images.length} 张图片</p>
                  </div>
                  <div className="text-center">
                    <div className="text-4xl font-bold text-accent-500">{totalPlates}</div>
                    <div className="text-dark-400 text-sm">识别到的车牌总数</div>
                  </div>
                </div>
              </div>
            )}
          </>
        )}

        {images.length === 0 && results.length === 0 && (
          <div className="text-center py-20">
            <div className="w-24 h-24 rounded-full bg-dark-700 flex items-center justify-center mx-auto mb-6">
              <Image className="w-12 h-12 text-dark-500" />
            </div>
            <h3 className="text-xl font-semibold text-white mb-2">选择图片开始识别</h3>
            <p className="text-dark-400">支持上传单张或多张图片，也可以选择文件夹批量识别</p>
          </div>
        )}
      </div>
    </div>
  )
}
