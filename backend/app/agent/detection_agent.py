from sqlalchemy.orm import Session

from app.services.video_detection_service import (
    VideoDetectionService,
    VideoTaskSubmission,
)


def detect_video_file(
    *,
    service: VideoDetectionService,
    db: Session,
    user_id: int,
    filename: str,
    content: bytes,
    confidence: float,
    iou: float,
    image_size: int,
    sample_rate: int,
    max_frames: int,
) -> VideoTaskSubmission:
    """Submit a local video detection task through the agent tool boundary."""
    return service.submit(
        db=db,
        user_id=user_id,
        filename=filename,
        content=content,
        confidence=confidence,
        iou=iou,
        image_size=image_size,
        sample_rate=sample_rate,
        max_frames=max_frames,
    )
