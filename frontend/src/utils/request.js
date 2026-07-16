const BASE_URL = "/api";
const DEFAULT_TIMEOUT = 30000;
const DEFAULT_HEADERS = {
  "Content-Type": "application/json",
};

function buildUrl(url) {
  if (/^https?:\/\//i.test(url)) {
    return url;
  }
  return `${BASE_URL}${url.startsWith("/") ? url : `/${url}`}`;
}

function getToken() {
  return localStorage.getItem("access_token") || localStorage.getItem("token");
}

function getErrorMessage(status, payload) {
  if (payload?.detail) {
    if (Array.isArray(payload.detail)) {
      return payload.detail[0]?.msg || "Request validation failed";
    }
    return payload.detail;
  }
  return `Request failed (${status})`;
}

async function parseResponse(response) {
  const contentType = response.headers.get("content-type") || "";
  if (contentType.includes("application/json")) {
    return response.json();
  }
  return response.text();
}

async function send(method, url, data, options = {}) {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), options.timeout ?? DEFAULT_TIMEOUT);
  const isFormData = typeof FormData !== "undefined" && data instanceof FormData;
  const headers = {
    ...DEFAULT_HEADERS,
    ...options.headers,
  };

  if (isFormData) {
    delete headers["Content-Type"];
  }

  const token = getToken();
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  try {
    const response = await fetch(buildUrl(url), {
      ...options,
      method,
      headers,
      signal: options.signal || controller.signal,
      body: data === undefined ? undefined : isFormData ? data : JSON.stringify(data),
    });
    const payload = await parseResponse(response);

    if (!response.ok) {
      const error = new Error(getErrorMessage(response.status, payload));
      error.response = {
        status: response.status,
        data: payload,
      };
      throw error;
    }

    return payload;
  } finally {
    clearTimeout(timeoutId);
  }
}

const request = {
  defaults: {
    baseURL: BASE_URL,
    timeout: DEFAULT_TIMEOUT,
    headers: DEFAULT_HEADERS,
  },
  get(url, options) {
    return send("GET", url, undefined, options);
  },
  post(url, data, options) {
    return send("POST", url, data, options);
  },
  put(url, data, options) {
    return send("PUT", url, data, options);
  },
  delete(url, options) {
    return send("DELETE", url, undefined, options);
  },
  request: send,
};

export default request;
