# Shipping a take to EdAtor Cloud

roll's job is capture; the pipeline lives at **edator.stumason.dev** (EdAtor Cloud).
Ship a finished pack and ~a few minutes later the take is perceived — verbatim
transcript on the shared clock, screen-text index, beats — and semantically
searchable in the library. The cut lands there next (edator-cloud M4).

## Today: `scripts/roll-ship`

```bash
# one-time: mint a device token (cached at ~/.config/roll/edator-token)
EDATOR_EMAIL=you@example.com EDATOR_PASSWORD=... scripts/roll-ship

# then it's one command per take:
scripts/roll-ship                                   # newest rec-* in ~/Movies/roll
scripts/roll-ship ~/Movies/roll/rec-1782...         # a specific pack
scripts/roll-ship --title "The confession"          # with a title
```

Needs `jq` (`brew install jq`). Uploads go **directly to R2 via presigned URLs** —
no proxy in the path, no size cap (a 193MB pack ships fine; the old crunch /pack
route died at 100MB).

What it does (the documented contract — `docs/PACK-API.md` in edator-cloud):

1. `POST /api/v1/packs` with the pack's `manifest.json` → the server derives the
   file list and returns one presigned PUT URL per declared file.
2. `PUT` each file straight to R2.
3. `POST /packs/{id}/complete` → the server HEAD-verifies every object, then
   queues perception.
4. Polls until `ready` (prints per-stage timings) or `failed` (prints the error).

Re-running after a failure is safe — it creates a fresh pack for the same take.

## Next: native (roll#26)

The script is the interim. The native step is a Rust `ship_pack` command
(streaming progress events), the token in the Keychain, and a **Ship** button +
status chip in the library UI — spec in issue #26.
