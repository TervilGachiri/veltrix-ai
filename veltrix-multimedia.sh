#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

echo "===== VELTRIX AI MULTIMEDIA UPGRADE ====="

STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p backups

cp backend/main.py "backups/main-media-$STAMP.py"
cp frontend/src/App.tsx "backups/App-media-$STAMP.tsx"
cp frontend/src/styles.css "backups/styles-media-$STAMP.css"

echo "Installing document processing libraries..."

backend/.venv/bin/python -m pip install \
  "python-multipart>=0.0.20" \
  "pypdf>=5,<7" \
  "python-docx>=1.1,<2" \
  "openpyxl>=3.1,<4" \
  "reportlab>=4,<5" \
  "Pillow>=11,<13"

cat > backend/media_routes.py <<'PY'
import base64
import io
import os
import re
from pathlib import Path

import httpx
from fastapi import (
    APIRouter, Cookie, File, HTTPException,
    Request, UploadFile
)
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from auth_routes import require_user

router = APIRouter(prefix="/api/media", tags=["Media"])

MAX_BYTES = 8 * 1024 * 1024
MAX_TEXT = 18000

ALLOWED = {
    ".pdf", ".docx", ".xlsx", ".txt",
    ".csv", ".png", ".jpg", ".jpeg", ".webp"
}
IMAGE_TYPES = {".png", ".jpg", ".jpeg", ".webp"}


def authenticate(token):
    return require_user(token)


def verify_origin(request: Request):
    origin = request.headers.get("origin")
    allowed = {
        "http://localhost:5173",
        "http://127.0.0.1:5173"
    }
    configured = os.getenv(
        "VELTRIX_FRONTEND_ORIGIN", ""
    ).rstrip("/")
    if configured:
        allowed.add(configured)

    if origin and origin.rstrip("/") not in allowed:
        raise HTTPException(403, "Untrusted request origin.")


async def read_limited(upload: UploadFile):
    data = await upload.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise HTTPException(413, "Maximum file size is 8 MB.")
    if not data:
        raise HTTPException(400, "The file is empty.")
    return data


def file_extension(filename):
    ext = Path(filename or "").suffix.lower()
    if ext not in ALLOWED:
        raise HTTPException(
            415, "Unsupported file format."
        )
    return ext


def extract_content(data, ext):
    if ext in (".txt", ".csv"):
        return data.decode("utf-8-sig", errors="replace")[:MAX_TEXT]

    if ext == ".pdf":
        from pypdf import PdfReader

        reader = PdfReader(io.BytesIO(data))
        if len(reader.pages) > 150:
            raise HTTPException(413, "Too many PDF pages.")

        parts = []
        total = 0
        for page in reader.pages:
            text = page.extract_text() or ""
            remaining = MAX_TEXT - total
            if remaining <= 0:
                break
            parts.append(text[:remaining])
            total += len(parts[-1])
        return "\n".join(parts)

    if ext == ".docx":
        from docx import Document

        document = Document(io.BytesIO(data))
        output = []
        for paragraph in document.paragraphs:
            if paragraph.text.strip():
                output.append(paragraph.text)
        for table in document.tables:
            for row in table.rows:
                output.append(
                    " | ".join(cell.text for cell in row.cells)
                )
        return "\n".join(output)[:MAX_TEXT]

    if ext == ".xlsx":
        from openpyxl import load_workbook

        book = load_workbook(
            io.BytesIO(data),
            read_only=True,
            data_only=True
        )
        output = []
        remaining = MAX_TEXT

        try:
            for sheet in book.worksheets[:10]:
                output.append(f"\nSheet: {sheet.title}")
                for index, row in enumerate(
                    sheet.iter_rows(values_only=True)
                ):
                    if index >= 300 or remaining <= 0:
                        break
                    line = " | ".join(
                        "" if cell is None else str(cell)
                        for cell in row[:30]
                    )
                    line = line[:remaining]
                    output.append(line)
                    remaining -= len(line)
        finally:
            book.close()

        return "\n".join(output)[:MAX_TEXT]

    raise HTTPException(415, "No text extractor available.")


def validated_image(data):
    from PIL import Image, ImageOps, UnidentifiedImageError

    try:
        image = Image.open(io.BytesIO(data))
        image.verify()

        image = Image.open(io.BytesIO(data))
        if image.width * image.height > 20_000_000:
            raise HTTPException(413, "Image resolution too large.")

        image = ImageOps.exif_transpose(image)
        image.thumbnail((1280, 1280))
        image = image.convert("RGB")

        result = io.BytesIO()
        image.save(result, format="JPEG", quality=82)
        return result.getvalue()
    except HTTPException:
        raise
    except (UnidentifiedImageError, OSError, ValueError):
        raise HTTPException(415, "Invalid or unsupported image.")


@router.post("/extract")
async def extract(
    request: Request,
    file: UploadFile = File(...),
    veltrix_session: str | None = Cookie(default=None),
):
    authenticate(veltrix_session)
    verify_origin(request)

    ext = file_extension(file.filename)
    if ext in IMAGE_TYPES:
        raise HTTPException(
            400,
            "Images need the vision model, not text extraction."
        )

    data = await read_limited(file)

    try:
        content = extract_content(data, ext)
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(
            422,
            "The document could not be read."
        )

    if not content.strip():
        raise HTTPException(
            422,
            "No readable text found. Scanned PDFs require OCR."
        )

    return {
        "filename": Path(file.filename or "document").name,
        "text": content,
        "truncated": len(content) >= MAX_TEXT
    }


@router.post("/vision")
async def vision(
    request: Request,
    file: UploadFile = File(...),
    veltrix_session: str | None = Cookie(default=None),
):
    authenticate(veltrix_session)
    verify_origin(request)

    ext = file_extension(file.filename)
    if ext not in IMAGE_TYPES:
        raise HTTPException(415, "Upload an image.")

    content = await read_limited(file)
    image_bytes = validated_image(content)

    model = os.getenv("OLLAMA_VISION_MODEL", "gemma3:4b")
    payload = {
        "model": model,
        "messages": [{
            "role": "user",
            "content": (
                "Describe this image accurately. "
                "Extract clearly readable text where relevant. "
                "Do not invent details you cannot see."
            ),
            "images": [
                base64.b64encode(image_bytes).decode("ascii")
            ]
        }],
        "stream": False,
        "options": {"num_predict": 400}
    }

    try:
        async with httpx.AsyncClient(
            timeout=240
        ) as client:
            response = await client.post(
                "http://127.0.0.1:11434/api/chat",
                json=payload
            )

        if response.status_code >= 400:
            raise HTTPException(
                503,
                "Vision model unavailable. "
                "Install the configured Ollama vision model."
            )

        result = response.json()
        description = result.get(
            "message", {}
        ).get("content", "").strip()

        description = re.sub(
            r"<think>.*?</think>",
            "",
            description,
            flags=re.DOTALL
        ).strip()

        if "</think>" in description:
            description = description.rsplit(
                "</think>", 1
            )[-1].strip()

        if not description:
            raise HTTPException(
                502, "Vision model returned no description."
            )

        return {
            "filename": Path(file.filename or "photo").name,
            "description": description[:MAX_TEXT]
        }

    except httpx.TimeoutException:
        raise HTTPException(504, "Image analysis timed out.")
    except httpx.RequestError:
        raise HTTPException(
            503, "Ollama vision service is unavailable."
        )


class ExportRequest(BaseModel):
    text: str = Field(min_length=1, max_length=30000)
    format: str = Field(pattern="^(pdf|docx|xlsx|txt)$")


@router.post("/export")
def export(
    data: ExportRequest,
    request: Request,
    veltrix_session: str | None = Cookie(default=None),
):
    authenticate(veltrix_session)
    verify_origin(request)

    content = io.BytesIO()
    fmt = data.format

    if fmt == "pdf":
        from reportlab.platypus import (
            SimpleDocTemplate, Paragraph, Spacer
        )
        from reportlab.lib.styles import getSampleStyleSheet
        from xml.sax.saxutils import escape

        doc = SimpleDocTemplate(content)
        styles = getSampleStyleSheet()

        story = [
            Paragraph("Veltrix AI Report", styles["Title"]),
            Spacer(1, 18)
        ]

        for line in data.text.splitlines():
            if line.strip():
                story.append(
                    Paragraph(
                        escape(line[:2000]),
                        styles["BodyText"]
                    )
                )
                story.append(Spacer(1, 6))

        doc.build(story)
        mime = "application/pdf"

    elif fmt == "docx":
        from docx import Document

        document = Document()
        document.add_heading("Veltrix AI Report", 0)

        for line in data.text.splitlines():
            document.add_paragraph(line)

        document.save(content)
        mime = (
            "application/vnd.openxmlformats-officedocument."
            "wordprocessingml.document"
        )

    elif fmt == "xlsx":
        from openpyxl import Workbook

        workbook = Workbook()
        sheet = workbook.active
        sheet.title = "Veltrix Report"

        for line in data.text.splitlines()[:5000]:
            # Prevent spreadsheet formula injection.
            if line.startswith(("=", "+", "-", "@")):
                line = "'" + line
            sheet.append([line[:32000]])

        workbook.save(content)
        mime = (
            "application/vnd.openxmlformats-officedocument."
            "spreadsheetml.sheet"
        )

    else:
        content.write(data.text.encode("utf-8"))
        mime = "text/plain; charset=utf-8"

    content.seek(0)

    return StreamingResponse(
        content,
        media_type=mime,
        headers={
            "Content-Disposition":
                f'attachment; filename="veltrix-report.{fmt}"',
            "Cache-Control": "no-store"
        }
    )
PY

python3 - <<'PY'
from pathlib import Path

p = Path("backend/main.py")
source = p.read_text()

statement = "from media_routes import router as media_router"

if statement not in source:
    lines = source.splitlines(keepends=True)
    position = 0
    for i, line in enumerate(lines):
        if line.startswith("from __future__ import"):
            position = i + 1
    lines.insert(position, statement + "\n")
    source = "".join(lines)

if "app.include_router(media_router)" not in source:
    source += "\napp.include_router(media_router)\n"

compile(source, str(p), "exec")
p.write_text(source)

print("Veltrix multimedia API registered.")
PY

echo "Backend media capabilities installed."

cat > frontend/src/MediaTools.tsx <<'TSX'
import {
  useRef, useState,
  type ChangeEvent
} from "react";
import {
  Paperclip, Camera, Mic, Volume2,
  Download, LoaderCircle, Square, VolumeX
} from "lucide-react";

type Props = {
  onInsert: (text: string) => void;
  latestAnswer: string;
};

type SpeechResult = {
  results: ArrayLike<ArrayLike<{ transcript: string }>>;
};

type SpeechRecognizer = {
  lang: string;
  onresult: ((event: SpeechResult) => void) | null;
  onerror: (() => void) | null;
  onend: (() => void) | null;
  start: () => void;
  stop: () => void;
};

type SpeechWindow = Window & {
  SpeechRecognition?: new () => SpeechRecognizer;
  webkitSpeechRecognition?: new () => SpeechRecognizer;
};

export default function MediaTools({
  onInsert,
  latestAnswer
}: Props) {
  const fileInput = useRef<HTMLInputElement>(null);
  const cameraInput = useRef<HTMLInputElement>(null);
  const recognizer = useRef<SpeechRecognizer | null>(null);

  const [busy, setBusy] = useState(false);
  const [listening, setListening] = useState(false);
  const [speaking, setSpeaking] = useState(false);
  const [message, setMessage] = useState("");

  async function upload(
    event: ChangeEvent<HTMLInputElement>,
    camera = false
  ) {
    const file = event.target.files?.[0];
    if (!file) return;

    event.target.value = "";
    setMessage("");

    if (file.size > 8 * 1024 * 1024) {
      setMessage("Maximum file size is 8 MB.");
      return;
    }

    const isImage = file.type.startsWith("image/") ||
      /\.(png|jpe?g|webp)$/i.test(file.name);

    const data = new FormData();
    data.append("file", file);

    setBusy(true);

    try {
      const response = await fetch(
        isImage ? "/api/media/vision" : "/api/media/extract",
        {
          method: "POST",
          credentials: "same-origin",
          body: data
        }
      );

      const result = await response.json();

      if (!response.ok) {
        throw new Error(
          typeof result.detail === "string"
            ? result.detail
            : "Unable to process file."
        );
      }

      const extracted = isImage
        ? result.description
        : result.text;

      const context = isImage
        ? `Image analysis from ${file.name}:\n${extracted}`
        : `Document ${file.name}:\n${extracted}`;

      onInsert(context);

      setMessage(
        camera
          ? "Photo analyzed. Add your question and send."
          : "File processed. Add your question and send."
      );

    } catch (error) {
      setMessage(
        error instanceof Error
          ? error.message
          : "File upload failed."
      );
    } finally {
      setBusy(false);
    }
  }

  function toggleMic() {
    if (listening) {
      recognizer.current?.stop();
      setListening(false);
      return;
    }

    const browser = window as SpeechWindow;
    const Constructor =
      browser.SpeechRecognition ||
      browser.webkitSpeechRecognition;

    if (!Constructor) {
      setMessage(
        "Speech recognition is unavailable in this browser. " +
        "Try a compatible browser or use the keyboard."
      );
      return;
    }

    const recognition = new Constructor();
    recognition.lang = "en-US";

    recognition.onresult = event => {
      const transcript = Array.from(event.results)
        .map(result => result[0]?.transcript || "")
        .join(" ");

      if (transcript.trim()) {
        onInsert(transcript.trim());
      }
    };

    recognition.onerror = () => {
      setListening(false);
      setMessage("Microphone recognition failed or permission was denied.");
    };

    recognition.onend = () => setListening(false);

    recognizer.current = recognition;

    try {
      recognition.start();
      setListening(true);
      setMessage("Listening...");
    } catch {
      setMessage("Unable to start microphone.");
    }
  }

  function toggleSpeech() {
    if (!("speechSynthesis" in window)) {
      setMessage("Spoken responses are unavailable in this browser.");
      return;
    }

    if (speaking) {
      window.speechSynthesis.cancel();
      setSpeaking(false);
      return;
    }

    if (!latestAnswer.trim()) {
      setMessage("Ask Veltrix AI a question first.");
      return;
    }

    window.speechSynthesis.cancel();

    const utterance = new SpeechSynthesisUtterance(
      latestAnswer.slice(0, 10000)
    );

    utterance.rate = 1;
    utterance.onend = () => setSpeaking(false);
    utterance.onerror = () => setSpeaking(false);

    window.speechSynthesis.speak(utterance);
    setSpeaking(true);
  }

  async function exportAnswer() {
    if (!latestAnswer.trim()) {
      setMessage("There is no AI answer to export yet.");
      return;
    }

    const format = window.prompt(
      "Export format: pdf, docx, xlsx or txt",
      "pdf"
    )?.trim().toLowerCase();

    if (!format) return;

    if (!["pdf", "docx", "xlsx", "txt"].includes(format)) {
      setMessage("Choose pdf, docx, xlsx or txt.");
      return;
    }

    setBusy(true);

    try {
      const response = await fetch("/api/media/export", {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          text: latestAnswer,
          format
        })
      });

      if (!response.ok) {
        throw new Error("Could not generate the file.");
      }

      const blob = await response.blob();
      const url = URL.createObjectURL(blob);

      const link = document.createElement("a");
      link.href = url;
      link.download = `veltrix-report.${format}`;
      link.click();

      setTimeout(() => URL.revokeObjectURL(url), 1000);
      setMessage("Report generated.");

    } catch (error) {
      setMessage(
        error instanceof Error
          ? error.message
          : "Export failed."
      );
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="veltrix-media">
      <input
        ref={fileInput}
        type="file"
        hidden
        accept=".pdf,.docx,.xlsx,.txt,.csv,.png,.jpg,.jpeg,.webp"
        onChange={event => upload(event)}
      />

      <input
        ref={cameraInput}
        type="file"
        hidden
        accept="image/*"
        capture="environment"
        onChange={event => upload(event, true)}
      />

      <div className="veltrix-media-actions">
        <button
          type="button"
          title="Upload document or picture"
          onClick={() => fileInput.current?.click()}
          disabled={busy}
        >
          <Paperclip size={17}/> Attach
        </button>

        <button
          type="button"
          title="Take a picture"
          onClick={() => cameraInput.current?.click()}
          disabled={busy}
        >
          <Camera size={17}/> Camera
        </button>

        <button
          type="button"
          title="Dictate your question"
          onClick={toggleMic}
          disabled={busy}
          aria-pressed={listening}
        >
          {listening
            ? <Square size={17}/>
            : <Mic size={17}/>}
          {listening ? "Stop" : "Voice"}
        </button>

        <button
          type="button"
          title="Read AI answer aloud"
          onClick={toggleSpeech}
        >
          {speaking
            ? <VolumeX size={17}/>
            : <Volume2 size={17}/>}
          {speaking ? "Stop voice" : "Listen"}
        </button>

        <button
          type="button"
          title="Download AI response"
          onClick={exportAnswer}
          disabled={busy}
        >
          <Download size={17}/> Export
        </button>
      </div>

      {busy && (
        <p className="veltrix-media-status">
          <LoaderCircle size={14}/> Processing...
        </p>
      )}

      {message && (
        <p className="veltrix-media-status" role="status">
          {message}
        </p>
      )}
    </div>
  );
}
TSX

cat >> frontend/src/styles.css <<'CSS'

/* Veltrix AI multimedia tools */
.veltrix-media {
  margin: 10px 0 4px;
}

.veltrix-media-actions {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 6px;
}

.veltrix-media-actions button {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: 9px;
  color: var(--text);
  font-size: 11px;
  padding: 8px 10px;
}

.veltrix-media-actions button:hover {
  border-color: var(--accent);
  color: var(--accent);
}

.veltrix-media-actions button:disabled {
  opacity: .5;
}

.veltrix-media-status {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 11px;
  color: var(--muted);
  margin: 8px 0;
}

@media (max-width: 600px) {
  .veltrix-media-actions {
    gap: 4px;
  }
  .veltrix-media-actions button {
    font-size: 10px;
    padding: 8px;
  }
}
CSS

python3 - <<'PY'
from pathlib import Path

p = Path("frontend/src/App.tsx")
source = p.read_text()

statement = 'import MediaTools from "./MediaTools";'
if statement not in source:
    anchor = 'import "./styles.css";'
    if anchor not in source:
        raise SystemExit("App styles import not found.")
    source = source.replace(
        anchor,
        anchor + "\n" + statement,
        1
    )

if "<MediaTools" not in source:
    start = source.find('<form className="composer"')
    if start < 0:
        raise SystemExit("Chat composer not found.")

    end = source.find("</textarea>", start)
    if end < 0:
        raise SystemExit("Composer text area not found.")

    end += len("</textarea>")

    toolbar = '''
                <MediaTools
                  latestAnswer={
                    [...messages]
                      .reverse()
                      .find(m => m.role === "assistant")
                      ?.content || ""
                  }
                  onInsert={text => {
                    setInput(previous =>
                      previous.trim()
                        ? previous + "\\n\\n" + text
                        : text
                    );
                  }}
                />
'''

    source = source[:end] + toolbar + source[end:]

p.write_text(source)
print("Media toolbar connected to the chat composer.")
PY

echo ""
echo "===== VERIFY PYTHON ====="

backend/.venv/bin/python -m py_compile \
  backend/main.py \
  backend/media_routes.py

echo "PASS: Python syntax"

echo ""
echo "===== VERIFY REACT ====="

(
  cd frontend
  npm run build
)

echo ""
echo "VELTRIX MULTIMEDIA UPGRADE COMPLETE"
