from pathlib import Path
from datetime import datetime
import shutil
import subprocess
import sys

root = Path("frontend/src")
app = root / "App.tsx"
media = root / "MediaTools.tsx"

print("\n===== CONNECTING VELTRIX MULTIMEDIA =====")

if not app.exists() or not media.exists():
    sys.exit("ERROR: App.tsx or MediaTools.tsx is missing.")

original = app.read_text()

if "<MediaTools" in original:
    sys.exit(
        "MediaTools is already rendered. "
        "No changes made."
    )

if '<div className="composer-area">' not in original:
    sys.exit("ERROR: Composer area not found.")

backup = app.with_name(
    "App.tsx.backup-" +
    datetime.now().strftime("%Y%m%d-%H%M%S")
)

shutil.copy2(app, backup)
print("Backup created:", backup)

updated = original

# Add component import.
if 'import MediaTools from "./MediaTools";' not in updated:
    updated = (
        'import MediaTools from "./MediaTools";\n'
        + updated
    )

# Place toolbar above the chat form.
toolbar = '''
              <MediaTools
                latestAnswer={
                  [...messages]
                    .reverse()
                    .find(m => m.role === "assistant")
                    ?.content || ""
                }
                onInsert={(text) => {
                  setInput(previous =>
                    previous.trim()
                      ? previous + "\\\\n\\\\n" + text
                      : text
                  );
                }}
              />
'''

anchor = '<div className="composer-area">'

updated = updated.replace(
    anchor,
    anchor + toolbar,
    1
)

app.write_text(updated)

print("MediaTools connected to chat composer.")
print("Running frontend build...")

result = subprocess.run(
    ["npm", "run", "build"],
    cwd="frontend",
    check=False
)

if result.returncode != 0:
    app.write_text(original)
    print("\nBUILD FAILED.")
    print("Original App.tsx restored.")
    sys.exit(1)

print("\nBUILD SUCCESSFUL.")
print("Multimedia toolbar installed.")
print("Backup:", backup)
