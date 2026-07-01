# Contributing to roll

Thanks for taking a look. `roll` is the native macOS capture front-end for
[edator](https://github.com/StuMason/edator) — it records a **pack** (screen +
camera + mic + system audio + input/semantic telemetry on one shared clock) that
downstream agents query instead of watch.

The single most important thing to protect is the **capture contract**: the shape
of a pack, enforced by [`schemas/pack.schema.json`](schemas/pack.schema.json).
Everything upstream of the pack is capture; everything downstream
([crunch](https://github.com/StuMason/crunch) → edator) is an agent reading facts.
If a change alters what lands in a pack, the schema changes with it — in the same PR.

## Project shape

| Layer | Where | What |
|---|---|---|
| Native engine | `capture-swift/` | Swift sidecar (`roll-capture`) — owns screen/camera/mic/telemetry, streams frames & levels over stdio |
| App shell | `src-tauri/` | Rust/Tauri — drives the sidecar, builds packs on disk, tray + events |
| UI | `src/` | React/TS — device pickers, live preview, VU meter, pack inspector |
| Contract | `schemas/pack.schema.json` | the hard boundary between capture and agents |

## Building locally

Requires macOS 13+, the Xcode toolchain, Node, and Rust.

```bash
cd capture-swift && swift build -c release      # native engine (built separately)
.build/release/roll-capture --list              # smoke test: displays / cameras / mics
cd .. && npm install && npm run tauri dev        # run the app
```

First run prompts for **Screen Recording, Camera, Microphone, and Accessibility** —
all four are needed for full capture. Functional capture can only be verified on a
real Mac with those permissions granted; the CI Mac runner compile-validates but
does not exercise capture.

## Making changes

`main` is **PR-gated** — you cannot push to it directly (this applies to
maintainers too).

1. Branch: `git checkout -b feat/your-thing` (or `fix/…`, `chore/…`, `docs/…`)
2. Make the change. If it touches the pack, update `schemas/pack.schema.json` too.
3. Keep it green locally:
   ```bash
   npm run build                                             # frontend
   cargo fmt   --manifest-path src-tauri/Cargo.toml          # rustfmt (CI enforces --check)
   cargo clippy --manifest-path src-tauri/Cargo.toml -- -D warnings
   cargo test  --manifest-path src-tauri/Cargo.toml
   ```
4. Commit with [conventional commits](https://www.conventionalcommits.org/):
   `feat:`, `fix:`, `chore:`, `docs:`, `ci:`, scoped where it helps
   (`feat(capture): …`, `fix(inspector): …`).
5. Open a PR against `main`. The **`ci-linux`** check (rustfmt + clippy `-D warnings`
   + tests + frontend build) must pass before it can merge. Relevant PRs also get a
   full macOS build via the `app-mac` workflow as a pre-merge signal.

## Ground rules

- **Capture is Rubbish-In-Rubbish-Out.** Correctness of what's recorded beats
  cleverness downstream. Inference belongs in crunch/edator, not the recorder.
- **Privacy is non-negotiable.** Typed text and clipboard are **never** captured
  while macOS secure input is active (password fields), and concealed/transient
  clipboard payloads are skipped. Don't weaken this.
- **Keep the app dumb.** The Rust/React shell owns no capture logic — it drives the
  sidecar. New capture goes in the Swift engine.

## Reporting issues

- **Bugs** — open an issue with steps, macOS version, and (if capture-related) the
  offending pack's `manifest.json`.
- **Features** — describe the use case: what should a pack contain that it doesn't?
