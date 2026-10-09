
import { useRef, useState } from 'react';
import {
  FileText, Upload, X, Send, Download,
  Loader2, CheckCircle2, AlertCircle, Paperclip
} from 'lucide-react';
import './document-assistant.css';

type ExtractedDocument = {
  filename: string;
  text: string;
  truncated: boolean;
};

export default function DocumentAssistant() {
  const [open, setOpen] = useState(false);
  const [document, setDocument] =
    useState<ExtractedDocument | null>(null);
  const [question, setQuestion] = useState('');
  const [answer, setAnswer] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [dragging, setDragging] = useState(false);

  const inputRef = useRef<HTMLInputElement>(null);

  const formats = ['pdf', 'docx', 'xlsx', 'csv', 'txt'];

  async function parseError(response: Response): Promise<string> {
    try {
      const body = await response.json();
      return typeof body.detail === 'string'
        ? body.detail
        : `Request failed (${response.status}).`;
    } catch {
      return `Request failed (${response.status}).`;
    }
  }

  async function uploadFile(file?: File) {
    if (!file || busy) return;

    setError('');
    setAnswer('');
    setDocument(null);

    const extension = file.name.split('.').pop()?.toLowerCase();

    if (!extension || !formats.includes(extension)) {
      setError('Choose a PDF, Word, Excel, CSV or TXT document.');
      return;
    }

    if (file.size > 8 * 1024 * 1024) {
      setError('Maximum document size is 8 MB.');
      return;
    }

    setBusy(true);

    try {
      const form = new FormData();
      form.append('file', file);

      const response = await fetch('/api/media/extract', {
        method: 'POST',
        credentials: 'same-origin',
        body: form
      });

      if (!response.ok) {
        throw new Error(await parseError(response));
      }

      const data = await response.json() as ExtractedDocument;

      if (!data.text?.trim()) {
        throw new Error('No readable text was found.');
      }

      setDocument(data);

    } catch (cause) {
      setError(
        cause instanceof Error
          ? cause.message
          : 'Document upload failed.'
      );
    } finally {
      setBusy(false);
      if (inputRef.current) {
        inputRef.current.value = '';
      }
    }
  }

  async function askDocument() {
    if (!document || !question.trim() || busy) return;

    setBusy(true);
    setError('');
    setAnswer('');

    try {
      const context = document.text.slice(0, 10500);

      const prompt =
        'Answer the following question using the provided document. ' +
        'Clearly say when information is missing. ' +
        'Do not invent facts.\n\n' +
        'DOCUMENT: ' + document.filename + '\n\n' +
        context + '\n\n' +
        'QUESTION: ' + question.trim();

      const response = await fetch('/api/chat', {
        method: 'POST',
        credentials: 'same-origin',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          mode: 'personal',
          model_mode: 'smart',
          messages: [
            { role: 'user', content: prompt }
          ]
        })
      });

      if (!response.ok) {
        throw new Error(await parseError(response));
      }

      const data = await response.json();

      if (!data.reply) {
        throw new Error('The AI returned an empty answer.');
      }

      setAnswer(data.reply);

    } catch (cause) {
      setError(
        cause instanceof Error
          ? cause.message
          : 'Document analysis failed.'
      );
    } finally {
      setBusy(false);
    }
  }

  async function exportAnswer(
    format: 'pdf' | 'docx' | 'xlsx' | 'txt'
  ) {
    if (!answer || busy) return;

    setBusy(true);
    setError('');

    try {
      const response = await fetch('/api/media/export', {
        method: 'POST',
        credentials: 'same-origin',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          text: answer,
          format
        })
      });

      if (!response.ok) {
        throw new Error(await parseError(response));
      }

      const blob = await response.blob();
      const url = URL.createObjectURL(blob);
      const link = window.document.createElement('a');

      link.href = url;
      link.download = `veltrix-document-report.${format}`;
      window.document.body.appendChild(link);
      link.click();
      link.remove();

      window.setTimeout(() => URL.revokeObjectURL(url), 1000);

    } catch (cause) {
      setError(
        cause instanceof Error
          ? cause.message
          : 'Report export failed.'
      );
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <button
        type="button"
        className="vd-launcher"
        onClick={() => setOpen(true)}
        title="Document Intelligence"
      >
        <Paperclip size={18} />
        <span>Documents</span>
      </button>

      {open && (
        <div
          className="vd-overlay"
          onMouseDown={event => {
            if (event.target === event.currentTarget) {
              setOpen(false);
            }
          }}
        >
          <section
            className="vd-panel"
            role="dialog"
            aria-modal="true"
            aria-label="Veltrix Document Intelligence"
          >
            <header className="vd-header">
              <div>
                <small>VELTRIX AI</small>
                <h2>Document Intelligence</h2>
                <p>Upload, understand and analyse your documents.</p>
              </div>

              <button
                className="vd-close"
                onClick={() => setOpen(false)}
                aria-label="Close"
              >
                <X size={21} />
              </button>
            </header>

            <div className="vd-body">
              <input
                ref={inputRef}
                type="file"
                accept=".pdf,.docx,.xlsx,.csv,.txt"
                hidden
                onChange={event =>
                  void uploadFile(event.target.files?.[0])
                }
              />

              <div
                className={`vd-drop ${dragging ? 'vd-dragging' : ''}`}
                onDragOver={event => {
                  event.preventDefault();
                  setDragging(true);
                }}
                onDragLeave={() => setDragging(false)}
                onDrop={event => {
                  event.preventDefault();
                  setDragging(false);
                  void uploadFile(event.dataTransfer.files[0]);
                }}
              >
                <div className="vd-drop-icon">
                  <Upload size={25} />
                </div>

                <strong>Upload your document</strong>
                <p>PDF, Word, Excel, CSV or TXT · Up to 8 MB</p>

                <button
                  type="button"
                  disabled={busy}
                  onClick={() => inputRef.current?.click()}
                >
                  <Paperclip size={16} />
                  Choose document
                </button>
              </div>

              {busy && (
                <div className="vd-status">
                  <Loader2 className="vd-spin" size={18} />
                  Processing your request…
                </div>
              )}

              {error && (
                <div className="vd-error" role="alert">
                  <AlertCircle size={18} />
                  <span>{error}</span>
                </div>
              )}

              {document && (
                <div className="vd-document">
                  <div className="vd-document-title">
                    <FileText size={21} />
                    <div>
                      <strong>{document.filename}</strong>
                      <p>Document text extracted successfully</p>
                    </div>
                    <CheckCircle2 size={19} />
                  </div>

                  {document.truncated && (
                    <p className="vd-warning">
                      This document was shortened to fit the
                      current processing limit.
                    </p>
                  )}

                  <details>
                    <summary>Preview extracted text</summary>
                    <pre>{document.text.slice(0, 3000)}</pre>
                  </details>

                  <div className="vd-question">
                    <label htmlFor="vd-question">
                      Ask Veltrix AI about this document
                    </label>

                    <textarea
                      id="vd-question"
                      value={question}
                      onChange={event => setQuestion(event.target.value)}
                      placeholder="e.g. Summarize this document and highlight the key findings"
                      rows={3}
                    />

                    <button
                      type="button"
                      onClick={() => void askDocument()}
                      disabled={busy || !question.trim()}
                    >
                      <Send size={16} />
                      Analyse document
                    </button>
                  </div>
                </div>
              )}

              {answer && (
                <div className="vd-answer">
                  <h3>Veltrix AI Analysis</h3>
                  <div className="vd-answer-text">{answer}</div>

                  <div className="vd-export">
                    <span>
                      <Download size={15} />
                      Export analysis:
                    </span>

                    {(['pdf', 'docx', 'xlsx', 'txt'] as const)
                      .map(format => (
                        <button
                          type="button"
                          key={format}
                          disabled={busy}
                          onClick={() => void exportAnswer(format)}
                        >
                          {format.toUpperCase()}
                        </button>
                      ))}
                  </div>
                </div>
              )}

              <p className="vd-note">
                Files are processed by your configured Veltrix
                backend. Extracted text is submitted to your
                configured AI provider for analysis. Scanned PDFs
                without selectable text currently require OCR.
              </p>
            </div>
          </section>
        </div>
      )}
    </>
  );
}
