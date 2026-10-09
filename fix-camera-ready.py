from pathlib import Path
from datetime import datetime
import shutil
import subprocess
import sys

path = Path("frontend/src/MediaTools.tsx")

if not path.exists():
    sys.exit("ERROR: MediaTools.tsx not found.")

original = path.read_text()
updated = original

backup = path.with_name(
    "MediaTools.tsx.backup-" +
    datetime.now().strftime("%Y%m%d-%H%M%S")
)

shutil.copy2(path, backup)

print("===== VELTRIX CAMERA READINESS FIX =====")
print("Backup:", backup)

old_state = 'const [cameraOpen, setCameraOpen] = useState(false);'
new_state = '''const [cameraOpen, setCameraOpen] = useState(false);
  const [cameraReady, setCameraReady] = useState(false);'''

old_open = '''      streamRef.current = stream;
      setPhoto(null);'''

new_open = '''      streamRef.current = stream;
      setCameraReady(false);
      setPhoto(null);'''

old_close = '''    stopCamera();
    setCameraOpen(false);'''

new_close = '''    stopCamera();
    setCameraReady(false);
    setCameraOpen(false);'''

old_capture = '''    if (!video || !video.videoWidth || !video.videoHeight) {
      setMessage("Camera is not ready. Try again.");
      return;
    }'''

new_capture = '''    if (!video || !cameraReady ||
        !video.videoWidth || !video.videoHeight) {
      setMessage("Camera is loading. Wait for the preview.");
      return;
    }'''

old_video = '''              <video
                ref={videoRef}
                autoPlay
                playsInline
                muted'''

new_video = '''              <video
                ref={videoRef}
                autoPlay
                playsInline
                muted
                onLoadedMetadata={() => {
                  videoRef.current?.play().catch(() => {
                    setMessage("Camera playback was blocked.");
                  });
                }}
                onPlaying={() => setCameraReady(true)}
                onEmptied={() => setCameraReady(false)}'''

old_button = '''                  onClick={capturePhoto}
                >
                  <Camera size={17} /> Capture Photo'''

new_button = '''                  onClick={capturePhoto}
                  disabled={!cameraReady}
                >
                  <Camera size={17} />
                  {cameraReady ? "Capture Photo" : "Starting Camera..."}'''

replacements = [
    (old_state, new_state),
    (old_open, new_open),
    (old_close, new_close),
    (old_capture, new_capture),
    (old_video, new_video),
    (old_button, new_button),
]

for old, new in replacements:
    count = updated.count(old)

    if count != 1:
        print(
            f"ERROR: Expected one match, found {count}: "
            f"{old[:65]!r}"
        )
        sys.exit(
            "No code changes saved. Original file preserved."
        )

    updated = updated.replace(old, new, 1)

path.write_text(updated)

print("Running frontend build...")

result = subprocess.run(
    ["npm", "run", "build"],
    cwd="frontend"
)

if result.returncode != 0:
    path.write_text(original)
    sys.exit("Build failed. Original file restored.")

print("\nCAMERA FIX BUILT SUCCESSFULLY")
print("Refresh http://localhost:5173")
