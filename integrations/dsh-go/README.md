# OpenRayneo × DSH Go

OpenRayneo owns the glasses connection, audio storage, ASR, local speaker processing and record summaries.
The phone's external Agent decides whether to wait, answer, call tools or run a workflow.
Current delivery: Android **37 / 1.2.0-beta.4** with plugin **0.1.8**; Android36 remains compatible.
Architecture and current limitations live in the workspace `.arch/`; operations live in `docs/runbook.md`.

## Install and connect

Install this directory once:

```sh
dsh plugin --profile web add /absolute/path/openrayneo-dsh
```

For a packaged update, replace the installed plugin directory with `openrayneo-dsh-0.1.8.tgz` contents.
The npm archive has a top-level `package/`; use `--strip-components=1` when extracting into that directory.
Update the companion APK and restart the DSH engine after replacing plugin code.
Existing connection credentials and saved phone records remain.

In OpenRayneo enable **DSH Go 与外部 Agent → 本机 Agent 入口**, then copy its address and token.
In DSH Go tap **Connect / 连接眼镜** and allow clipboard access.
The plugin stores the token as the `OPENRAYNEO_TOKEN` credential; clipboard content stays out of prompts.
The default local URL is `http://127.0.0.1:8766`; set the actual Service URL for a custom port.
Keep both phone apps allowed to run in the background.
Record encounter sync uses a separate token and port **8767**; it does not expose device tools.

## Tools and records

The plugin registers `rayneo_status`, `rayneo_tools` and `rayneo_call`.
Read the actual tool definitions before use; they define the available glasses and phone operations.
`record_query` searches by record ID, text or Unix-millisecond interval `[from,to)`.
`record_annotate` attaches `analysis`, `note` or `tags` using the queried `sourceRevision`.
Use a stable annotation `id` for retries; source corrections mark derived results stale.
Todo/calendar mutations require stable `request_id` values and readback after uncertain outcomes.
Raw audio, voice embeddings, model API keys and vendor-cloud credentials are not needed by this plugin.

## Voice delivery and conversation reuse

Completed ASR and speaker results are delivered together, including unknown or mixed segments.
The encrypted phone outbox preserves pending inputs while DSH is unavailable and answers until delivery.
Live **小雷小雷** inputs reuse one DSH conversation across wake, record and task IDs.
The persisted binding is scoped by phone installation, native conversation key and selected Agent preset.
Stable native keys require Android36 or newer; other sources and historical backfill retain separate sessions.
Phone **助手 → 新建对话** rotates the native key and clears local short context without deleting records.
Changing the Agent preset chooses its own binding; stale replies cannot enter a new conversation.

The reply uses the current native wake/realtime SID when valid, otherwise a glasses notification.
Stopping capture preserves an already submitted task; cancellation targets only the owned request.
Manual DSH input and other requests keep their own lifecycle; already executed operations remain.
Same-key requests serialize until the prior turn and cancellation cleanup are quiescent.
Bindings survive plugin reload and DSH cold restart through the real session controller and storage domain.
Only a genuinely missing session may be recreated before prompting; transient failures do not replay prompts/tools.
Terminal delivery retries use readback. Approvals and phone-control permissions remain in DSH Go.

Backfill carries `input.backfill=true`, original time facts and processing delay.
It updates historical context; it is not a fresh instruction to execute past commands.
Completed old utterances are not replayed. Explicit current authorization still governs new actions.
