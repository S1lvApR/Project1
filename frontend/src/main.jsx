import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
import { setupErrorReporting } from './utils/errorReporter'
import './index.scss'

setupErrorReporting()

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
