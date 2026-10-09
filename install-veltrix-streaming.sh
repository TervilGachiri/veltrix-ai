#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

echo "======================================"
echo " VELTRIX AI — LIVE STREAMING"
echo "======================================"

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="backups/streaming-$STAMP"
mkdir -p "$BACKUP"

cp frontend/src/main.tsx "$BACKUP/main.tsx"

for FILE in StreamingChat.tsx streaming-chat.css; do
  if [ -f "frontend/src/$FILE" ]; then
    cp "frontend/src/$FILE" "$BACKUP/$FILE"
  fi
done

echo "Backup created: $BACKUP"

cat > frontend/src/StreamingChat.tsx <<'TSX'
import { useEffect, useRef, useState } from 'react';
import {
  Zap,
  X,
  ArrowUp,
  Square,
  Loader2,
  Sparkles,
  Trash2
} from 'lucide-react';

import './streaming-chat.css';

type Message = {
  role: 'user' | 'assistant';
  content: string;
};

type StreamEvent = {
  type: 'delta' | 'done' | 'error';
  text?: string;
  detail?: string;
};

export default function StreamingChat() {
  const [open, setOpen] = useState(false);
  const [messages, setMessages] = useState<Message[]>([]);
  const [input, setInput] = useState('');
  const [model, setModel] =
    useState<'fast' | 'smart' | 'auto'>('auto');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const controller = useRef<AbortController | null>(null);
  const scrollEnd = useRef<HTMLDivElement>(null);

  useEffect(() => {
    scrollEnd.current?.scrollIntoView({
      behavior: 'smooth'
    });
  }, [messages]);

  useEffect(() => {
    return () => controller.current?.abort();
  }, []);

  function stop() {
    controller.current?.abort();
    controller.current = null;
    setBusy(false);
  }

  async function send() {
    const question = input.trim();

    if (!question || busy) return;

    const previous = messages.filter(
      m => m.content.trim().length > 0
    );

    const userMessage: Message = {
      role: 'user',
      content: question
    };

    const history = [...previous, userMessage];

    setMessages([
      ...history,
      { role: 'assistant', content: '' }
    ]);

    setInput('');
    setError('');
    setBusy(true);

    const abort = new AbortController();
    controller.current = abort;

    let answer = '';
    let completed = false;

    function appendText(text: string) {
      answer += text;

      setMessages(current => {
        const next = [...current];

        if (
          next.length > 0 &&
          next[next.length - 1].role === 'assistant'
        ) {
          next[next.length - 1] = {
            role: 'assistant',
            content: answer
          };
        }

        return next;
      });
    }

    function handleEvent(event: StreamEvent) {
      if (event.type === 'delta' && event.text) {
        appendText(event.text);
      }

      if (event.type === 'done') {
        completed = true;
      }

      if (event.type === 'error') {
        throw new Error(
          event.detail || 'AI streaming failed.'
        );
      }
    }

    try {
      const response = await fetch('/api/v2/chat/stream', {
        method: 'POST',
        credentials: 'same-origin',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          model_mode: model,
          mode: 'personal',
          messages: history.slice(-25)
        }),
        signal: abort.signal
      });

      if (!response.ok) {
        let detail = `HTTP ${response.status}`;

        try {
          const body = await response.json();
          detail = body.detail || detail;
        } catch {
          // Preserve HTTP error.
        }

        throw new Error(detail);
      }

      if (!response.body) {
        throw new Error(
          'This browser did not provide a readable response stream.'
        );
      }

      const reader = response.body.getReader();
      const decoder = new TextDecoder();

      let buffer = '';

      while (true) {
        const result = await reader.read();

        if (result.done) break;

        buffer += decoder.decode(
          result.value,
          { stream: true }
        );

        let boundary = buffer.indexOf('\n');

        while (boundary !== -1) {
          const line = buffer.slice(0, boundary).trim();
          buffer = buffer.slice(boundary + 1);

          if (line) {
            handleEvent(JSON.parse(line) as StreamEvent);
          }

          boundary = buffer.indexOf('\n');
        }
      }

      buffer += decoder.decode();

      if (buffer.trim()) {
        handleEvent(
          JSON.parse(buffer.trim()) as StreamEvent
        );
      }

      if (!completed && !abort.signal.aborted) {
        throw new Error(
          'The AI response ended before completion.'
        );
      }

    } catch (cause) {
      if (!abort.signal.aborted) {
        setError(
          cause instanceof Error
            ? cause.message
            : 'Unable to generate an answer.'
        );
      }
    } finally {
      if (controller.current === abort) {
        controller.current = null;
        setBusy(false);
      }
    }
  }

  return (
    <>
      <button
        className="vs-launch"
        onClick={() => setOpen(true)}
        title="Live AI Streaming"
      >
        <Zap size={18} />
        Live AI
      </button>

      {open && (
        <div
          className="vs-overlay"
          onMouseDown={event => {
            if (event.target === event.currentTarget) {
              setOpen(false);
            }
          }}
        >
          <section
            className="vs-panel"
            role="dialog"
            aria-modal="true"
            aria-label="Veltrix AI Streaming"
          >
            <header className="vs-header">
              <div className="vs-heading">
                <div className="vs-mark">
                  <Zap size={20} />
                </div>
                <div>
                  <h2>Veltrix Live AI</h2>
                  <small>Real-time AI responses</small>
                </div>
              </div>

              <div className="vs-header-actions">
                <select
                  aria-label="AI model"
                  value={model}
                  disabled={busy}
                  onChange={e => setModel(
                    e.target.value as 'fast' | 'smart' | 'auto'
                  )}
                >
                  <option value="auto">Auto</option>
                  <option value="fast">Fast</option>
                  <option value="smart">Smart</option>
                </select>

                <button
                  title="Clear session"
                  aria-label="Clear session"
                  onClick={() => {
                    stop();
                    setMessages([]);
                    setError('');
                  }}
                >
                  <Trash2 size={17} />
                </button>

                <button
                  aria-label="Close Live AI"
                  onClick={() => setOpen(false)}
                >
                  <X size={20} />
                </button>
              </div>
            </header>

            <div className="vs-messages">
              {messages.length === 0 && (
                <div className="vs-welcome">
                  <Sparkles size={34} />
                  <h3>Intelligence, as it happens.</h3>
                  <p>
                    Ask Veltrix AI anything and watch
                    the response appear live.
                  </p>
                </div>
              )}

              {messages.map((message, index) => (
                <div
                  key={index}
                  className={`vs-message ${message.role}`}
                >
                  <strong>
                    {message.role === 'user'
                      ? 'You'
                      : 'Veltrix AI'}
                  </strong>

                  <div className="vs-content">
                    {message.content || (
                      busy ? (
                        <span className="vs-thinking">
                          <Loader2
                            size={15}
                            className="vs-spin"
                          />
                          Generating…
                        </span>
                      ) : 'No response received.' 
                    )}
                  </div>
                </div>
              ))}

              {error && (
                <div className="vs-error" role="alert">
                  {error}
                </div>
              )}

              <div ref={scrollEnd} />
            </div>

            <form
              className="vs-compose"
              onSubmit={e => {
                e.preventDefault();
                void send();
              }}
            >
              <textarea
                value={input}
                onChange={e => setInput(e.target.value)}
                placeholder="Message Veltrix AI..."
                rows={2}
                disabled={busy}
                onKeyDown={e => {
                  if (e.key === 'Enter' && !e.shiftKey) {
                    e.preventDefault();
                    void send();
                  }
                }}
              />

              <div className="vs-controls">
                <span>
                  Enter to send · Shift+Enter for newline
                </span>

                {busy ? (
                  <button
                    type="button"
                    className="vs-stop"
                    onClick={stop}
                  >
                    <Square size={15} />
                    Stop
                  </button>
                ) : (
                  <button
                    type="submit"
                    className="vs-send"
                    disabled={!input.trim()}
                  >
                    <ArrowUp size={18} />
                    Send
                  </button>
                )}
              </div>
            </form>
          </section>
        </div>
      )}
    </>
  );
}
TSX

cat > frontend/src/streaming-chat.css <<'CSS'
.vs-launch{
  position:fixed;
  right:20px;
  bottom:77px;
  z-index:89;
  display:flex;
  align-items:center;
  gap:9px;
  padding:13px 18px;
  border:0;
  border-radius:15px;
  background:#242e63;
  color:white;
  font-weight:700;
  box-shadow:0 8px 26px #19245055;
}
.vs-overlay{
  position:fixed;
  inset:0;
  z-index:110;
  display:flex;
  justify-content:center;
  align-items:center;
  background:#070a1cb5;
  padding:16px;
}
.vs-panel{
  width:min(850px,100%);
  height:min(750px,92vh);
  display:flex;
  flex-direction:column;
  background:var(--panel,#fff);
  color:var(--text,#19233d);
  border:1px solid var(--line,#ddd);
  border-radius:22px;
  overflow:hidden;
  box-shadow:0 25px 90px #0005;
}
.vs-header{
  display:flex;
  justify-content:space-between;
  align-items:center;
  gap:12px;
  padding:18px 22px;
  border-bottom:1px solid var(--line,#ddd);
}
.vs-heading{
  display:flex;
  align-items:center;
  gap:11px;
}
.vs-heading h2{
  font-size:17px;
  margin:0 0 5px;
}
.vs-heading small{
  color:var(--muted,#888);
}
.vs-mark{
  padding:11px;
  background:#ecebff;
  color:#5e57da;
  border-radius:12px;
}
.vs-header-actions{
  display:flex;
  align-items:center;
  gap:8px;
}
.vs-header-actions button,
.vs-header-actions select{
  border:1px solid var(--line,#ddd);
  border-radius:9px;
  background:var(--bg,#f7f8fc);
  color:var(--text,#19233d);
  padding:9px;
}
.vs-messages{
  flex:1;
  overflow-y:auto;
  padding:25px;
}
.vs-welcome{
  text-align:center;
  margin:80px auto;
  max-width:380px;
}
.vs-welcome svg{
  color:#7770eb;
}
.vs-welcome h3{
  margin:14px 0 8px;
}
.vs-welcome p{
  color:var(--muted,#888);
  line-height:1.7;
}
.vs-message{
  max-width:88%;
  margin:0 0 25px;
}
.vs-message.user{
  margin-left:auto;
  padding:15px;
  background:var(--accent-soft,#eeecff);
  border-radius:15px;
}
.vs-message strong{
  display:block;
  margin-bottom:8px;
  font-size:12px;
}
.vs-content{
  white-space:pre-wrap;
  overflow-wrap:anywhere;
  line-height:1.8;
  font-size:14px;
}
.vs-thinking{
  display:flex;
  gap:9px;
  align-items:center;
  color:var(--muted,#888);
}
.vs-error{
  padding:12px;
  background:#ffe9ed;
  border-radius:10px;
  color:#bd4053;
  font-size:13px;
}
.vs-compose{
  border-top:1px solid var(--line,#ddd);
  padding:17px 22px;
}
.vs-compose textarea{
  width:100%;
  min-height:75px;
  resize:vertical;
  border:1px solid var(--line,#ddd);
  border-radius:12px;
  padding:13px;
  color:var(--text,#19233d);
  background:var(--bg,#f8f9fc);
}
.vs-controls{
  display:flex;
  justify-content:space-between;
  align-items:center;
  gap:10px;
  margin-top:12px;
}
.vs-controls span{
  color:var(--muted,#888);
  font-size:11px;
}
.vs-controls button{
  display:flex;
  align-items:center;
  gap:8px;
  border:0;
  border-radius:10px;
  padding:10px 16px;
  color:white;
  font-weight:700;
}
.vs-send{
  background:#6661e9;
}
.vs-stop{
  background:#c64c5c;
}
.vs-send:disabled{
  opacity:.45;
}
.vs-spin{
  animation:vs-rotate 1s linear infinite;
}
@keyframes vs-rotate{
  to{transform:rotate(360deg)}
}
@media(max-width:600px){
  .vs-launch{
    bottom:68px;
    right:12px;
    padding:11px 13px;
  }
  .vs-header{
    padding:12px;
  }
  .vs-header-actions{
    gap:4px;
  }
  .vs-messages{
    padding:15px;
  }
  .vs-compose{
    padding:12px;
  }
}
CSS

echo ""
echo "===== CONNECTING LIVE AI INTERFACE ====="

python3 - <<'PY'
from pathlib import Path
import re

path = Path("frontend/src/main.tsx")
code = path.read_text()

if "StreamingChat" not in code:
    code = (
        "import StreamingChat from './StreamingChat';\n"
        + code
    )

    # Add beside the existing App without replacing it.
    code, count = re.subn(
        r"<App\s*/>",
        "<><App /><StreamingChat /></>",
        code,
        count=1
    )

    if count != 1:
        raise SystemExit(
            "Cannot safely locate App root. "
            "Frontend entry file was not changed."
        )

    path.write_text(code)
    print("Live AI connected to React root.")
else:
    print("Live AI already connected.")
PY

echo ""
echo "===== BUILD VERIFICATION ====="

if (cd frontend && npm run build); then
  echo "React build PASSED."
else
  echo "Build failed. Restoring previous files."

  cp "$BACKUP/main.tsx" frontend/src/main.tsx

  for FILE in StreamingChat.tsx streaming-chat.css; do
    if [ -f "$BACKUP/$FILE" ]; then
      cp "$BACKUP/$FILE" "frontend/src/$FILE"
    else
      rm -f "frontend/src/$FILE"
    fi
  done

  exit 1
fi

echo ""
echo "===== VERIFY STREAMING API ====="

curl -sS \
  -o /dev/null \
  -w "Backend HTTP %{http_code}\n" \
  http://127.0.0.1:8001/api/health

echo ""
echo "======================================"
echo " VELTRIX LIVE AI INTERFACE INSTALLED"
echo "======================================"
echo "Streaming panel: Added"
echo "Stop Generation: Added"
echo "Fast/Smart/Auto: Available"
echo "Document Intelligence: Unchanged"
echo "Existing conversations: Unchanged"
echo "Login: Unchanged"
echo "Backup: $BACKUP"
echo "======================================"
