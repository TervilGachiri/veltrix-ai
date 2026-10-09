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
