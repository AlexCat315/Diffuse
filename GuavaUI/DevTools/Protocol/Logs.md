# Log stream

Capability: `log`. Hosts use `GuavaLogCore.LogRecord` unchanged on native and Wasm transports. Logging works independently of an Inspector connection.

`log.subscribe` accepts an optional LogQuery: `{minimum:"warning", labels:["com.example"], text:"save", afterSequence:42}`. Omitted fields use trace/empty/empty/no cursor. Labels match an exact module or a descendant path segment; text searches message, label, metadata and location. The reply is `log.snapshot` with `{records, dropped, firstAvailableSequence}`. Native replay is bounded to the newest 200 matches and 512 KiB. The cursor filters a single process's sequence, and the snapshot's dropped count is the cumulative producer queue loss.

Live messages are `log.entry` with a LogRecord. Clients deduplicate by `(process.runID, process.pid, sequence)` across snapshots and live delivery. `log.gap` reports `{dropped:N}` for records lost in delivery since the previous report. `log.unsubscribe` replies `log.unsubscribe.ok` and ends that client's stream. Connections have independent filters, cursors and loss counters.

Record fields are `sequence`, `timestamp` (Unix seconds), `level`, `label`, `message`, `metadata` (natural JSON strings/arrays/objects), `location:{source,file,function,line}`, and `process:{pid,name,runID}`. Consumers must render text as text, not HTML. The Inspector batches display updates, bounds local history, preserves details and exports the filtered history as JSONL. Pausing display continues capture.

Native logging uses a bounded writer-to-server handoff and checks connection writability. A slow connection does not block the writer or other clients. Gaps and bounded replay mean the Inspector is a live diagnostics view; rotating files are the longer-lived journal. Source files are not read by the logging protocol.
