const REPORT_TO_BACKEND = false;
const REPORT_API = "/api/errors/report";
const MAX_STORED_ERRORS = 50;

export function reportError(errorInfo) {
  console.error("[ErrorReporter]", errorInfo);

  try {
    const errors = JSON.parse(localStorage.getItem("error_logs") || "[]");
    errors.push({
      ...errorInfo,
      timestamp: new Date().toISOString(),
      url: window.location.href,
      userAgent: navigator.userAgent,
    });
    if (errors.length > MAX_STORED_ERRORS) {
      errors.splice(0, errors.length - MAX_STORED_ERRORS);
    }
    localStorage.setItem("error_logs", JSON.stringify(errors));
  } catch (error) {
    console.warn("ErrorReporter: localStorage write failed", error);
  }

  if (REPORT_TO_BACKEND) {
    fetch(REPORT_API, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(errorInfo),
    }).catch(() => {});
  }
}

export function setupErrorReporting() {
  window.onerror = (message, source, lineno, colno, error) => {
    reportError({
      type: "js_error",
      message,
      source,
      lineno,
      colno,
      stack: error?.stack,
    });
  };

  window.onunhandledrejection = (event) => {
    reportError({
      type: "promise_rejection",
      message: event.reason?.message || String(event.reason),
      stack: event.reason?.stack,
    });
    event.preventDefault();
  };
}
