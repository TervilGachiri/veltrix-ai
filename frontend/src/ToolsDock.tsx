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
