import { afterEach, describe, expect, it, vi } from "vitest";

import { streamChat } from "@/utils/stream";

describe("streamChat", () => {
  afterEach(() => {
    localStorage.clear();
    vi.unstubAllGlobals();
  });

  it("uses the same token key as the rest of the application", () => {
    localStorage.setItem("token", "current-token");
    const fetchMock = vi.fn(() => new Promise(() => {}));
    vi.stubGlobal("fetch", fetchMock);

    const stop = streamChat("/api/chat/stream", { message: "test" }, {});

    expect(fetchMock).toHaveBeenCalledOnce();
    expect(fetchMock.mock.calls[0][1].headers.Authorization).toBe(
      "Bearer current-token",
    );
    stop();
  });
});
