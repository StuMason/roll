import { useEffect, useRef, useState } from "react";

export interface Opt {
  value: number | null;
  label: string;
  hint?: string;
}

interface Props {
  value: number | null;
  options: Opt[];
  onChange: (v: number | null) => void;
  disabled?: boolean;
  icon?: React.ReactNode;
}

export default function Dropdown({ value, options, onChange, disabled, icon }: Props) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const cur = options.find((o) => o.value === value);

  useEffect(() => {
    if (!open) return;
    const onDoc = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    const onEsc = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    document.addEventListener("mousedown", onDoc);
    document.addEventListener("keydown", onEsc);
    return () => {
      document.removeEventListener("mousedown", onDoc);
      document.removeEventListener("keydown", onEsc);
    };
  }, [open]);

  return (
    <div className={`dd${open ? " open" : ""}`} ref={ref}>
        <button
          type="button"
          className="dd-trigger"
          disabled={disabled}
          onClick={() => setOpen((o) => !o)}
        >
          {icon && <span className="dd-icon">{icon}</span>}
          <span className="dd-value">{cur ? cur.label : "—"}</span>
          <svg className="dd-chevron" viewBox="0 0 12 12" width="12" height="12">
            <path d="M2.5 4.5L6 8l3.5-3.5" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </button>
        {open && (
          <ul className="dd-menu" role="listbox">
            {options.map((o) => (
              <li
                key={String(o.value)}
                role="option"
                aria-selected={o.value === value}
                className={o.value === value ? "sel" : ""}
                onClick={() => {
                  onChange(o.value);
                  setOpen(false);
                }}
              >
                <span className="dd-opt-label">{o.label}</span>
                {o.hint && <span className="dd-opt-hint">{o.hint}</span>}
                {o.value === value && (
                  <svg className="dd-check" viewBox="0 0 12 12" width="12" height="12">
                    <path d="M2.5 6.5L5 9l4.5-5.5" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
                  </svg>
                )}
              </li>
            ))}
          </ul>
        )}
    </div>
  );
}
