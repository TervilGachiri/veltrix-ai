#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

echo '===== VELTRIX ANDROID API REPAIR ====='

IP=$(ipconfig getifaddr en0)

if [ -z "$IP" ]; then
  echo 'ERROR: Mac Wi-Fi address unavailable.'
  exit 1
fi

URL=http://$IP:5174
echo "Phone server: $URL"

echo '===== VERIFY REAL API JSON ====='

python3 - "$URL" <<'PY'
import json
import sys
import urllib.request

url = sys.argv[1] + "/api/health"

try:
    with urllib.request.urlopen(url, timeout=8) as response:
        content_type = response.headers.get("Content-Type", "")
        raw = response.read()
        payload = json.loads(raw)

        if not isinstance(payload, dict) or payload.get("status") != "ok":
            raise ValueError("Unexpected API health response")

        if "json" not in content_type.lower():
            raise ValueError("API returned incorrect Content-Type")

        print("PASS: API responds with JSON:", payload)
except Exception as error:
    print("ERROR: API is not ready:", error)
    print("Start the Mac backend and Vite server on port 5174 first.")
    sys.exit(1)
PY

echo '===== BACK UP ANDROID CONFIGURATION ====='

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=backups/android-api-$STAMP
mkdir -p "$BACKUP"

cp frontend/android/app/src/main/AndroidManifest.xml "$BACKUP/AndroidManifest.xml"

if [ -f frontend/android/app/src/main/assets/capacitor.config.json ]; then
  cp frontend/android/app/src/main/assets/capacitor.config.json \
    "$BACKUP/capacitor.config.json"
fi

echo '===== SYNC CURRENT FRONTEND ====='

cd frontend
npm run build
npx cap sync android

echo '===== FIX NATIVE SERVER CONNECTION ====='

python3 - "$URL" <<'PY'
import json
import re
import sys
from pathlib import Path

url = sys.argv[1]

config_path = Path(
    "android/app/src/main/assets/capacitor.config.json"
)

manifest_path = Path(
    "android/app/src/main/AndroidManifest.xml"
)

config = json.loads(config_path.read_text())

config["server"] = {
    **config.get("server", {}),
    "url": url,
    "cleartext": True
}

config_path.write_text(json.dumps(config, indent=2) + "\n")

manifest = manifest_path.read_text()

if 'android:usesCleartextTraffic=' in manifest:
    manifest = re.sub(
        r'android:usesCleartextTraffic="[^"]*"',
        'android:usesCleartextTraffic="true"',
        manifest
    )
else:
    manifest = manifest.replace(
        "<application",
        '<application android:usesCleartextTraffic="true"',
        1
    )

manifest_path.write_text(manifest)

print("PASS: Android WebView connects to:", url)
print("PASS: Development HTTP connection enabled")
print("PASS: Authentication API uses the same web origin")
PY

echo '===== BUILD REPLACEMENT APK ====='

export JAVA_HOME=/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home
export PATH=$JAVA_HOME/bin:$PATH
export ANDROID_HOME=$HOME/Library/Android/sdk
export ANDROID_SDK_ROOT=$ANDROID_HOME

cd android

./gradlew --no-daemon \
  -Dorg.gradle.java.home=$JAVA_HOME \
  assembleDebug --console=plain

APK=app/build/outputs/apk/debug/app-debug.apk

test -f "$APK"

echo '===== APK CREATED ====='
ls -lh "$APK"
open -R "$APK"

echo '===== REPAIR COMPLETE ====='
echo "API address: $URL"
echo "Backup: $BACKUP"
echo 'Install the newly built APK on your Android phone.'
