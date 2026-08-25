---
name: track
description: Record a dated obligation — cert renewals, secret rotations, domain expiries — so Houston's Tracked bell reminds you before it's due. Trigger on "track …", "what am I tracking", "mark … done", "stop tracking …".
---

# /track — Track a dated obligation

Triggered when the user says **"track ___"** (e.g. "track that the Hierarch
client secret expires in 24 months"), asks **"what am I tracking?"**, reports
something **done / renewed / rotated**, or says **"stop tracking ___"**.

## The store

Every operation reads and writes one file:

```
~/Library/Application Support/Houston/tracked.json
```

A JSON **array** of items. Houston polls this file live: its sidebar footer
bell lists every active item and badges the ones whose lead window has opened,
so a correct write here IS the reminder — nothing else to install.

Rules:

- **Read the existing array, modify it, write the whole thing back.** If the
  file is missing, start from `[]` (create the directory if needed). Preserve
  entries and fields you don't recognize — never regenerate the file from
  what you remember.
- Write atomically: write to a temp file in the same directory, then `mv` over
  the original.
- Done items are history — never delete them unless the user says to
  untrack/remove.

## Item schema

```json
{
  "id": "hierarch-client-secret",
  "title": "Rotate Hierarch client secret",
  "due": "2028-08-24",
  "project": "hierarch",
  "leadDays": 30,
  "notes": "Azure app registration — secret expires 24 months from 2026-08-24. Rotate in Azure Portal → App registrations → Certificates & secrets.",
  "created": "2026-08-24",
  "done": false
}
```

- `id` — unique kebab-case slug; the stable handle for done/untrack.
- `title` — imperative phrasing of what needs *doing* ("Rotate …", "Renew …"),
  not a description of the deadline.
- `due` — `YYYY-MM-DD`, required. Convert relative dates ("in 24 months",
  "next March") to absolute against today — get today with `date +%F`, never
  from memory.
- `project` — the `~/Apps/<project>` folder name when the item belongs to the
  project you're working in; omit otherwise.
- `leadDays` — how many days before `due` the reminder lights up. Pick by
  horizon: **30** for due dates over a year out, **14** for 3–12 months,
  **7** under 3 months — unless the user names a lead time.
- `notes` — what future-you needs to actually do it: where the thing lives
  (portal path, URL), the command, the account. One or two sentences.
- `repeatMonths` — optional integer for recurring obligations ("rotate every
  6 months").

## Operations

### Track — "track ___"

1. `date +%F` for today; compute `due` from the user's phrasing.
2. Read the file. If an item for the same subject already exists (match on
   meaning, not exact id), **update** its `due`/`notes` instead of adding a
   duplicate.
3. Append (or update), write back, and confirm in one line: the title, the
   absolute due date, and when the reminder will fire — e.g.
   *"Tracked — Rotate Hierarch client secret, due 2028-08-24. Houston's bell
   will flag it 30 days out."*

If the user gave no date, ask for one — an item without `due` never reminds.

### List — "what am I tracking?"

Show active items sorted soonest-first: title, due date, countdown, project.
Mention done items only if asked.

### Done — "mark ___ done", "I rotated ___"

Find the item by id or title match. If it has `repeatMonths`, advance `due`
by that many months from **today**, leave it active, and say when it next
comes due. Otherwise set `"done": true` and `"doneAt": "<today>"`.

### Untrack — "stop tracking ___", "remove ___"

Remove the entry entirely. If the match is ambiguous, list the candidates and
ask which one before deleting anything.
