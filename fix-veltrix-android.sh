#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

echo '===== VELTRIX AI ANDROID FINAL UI FIX ====='

IP=$(ipconfig getifaddr en0)

if [ -z "$IP" ]; then
  echo 'ERROR: Wi-Fi IP address not found.'
  exit 1
fi

URL=http://$IP:5174

echo "Android app address: $URL"

echo ''
echo '===== VERIFY PHONE SERVER ====='

if ! curl -fsS --max-time 5 "$URL/api/health"; then
  echo ''
  echo 'ERROR: Veltrix AI is not reachable on port 5174.'
  echo 'Start the phone-accessible Vite server first.'
  exit 1
fi

echo ''
echo '===== BACKUP AND REPOSITION BUTTONS ====='

python3 - <<'PY'
from pathlib import Path
from datetime import datetime
import shutil

root = Path.cwd()
stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
backup = root / "backups" / f"android-ui-{stamp}"
backup.mkdir(parents=True, exist_ok=True)

styles = {
    "team-workspace.css": """
.vt-launch {
  top: 82px !important;
  bottom: auto !important;
  right: 14px !important;
  z-index: 89;
}
""",
    "streaming-chat.css": """
.vs-launch {
  top: 137px !important;
  bottom: auto !important;
  right: 14px !important;
  z-index: 89;
}
""",
    "document-assistant.css": """
.vd-launcher {
  top: 192px !important;
  bottom: auto !important;
  right: 14px !important;
  z-index: 89;
}
"""
}

for filename, css in styles.items():
    path = root / "frontend" / "src" / filename

    if not path.exists():
        raise SystemExit(f"Missing stylesheet: {filename}")

    shutil.copy2(path, backup / filename)

    source = path.read_text()

    start = "/* VELTRIX MOBILE BUTTON FIX START */"
    end = "/* VELTRIX MOBILE BUTTON FIX END */"

    if start in source and end in source:
        before = source.split(start)[0]
        after = source.split(end, 1)[1]
        source = before + after

    source += (
        "\n" + start + "\n"
        + css
        + end + "\n"
    )

    path.write_text(source)
    print("Fixed:", filename)

print("Backup:", backup)
PY

echo ''
echo '===== BUILD UPDATED WEB INTERFACE ====='

cd frontend

npm run build

echo ''
echo '===== SYNC ANDROID ====='

npx cap sync android

echo ''
echo '===== CONFIGURE ANDROID NETWORK ====='

python3 - "$URL" <<'PY'
import json
import re
import sys
from pathlib import Path

url = sys.argv[1]

assets = Path(
    "android/app/src/main/assets/capacitor.config.json"
)

manifest = Path(
    "android/app/src/main/AndroidManifest.xml"
)

if not assets.exists() or not manifest.exists():
    raise SystemExit(
        "Android configuration files were not found."
    )

config = json.loads(assets.read_text())

server = config.get("server", {})
server["url"] = url
server["cleartext"] = True

config["server"] = server

assets.write_text(
    json.dumps(config, indent=2) + "\n"
)

text = manifest.read_text()

if "android:usesCleartextTraffic" not in text:
    text, count = re.subn(
        r"<application\b",
        '<application android:usesCleartextTraffic="true"',
        text,
        count=1
    )

    if count != 1:
        raise SystemExit(
            "Could not locate Android application manifest."
        )

    manifest.write_text(text)

print("Android app URL:", url)
print("Local HTTP enabled for development testing.")
PY

echo ''
echo '===== BUILD ANDROID APK ====='

export JAVA_HOME=/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home
export PATH=$JAVA_HOME/bin:$PATH
export ANDROID_HOME=$HOME/Library/Android/sdk
export ANDROID_SDK_ROOT=$ANDROID_HOME

cd android

"$JAVA_HOME/bin/java" -version

./gradlew --no-daemon \
  -Dorg.gradle.java.home="$JAVA_HOME" \
  assembleDebug \
  --console=plain

echo ''
echo '===== VERIFY APK ====='

APK=app/build/outputs/apk/debug/app-debug.apk

if [ -f "$APK" ]; then
  echo 'VELTRIX AI ANDROID APK BUILD SUCCESSFUL'
  ls -lh "$APK"
  open -R "$APK"
else
  echo 'ERROR: APK file not found.'
  exit 1
fi

echo ''
echo '========================================'
echo ' VELTRIX AI ANDROID UPDATE COMPLETE'
echo '========================================'
echo 'Teams: Moved above chat'
echo 'Live AI: Moved above chat'
echo 'Documents: Moved above chat'
echo 'Send button: Unobstructed'
echo 'Android API connection: Wi-Fi test mode'
echo 'Existing accounts: Preserved'
echo 'Database: Unchanged'
echo '========================================'
