#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

python3 - <<'PY'
from pathlib import Path
from datetime import datetime
import subprocess
import sys

p = Path("frontend/src/MediaTools.tsx")
if not p.exists():
    sys.exit("ERROR: MediaTools.tsx not found.")

original = p.read_text()
source = original

backup = p.with_name(
    f"MediaTools.tsx.backup-{datetime.now():%Y%m%d-%H%M%S}"
)
backup.write_text(original)

print("===== VELTRIX CAMERA STREAM REPAIR =====")
print("Backup:", backup)

try:
    # Stable callback that attaches the stream as soon as
    # React creates the video element.
    if "  useCallback," not in source:
        source = source.replace(
            "  useEffect,\n",
            "  useEffect,\n  useCallback,\n",
            1
        )

    if "  useCallback," not in source:
        raise ValueError("Could not add useCallback import.")

    # Remove the old camera effect, including the metadata timeout.
    start = source.find("  useEffect(() => {\n    if (!cameraOpen")
    end_marker = "  }, [cameraOpen, photo]);"

    if start == -1:
        raise ValueError("Expected camera effect not found.")

    end = source.find(end_marker, start)
    if end == -1:
        raise ValueError("Camera effect ending not found.")

    end += len(end_marker)

    source = source[:start] + source[end:]

    anchor = "  function closeCamera() {"

    callback = '''
  const attachVideo = useCallback(
    (element: HTMLVideoElement | null) => {
      videoRef.current = element;
      if (!element) return;

      const stream = streamRef.current;
      if (!stream) {
        setMessage("Camera stream unavailable.");
        return;
      }

      element.muted = true;
      element.playsInline = true;
      element.autoplay = true;
      element.srcObject = stream;

      const reportReady = () => {
        if (element.videoWidth > 0 &&
            element.videoHeight > 0) {
          setCameraReady(true);
          setMessage("");
        }
      };

      element.onloadeddata = reportReady;
      element.onplaying = reportReady;

      element.onloadedmetadata = () => {
        void element.play().catch(error => {
          setMessage(
            "Camera playback: " +
            (error instanceof Error
              ? error.name + " - " + error.message
              : "Playback unavailable")
          );
        });
      };

      // Safari may already have metadata when handlers attach.
      if (element.readyState >= 1) {
        void element.play().catch(error => {
          setMessage(
            "Camera playback: " +
            (error instanceof Error
              ? error.name + " - " + error.message
              : "Playback unavailable")
          );
        });
      }

      reportReady();
    },
    []
  );

'''

    if source.count(anchor) != 1:
        raise ValueError("Could not locate camera close handler.")

    source = source.replace(anchor, callback + anchor, 1)

    if source.count("ref={videoRef}") != 1:
        raise ValueError("Expected video ref not found.")

    source = source.replace(
        "ref={videoRef}",
        "ref={attachVideo}",
        1
    )

    # The callback handles playback itself.
    old = '''                onLoadedMetadata={() => {
                  videoRef.current?.play().catch(() => {
                    setMessage("Camera playback was blocked.");
                  });
                }}
'''
    source = source.replace(old, "", 1)

    p.write_text(source)

    print("Building React frontend...")
    result = subprocess.run(
        ["npm", "run", "build"],
        cwd="frontend",
        check=False
    )

    if result.returncode != 0:
        raise ValueError("Frontend build failed.")

except Exception as error:
    p.write_text(original)
    sys.exit(f"Repair not applied: {error}")

print()
print("SUCCESS: Camera stream integration built.")
print("Existing login and database untouched.")
print("Refresh http://localhost:5173")
PY
