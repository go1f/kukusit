# Third-party components

Kukusit uses Apple frameworks supplied by macOS, and bundles the following components for offline pose inference:

- MediaPipe 0.10.35, Google / The MediaPipe Authors, Apache License 2.0. Source: https://github.com/google-ai-edge/mediapipe
- Pose Landmarker Full, official model bundle version 1. Model source and model card: https://developers.google.com/edge/mediapipe/solutions/vision/pose_landmarker
  - Download: https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_full/float16/1/pose_landmarker_full.task
  - SHA-256: `5134a3aad27a58b93da0088d431f366da362b44e3ccfbe3462b3827a839011b1`
- Python 3.12, Python Software Foundation License. https://www.python.org/psf/license/
- NumPy 2.2.6, NumPy Developers, BSD-3-Clause. https://numpy.org/
- PyInstaller 6.16.0, GPL-2.0-or-later with the PyInstaller bootloader exception; generated application distribution is permitted under that exception. https://pyinstaller.org/en/v6.16.0/license.html

The bundled inference runtime also contains dependencies required by these packages, including matplotlib, OpenCV, Pillow, flatbuffers, absl-py, cffi and sounddevice. Their original license files are included under `Contents/Resources/ThirdPartyLicenses/` in the release app, where available from the installed distributions.

No camera images, personal calibration data, or machine-specific validation reports are included in the release.
