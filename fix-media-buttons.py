from pathlib import Path
from datetime import datetime
import shutil
import re

root = Path("frontend/src")
app = root / "App.tsx"
media = root / "MediaTools.tsx"

print("\n===== VELTRIX AI MEDIA TOOLBAR FIX =====")

if not app.exists():
    raise SystemExit("ERROR: App.tsx not found.")

if not media.exists():
    raise SystemExit(
        "ERROR: MediaTools.tsx is missing. "
        "The multimedia installation was incomplete."
    )

source = app.read_text()

if "MediaTools" in source and "<MediaTools" in source:
    print("Toolbar already inserted. Checking its position...")
else:
    backup = app.with_name(
        "App.tsx.backup-" +
        datetime.now().strftime("%Y%m%d-%H%M%S")
    )
    shutil.copy2(app, backup)
    print("Backup:", backup)

    if 'import MediaTools from "./MediaTools";' not in source:
        source = 'import MediaTools from "./MediaTools";\n' + source

    matches = list(
        re.finditer(r"<textarea\b", source, flags=re.I)
    )

    if not matches:
        raise SystemExit(
            "ERROR: Cannot locate chat textarea. "
            "App.tsx has a different composer structure."
        )

    print("Textareas found:", len(matches))

    match = matches[-1]
    start = match.start()
    end = source.find("</textarea>", start)

    if end == -1:
        raise SystemExit(
            "ERROR: Chat textarea closing tag not found."
        )

    end += len("</textarea>")

    toolbar = '''
          <MediaTools
            latestAnswer={
              [...messages]
                .reverse()
                .find(m => m.role === "assistant")
                ?.content || ""
            }
            onInsert={(text) =>
              setInput(previous =>
                previous.trim()
                  ? previous + "\\n\\n" + text
                  : text
              )
            }
          />
'''

    source = source[:end] + toolbar + source[end:]
    app.write_text(source)

    print("Toolbar added after chat textarea.")

print("\n===== VERIFY FILES =====")
print("MediaTools.tsx:", media.exists())
print("Toolbar in App.tsx:", "<MediaTools" in app.read_text())
