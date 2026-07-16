import { BrowserRouter, Routes, Route } from 'react-router-dom'
import Home from '@/pages/Home'
import LicensePlate from '@/pages/LicensePlate'
import CameraDetection from '@/pages/CameraDetection'

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Home />} />
        <Route path="/license-plate" element={<LicensePlate />} />
        <Route path="/camera" element={<CameraDetection />} />
      </Routes>
    </BrowserRouter>
  )
}
