"""Local-only BGRA frame pipe -> MediaPipe Pose -> JSON; no camera or files."""
import argparse
import hashlib
import json
import sys


def emit(value):
    sys.stdout.write(json.dumps(value, allow_nan=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def read_exact(stream, length):
    parts = []
    remaining = length
    while remaining:
        chunk = stream.read(remaining)
        if not chunk:
            raise EOFError("incomplete frame")
        parts.append(chunk)
        remaining -= len(chunk)
    return b"".join(parts)


def run(model_path, expected_hash):
    import mediapipe as mp
    import numpy as np

    with open(model_path, "rb") as model_file:
        if hashlib.file_digest(model_file, "sha256").hexdigest() != expected_hash:
            raise ValueError("model checksum mismatch")
    options = mp.tasks.vision.PoseLandmarkerOptions(
        base_options=mp.tasks.BaseOptions(model_asset_path=model_path),
        running_mode=mp.tasks.vision.RunningMode.VIDEO,
        num_poses=2,
        min_pose_detection_confidence=0.5,
        min_pose_presence_confidence=0.5,
        min_tracking_confidence=0.5,
        output_segmentation_masks=False,
    )
    with mp.tasks.vision.PoseLandmarker.create_from_options(options) as detector:
        emit({"ready": True, "version": mp.__version__})
        last_timestamp = -1
        while header_line := sys.stdin.buffer.readline():
            header = json.loads(header_line)
            width, height, row_bytes = header["width"], header["height"], header["rowBytes"]
            timestamp = header["timestampMS"]
            if not (0 < width <= 4096 and 0 < height <= 4096 and width * 4 <= row_bytes <= width * 4 + 4096):
                raise ValueError("invalid frame dimensions")
            if timestamp <= last_timestamp:
                raise ValueError("timestamps must increase")
            pixels = read_exact(sys.stdin.buffer, row_bytes * height)
            rows = np.frombuffer(pixels, dtype=np.uint8).reshape(height, row_bytes)
            bgra = rows[:, :width * 4].reshape(height, width, 4)
            rgb = np.ascontiguousarray(bgra[:, :, [2, 1, 0]])
            image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
            result = detector.detect_for_video(image, timestamp)
            last_timestamp = timestamp
            poses = [[{"x": p.x, "y": p.y,
                       "confidence": min(p.visibility or 0.0, p.presence or 0.0)}
                      for p in pose] for pose in result.pose_landmarks]
            emit({"timestampMS": timestamp, "poses": poses})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--sha256", required=True)
    args = parser.parse_args()
    try:
        run(args.model, args.sha256)
    except (BrokenPipeError, EOFError):
        return
    except Exception as error:
        emit({"error": str(error)})
        raise SystemExit(1)


if __name__ == "__main__":
    main()
