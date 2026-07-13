import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
import './index.scss'

window.onerror = function (message, source, lineno, colno, error) {
  console.error('Global Error:', { message, source, lineno, colno, error })
}

window.addEventListener('unhandledrejection', function (event) {
  console.error('Unhandled Rejection:', event.reason)
})

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <App />
  </StrictMode>,
)