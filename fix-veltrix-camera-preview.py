from pathlib import Path
from datetime import datetime
import shutil
import subprocess
import sys

p = Path("frontend/src/MediaTools.tsx")
if not p.exists():
    sys.exit("MediaTools.tsx not found.")

original = p.read_text()
source = original

backup = p.with_name(
    f"MediaTools.tsx.camera-backup-{datetime.now():%Y%m%d-%H%M%S}"
)
shutil.copy2(p, backup)

def replace_once(old, new, label):
    global source
    count = source.count(old)
    if count != 1:
        raise ValueError(f"{label}: expected 1 match; found {count}")
    source = source.replace(old, new, 1)

try:
    replace_once(
        '''  useEffect(() => {
    if (cameraOpen && streamRef.current && videoRef.current) {
      videoRef.current.srcObject = streamRef.current;
      videoRef.current.play().catch(() => {
        setMessage("Camera preview could not start.");
      });
    }
  }, [cameraOpen, photo]);''',
        '''  useEffect(() => {
    if (!cameraOpen || photo || !videoRef.current ||
        !streamRef.current) return;

    const video = videoRef.current;
    const stream = streamRef.current;
    let cancelled = false;

    video.srcObject = stream;

    const startPlayback = async () => {
      try {
        if (video.readyState < HTMLMediaElement.HAVE_METADATA) {
          await new Promise<void>((resolve, reject) => {
            const timeout = window.setTimeout(() => {
              cleanup();
              reject(new Error("Camera metadata timeout"));
            }, 10000);

            const cleanup = () => {
              window.clearTimeout(timeout);
              video.removeEventListener("loadedmetadata", onReady);
              video.removeEventListener("error", onError);
            };

            const onReady = () => {
              cleanup();
              resolve();
            };

            const onError = () => {
              cleanup();
              reject(new Error("Camera video error"));
            };

            video.addEventListener("loadedmetadata", onReady);
            video.addEventListener("error", onError);
          });
        }

        if (!cancelled) {
          await video.play();
          if (!cancelled) setCameraReady(true);
        }
      } catch (error) {
        if (!cancelled) {
          setCameraReady(false);
          setMessage(
            "Camera preview failed: " +
            (error instanceof Error ? error.message : "Unknown error")
          );
        }
      }
    };

    void startPlayback();

    return () => {
      cancelled = true;
    };
  }, [cameraOpen, photo]);''',
        "camera playback effect"
    )

    # Remove the second play() call; playback is now handled
    # by the effect after metadata becomes available.
    old = '''                onLoadedMetadata={() => {
                  videoRef.current?.play().catch(() => {
                    setMessage("Camera playback was blocked.");
                  });
                }}
'''
    if old in source:
        source = source.replace(old, "", 1)

    p.write_text(source)

    result = subprocess.run(
        ["npm", "run", "build"],
        cwd="frontend",
        check=False
    )

    if result.returncode != 0:
        p.write_text(original)
        sys.exit("Build failed. Original file restored.")

except (ValueError, OSError) as error:
    p.write_text(original)
    sys.exit(f"No changes kept: {error}")

print()
print("CAMERA PREVIEW FIX: BUILD PASSED")
print("Backup:", backup)
print("Refresh http://localhost:5173")
