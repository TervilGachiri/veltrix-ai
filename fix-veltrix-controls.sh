#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

echo '===== VELTRIX AI CONTROL FIX ====='

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="backups/controls-$STAMP"
mkdir -p "$BACKUP"

for file in App.tsx main.tsx ToolsDock.tsx tool-dock.css; do
  if [ -f "frontend/src/$file" ]; then
    cp "frontend/src/$file" "$BACKUP/$file"
  fi
done

echo "Backup: $BACKUP"

cat > frontend/src/ToolsDock.tsx <<'TSX'
import { useEffect, useState } from 'react';
import { Wrench, X } from 'lucide-react';
import './tool-dock.css';

export default function ToolsDock() {
  const [open, setOpen] = useState(false);

  useEffect(() => {
    document.body.classList.toggle('vx-tools-open', open);
    return () => {
      document.body.classList.remove('vx-tools-open');
    };
  }, [open]);

  return (
    <button
      type="button"
      className="vx-tools-toggle"
      onClick={() => setOpen(value => !value)}
      aria-label={open ? 'Close tools' : 'Open tools'}
      aria-expanded={open}
      title="Veltrix AI Tools"
    >
      {open ? <X size={19} /> : <Wrench size={19} />}
      <span>{open ? 'Close' : 'Tools'}</span>
    </button>
  );
}
TSX

cat > frontend/src/tool-dock.css <<'CSS'
/*
  Veltrix tools dock.

  Collapsed: one button at the middle right.
  Expanded: three tools stacked around the
  middle of the screen.

  No controls overlap the header or composer.
*/

.vx-tools-toggle {
  position: fixed !important;
  top: 49% !important;
  right: 12px !important;
  bottom: auto !important;
  left: auto !important;
  transform: translateY(-50%);
  z-index: 95 !important;
  display: flex !important;
  align-items: center;
  justify-content: center;
  gap: 7px;
  padding: 11px 13px;
  min-height: 43px;
  border: none;
  border-radius: 13px;
  background: #5e58d7;
  color: #fff;
  box-shadow: 0 7px 22px #161a5060;
  font-size: 12px;
  font-weight: 700;
  cursor: pointer;
}

/* Hide individual tools while the dock is closed. */

body:not(.vx-tools-open) .vt-launch,
body:not(.vx-tools-open) .vs-launch,
body:not(.vx-tools-open) .vd-launcher {
  visibility: hidden !important;
  opacity: 0 !important;
  pointer-events: none !important;
}

/* Reveal three tools in one compact vertical group. */

body.vx-tools-open .vt-launch,
body.vx-tools-open .vs-launch,
body.vx-tools-open .vd-launcher {
  visibility: visible !important;
  opacity: 1 !important;
  pointer-events: auto !important;

  position: fixed !important;
  left: auto !important;
  bottom: auto !important;
  right: 12px !important;

  transform: none !important;
  z-index: 94 !important;

  min-height: 42px;
  min-width: 112px;

  display: flex !important;
  align-items: center;
  justify-content: center;

  padding: 10px 12px !important;
  font-size: 12px;
}

body.vx-tools-open .vt-launch {
  top: calc(49% - 118px) !important;
}

body.vx-tools-open .vs-launch {
  top: calc(49% - 68px) !important;
}

body.vx-tools-open .vd-launcher {
  top: calc(49% + 32px) !important;
}

/* Keep the main message composer interactive. */

.compose-wrap {
  position: relative;
  z-index: 2;
}

.compose {
  position: relative;
}

.compose textarea {
  position: relative;
  pointer-events: auto !important;
}

.compose .send,
.compose button[type="submit"],
.compose button[aria-label="Send message"] {
  position: relative;
  z-index: 5;
  pointer-events: auto !important;
  touch-action: manipulation;
}

/* On narrow phones, protect the message field. */

@media (max-width: 600px) {
  .vx-tools-toggle {
    right: 7px !important;
    padding: 10px !important;
    min-height: 42px;
  }

  body.vx-tools-open .vt-launch,
  body.vx-tools-open .vs-launch,
  body.vx-tools-open .vd-launcher {
    right: 7px !important;
    min-width: 102px;
    padding: 9px !important;
    font-size: 11px;
  }

  .compose-wrap {
    padding-bottom: env(safe-area-inset-bottom, 0px);
  }
}
CSS

echo '===== INTEGRATING TOOLS MENU ====='

python3 - <<'PY'
from pathlib import Path
import re

root = Path("frontend/src")
main = root / "main.tsx"
source = main.read_text()

if "import ToolsDock from " not in source:
    source = (
        "import ToolsDock from './ToolsDock';\n"
        + source
    )

if "<ToolsDock" not in source:
    source, count = re.subn(
        r"<App\s*/>",
        "<App /><ToolsDock />",
        source,
        count=1
    )

    if count != 1:
        raise SystemExit(
            "Could not safely locate React App root."
        )

main.write_text(source)
print("PASS: Tools menu connected")

# Fix the main chat's Send button explicitly
# where the original send() function exists.

app = root / "App.tsx"
code = app.read_text()

supports_send = bool(re.search(
    r"(async\s+function\s+send\s*\(|"
    r"function\s+send\s*\(|"
    r"const\s+send\s*=)",
    code
))

pattern = re.compile(
    r'<button\s+type="submit"\s+className="send"'
)

if supports_send and pattern.search(code):
    code = pattern.sub(
        '<button type="button" '
        'onClick={() => { void send(); }} '
        'className="send"',
        code,
        count=1
    )
    app.write_text(code)
    print("PASS: Main Send button wired directly")
elif re.search(
    r'onClick=\{.*send\(',
    code
):
    print("INFO: Existing Send click handler detected")
else:
    print(
        "WARNING: Main Send handler uses another structure."
    )
    print(
        "The button remains unchanged; layout fix applied."
    )
PY

echo '===== VERIFY REACT BUILD ====='

if ! (cd frontend && npm run build); then
  echo 'Build failed. Restoring files.'

  for file in App.tsx main.tsx ToolsDock.tsx tool-dock.css; do
    if [ -f "$BACKUP/$file" ]; then
      cp "$BACKUP/$file" "frontend/src/$file"
    else
      rm -f "frontend/src/$file"
    fi
  done

  exit 1
fi

echo '===== SYNC ANDROID ====='

(
  cd frontend
  npx cap sync android
)

echo '===== BUILD ANDROID APK ====='

export JAVA_HOME=/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home
export PATH="$JAVA_HOME/bin:$PATH"
export ANDROID_HOME="$HOME/Library/Android/sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"

if [ ! -x "$JAVA_HOME/bin/java" ]; then
  echo 'JDK 21 not found. Frontend changes were saved.'
  exit 1
fi

(
  cd frontend/android
  ./gradlew --no-daemon \
    -Dorg.gradle.java.home="$JAVA_HOME" \
    assembleDebug \
    --console=plain
)

echo '===== VERIFY UPDATED APK ====='

APK=frontend/android/app/build/outputs/apk/debug/app-debug.apk

if [ -f "$APK" ]; then
  ls -lh "$APK"
  open -R "$APK"
  echo 'SUCCESS: Updated Android APK created.'
else
  echo 'ERROR: APK not found.'
  exit 1
fi

echo '===== VELTRIX UI UPDATE COMPLETE ====='
echo 'Main Send button: Updated where supported'
echo 'Tools menu: Added'
echo 'Teams / Live AI / Documents: Repositioned'
echo 'Login and database: Unchanged'
echo "Backup: $BACKUP"
