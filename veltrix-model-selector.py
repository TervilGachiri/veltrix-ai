from pathlib import Path
from datetime import datetime
import ast
import re
import shutil
import subprocess

root = Path.cwd()
backend = root / "backend/main.py"
frontend = root / "frontend/src/App.tsx"
stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
backup = root / "backups" / f"model-selector-{stamp}"
backup.mkdir(parents=True, exist_ok=True)

shutil.copy2(backend, backup / "main.py")
shutil.copy2(frontend, backup / "App.tsx")

b = backend.read_text()
f = frontend.read_text()

try:
    # Find the Pydantic request model used by the chat endpoint.
    classes = list(re.finditer(
        r"(?m)^class (\w+)\(BaseModel\):\n"
        r"((?:^[ \t]+.*\n|^\s*\n)*)", b
    ))

    chat_class = next(
        (m for m in classes
         if "messages:" in m.group(2)
         and "mode:" in m.group(2)),
        None
    )

    if chat_class is None:
        raise ValueError(
            "Could not identify the existing chat request schema."
        )

    if "model_mode:" not in chat_class.group(2):
        position = chat_class.end()
        b = (
            b[:position]
            + "    model_mode: str = 'fast'\n"
            + b[position:]
        )

    # Only allow known local models. Never accept an
    # arbitrary model name supplied by the browser.
    anchor = '    provider = os.getenv("AI_PROVIDER", "ollama").lower()'

    routing = '''
    # Veltrix AI model selection
    model_mode = getattr(data, "model_mode", "fast")

    if model_mode not in ("fast", "smart", "auto"):
        raise HTTPException(
            status_code=400,
            detail="Invalid AI model selection."
        )

    if model_mode == "auto":
        latest_message = data.messages[-1].content.lower() if data.messages else ""
        complex_terms = (
            "code", "python", "debug", "programming",
            "analyze", "analyse", "compare", "architecture",
            "complex", "explain in detail", "mathematics",
            "business strategy", "javascript"
        )
        model_mode = (
            "smart"
            if any(term in latest_message for term in complex_terms)
            else "fast"
        )

    chosen_model = (
        "qwen3:4b"
        if model_mode == "smart"
        else "qwen3:1.7b"
    )

'''

    if "chosen_model =" not in b:
        if anchor not in b:
            raise ValueError("Ollama provider section not found.")
        b = b.replace(anchor, routing + anchor, 1)

    old_model = 'os.getenv("OLLAMA_MODEL", "qwen3:4b")'

    if '"model": chosen_model' not in b:
        if old_model in b:
            b = b.replace(old_model, "chosen_model", 1)
        else:
            match = re.search(
                r'"model"\s*:\s*os\.getenv\("OLLAMA_MODEL"[^)]*\)',
                b
            )
            if not match:
                raise ValueError("Ollama model configuration not found.")
            b = b[:match.start()] + '"model": chosen_model' + b[match.end():]

    ast.parse(b)

    # Frontend state
    state_anchor = '  const [workspace, setWorkspace] = useState<Workspace>('

    if 'const [modelMode, setModelMode]' not in f:
        if state_anchor not in f:
            raise ValueError("Frontend workspace state not found.")

        state = '''  const [modelMode, setModelMode] = useState<
    "fast" | "smart" | "auto"
  >(() => {
    const saved = stored("veltrix-model-mode", "fast");
    return ["fast", "smart", "auto"].includes(saved)
      ? saved as "fast" | "smart" | "auto"
      : "fast";
  });

  useEffect(() => {
    localStorage.setItem(
      "veltrix-model-mode",
      JSON.stringify(modelMode)
    );
  }, [modelMode]);

'''
        f = f.replace(state_anchor, state + state_anchor, 1)

    # Send selected mode with chat requests
    if "model_mode: modelMode" not in f:
        anchor = 'messages: next.slice(-25),'
        if anchor not in f:
            raise ValueError("Frontend chat request not found.")
        f = f.replace(
            anchor,
            anchor + '\n          model_mode: modelMode,',
            1
        )

    # Add visible selector to Settings
    if "AI Model Selection" not in f:
        start = f.find('{page === "settings" && (')
        if start == -1:
            raise ValueError("Settings page not found.")

        section = f.find(
            '<section className="setting-card">',
            start
        )
        if section == -1:
            raise ValueError("Settings section not found.")

        selector = '''<section className="setting-card">
              <h3><BrainCircuit size={19}/> AI Model Selection</h3>
              <p>Choose how Veltrix AI processes your questions.</p>

              <div className="theme-grid">
                {([
                  ["fast", "Fast", "Qwen3 1.7B"],
                  ["smart", "Smart", "Qwen3 4B"],
                  ["auto", "Auto", "Automatic"]
                ] as const).map(([value, label, description]) => (
                  <button
                    key={value}
                    className={modelMode === value ? "chosen" : ""}
                    onClick={() => setModelMode(value)}
                    type="button"
                    style={{
                      flexDirection: "column",
                      gap: "7px"
                    }}
                  >
                    <strong>{label}</strong>
                    <span style={{fontSize: 11}}>
                      {description}
                    </span>
                    {modelMode === value && <Check size={16}/>}
                  </button>
                ))}
              </div>

              <p className="notice">
                Fast mode prioritizes speed. Smart mode uses a larger
                model. Auto mode selects between them using simple
                task rules. Your choice applies to new messages.
              </p>
            </section>

            '''
        f = f[:section] + selector + f[section:]

    # Validate backend before saving.
    compile(b, str(backend), "exec")

    backend.write_text(b)
    frontend.write_text(f)

    # Validate frontend; revert both files on failure.
    result = subprocess.run(
        ["npm", "run", "build"],
        cwd=root / "frontend"
    )

    if result.returncode != 0:
        raise RuntimeError("Frontend build failed.")

    print()
    print("SUCCESS: Veltrix AI model selector installed.")
    print("Fast: qwen3:1.7b")
    print("Smart: qwen3:4b")
    print("Auto: task-based selection")
    print("Backup:", backup)

except Exception as error:
    shutil.copy2(backup / "main.py", backend)
    shutil.copy2(backup / "App.tsx", frontend)
    print("Upgrade not applied:", error)
    print("Original files restored.")
    raise SystemExit(1)
