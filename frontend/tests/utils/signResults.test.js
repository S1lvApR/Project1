import { describe, expect, it } from "vitest";

import { formatSignResult } from "@/utils/signResults";

describe("formatSignResult", () => {
  it("formats task metadata and model detections", () => {
    const summary = formatSignResult({
      time: "2026/07/13 16:00:00",
      task_id: 7,
      total_images: 1,
      total_signs: 1,
      total_lights: 0,
      results: [
        {
          filename: "road.jpg",
          traffic_signs: [{ type: "pl60", confidence: 91 }],
          traffic_lights: [],
        },
      ],
    });

    expect(summary).toContain("任务 ID：7");
    expect(summary).toContain("最高限速 60 km/h");
    expect(summary).not.toContain("- pl60：");
    expect(summary).toContain("91%");
    expect(summary).not.toContain("模拟");
  });

  it("reports an empty result without throwing", () => {
    expect(formatSignResult({ total_images: 1, total_signs: 0, total_lights: 0 })).toContain(
      "未识别到交通标志和信号灯"
    );
  });

  it("prefers the classifier display label and includes its mode", () => {
    const summary = formatSignResult({
      recognition_mode: "classify",
      total_images: 1,
      total_signs: 1,
      results: [
        {
          filename: "00000.png",
          traffic_signs: [
            {
              type: "Vehicles over 3.5 metric tons prohibited",
              display_name: "禁止 3.5 吨以上车辆通行",
              confidence: 97.5,
            },
          ],
          traffic_lights: [],
        },
      ],
    });

    expect(summary).toContain("classify");
    expect(summary).toContain("禁止 3.5 吨以上车辆通行");
  });
});
