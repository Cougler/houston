---
name: release
description: Ship a Houston release end-to-end — package a signed+notarized DMG, publish the GitHub release the in-app updater reads, and put the same DMG on tryhoustonapp.com. Trigger on "/release", "release it", "ship a release", "cut a release".
---

# Release Houston

Ships version `$ARGUMENTS` (or, if no version given, bump the patch number of
the latest `vX.Y.Z` tag on GitHub releases). All steps run from
`~/Apps/houston` unless noted. The three outputs MUST stay in sync: the GitHub
release (what installed apps update from), the site DMG (what new users
download), and the tag (what `UpdateChecker` compares against).

1. **Preflight.** The working tree must be clean and pushed — a release built
   from unpushed code can't be reproduced from the repo. If it isn't, stop and
   tell the user to run `/push` first.

2. **Package** (signs with the Developer ID, notarizes via the
   `houston-notary` keychain profile — waits on Apple, usually a few minutes —
   and staples):

   ```bash
   SIGN_ID="Developer ID Application: Aaron Cougle (4CDVHNL984)" scripts/package.sh <VERSION>
   ```

   Only proceed if it ends with `✓ Gatekeeper: accepted`.

3. **Publish the GitHub release** — this is what the in-app update checker
   polls (`releases/latest`); the tag MUST be `v<VERSION>` with the DMG
   attached. Write the notes as a short plain-English summary of what changed
   since the previous tag (`git log <prev-tag>..HEAD --oneline` for the raw
   list):

   ```bash
   gh release create v<VERSION> dist/Houston.dmg --title "Houston <VERSION>" --notes "<summary>"
   ```

4. **Update the site download** so first-time downloads get the same build:

   ```bash
   cp dist/Houston.dmg ~/Apps/houston-fos/public/Houston.dmg
   cd ~/Apps/houston-fos && npx vercel deploy --prod --yes
   ```

5. **Verify both ends**, then report the version, release URL, and site URL:

   ```bash
   curl -s https://api.github.com/repos/Cougler/houston/releases/latest | grep tag_name   # expect v<VERSION>
   curl -sI https://tryhoustonapp.com/Houston.dmg | grep -i last-modified                 # expect just now
   ```
