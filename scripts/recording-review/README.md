# Local recording review

A standalone Chinese browser tool for reviewing every available Yanyu and Handy recording. It makes no remote model calls. Its suggestions compare existing history text only and never claim to verify the audio.

From the repository root:

```sh
bun install --frozen-lockfile
bun scripts/recording-review/server.ts
```

Open **http://127.0.0.1:17843**. Use this exact address. The server rejects other hosts and foreign origins. Stop with Ctrl+C. Only one server may use a snapshot directory at a time.

On macOS, sources are `~/Library/Application Support/com.siyuqian.yanyu/recordings` and `~/Library/Application Support/com.pais.handy/recordings`. History comes from each application's `history.db`, opened read-only. Windows uses `%APPDATA%`, and Linux uses `$XDG_DATA_HOME` or `~/.local/share` with the same application identifiers. Missing source directories are treated as empty. Database access or schema errors stop startup rather than silently discard history.

The private snapshot is under the platform's app-data directory, in `com.siyuqian.yanyu-recording-review/`. It contains immutable audio snapshots, `samples.json` with matching history text, and separate `feedback.json`. The directory has mode 0700 and files have mode 0600 on systems that support POSIX permissions. Never commit or upload this directory, recordings, reference transcripts, feedback, or screenshots containing personal data.

Every supported regular audio file is included, even duplicates across applications and files without history. Supported extensions are WAV, MP3, OGG, M4A, FLAC, WEBM and AAC. Yanyu stores WAV. Browser playback of other formats depends on the browser. Symbolic links and non-audio files are excluded. A source identity includes the application directory, filename and file contents. Restarting appends new or changed recordings while retaining previous snapshots and feedback. Source cleanup does not remove existing samples. No source files are changed. Existing history is captured once for each audio identity and is not refreshed later.

Select a recording, listen, then confirm or reject the provisional suggestion or select uncertain. Enter a reference transcript, optional preferred output, and notes. **Save** acknowledges persistence on disk. Only a saved judgment other than unreviewed counts toward progress. Navigation asks before discarding unsaved edits. Reloading or closing the page also warns about unsaved edits. A failed save leaves your edits visible and unsaved.

If startup fails, check access to the source databases, the private directory, and port 17843. After an unclean termination, remove `server.lock` from the private directory **only after confirming no review server is running**. Never remove snapshot or feedback files as a startup workaround. Keep review data private when seeking troubleshooting help.

Verification uses generated silent audio and fictional history under an OS temporary directory:

```sh
bun test scripts/recording-review
bunx tsc --project scripts/recording-review/tsconfig.json --noEmit
```

The browser test requires installed Playwright Chromium (`bunx playwright install chromium`). There are no additional packages or changes to desktop settings. Tests never use the default personal-data directories.
