/**
 * Code-Notify bridge for pi.
 *
 * Managed by code-notify — `cn on pi` rewrites this file; edits are lost.
 *
 * pi runs inside a container (pi-less-yolo), which cannot deliver a
 * notification: no $TMUX, no host tmux socket, no notifier. This extension
 * drops one small file per lifecycle event into the spool directory named by
 * CODE_NOTIFY_SPOOL — inside the bind-mounted agent state directory — and the
 * host-side relay (`code-notify relay pi`) turns them into notifications from
 * the tmux pane the container renders into. See the omp hook for the shared
 * wire format; the two differ only in which events exist.
 *
 * pi has no built-in tool-approval prompt (that is the "less YOLO" the
 * container provides instead), so the event set is turn-scoped: work handed
 * over, and work finished.
 *
 * No CODE_NOTIFY_SPOOL means pi was not launched through the relay: the
 * extension disables itself entirely.
 */

import { mkdirSync, renameSync, writeFileSync } from "node:fs";

const SPOOL = process.env.CODE_NOTIFY_SPOOL;

// Module scope, not the factory closure: if this file is ever instantiated
// more than once in a process (as omp does for subagent sessions), per-instance
// counters would both start at 0 and two events in the same millisecond would
// name the same file — the second rename destroying the first. One counter for
// the process, plus the pid, makes that impossible. See the omp hook, where
// this is not hypothetical.
let spoolSeq = 0;
const SPOOL_PID = typeof process?.pid === "number" ? process.pid : 0;

export default function (pi: any) {
	if (!SPOOL) return;

	let spoolReady = false;

	const clean = (value: unknown): string =>
		typeof value === "string" ? value.replace(/[\t\r\n]+/g, " ").slice(0, 512) : "";

	const emit = (event: string, toolName?: unknown): void => {
		try {
			if (!spoolReady) {
				mkdirSync(SPOOL, { recursive: true });
				spoolReady = true;
			}
			const base = `${SPOOL}/${Date.now()}-${String(spoolSeq++).padStart(4, "0")}-${SPOOL_PID}`;
			writeFileSync(`${base}.tmp`, `${event}\t${clean(process.cwd())}\t${clean(toolName)}\n`);
			renameSync(`${base}.tmp`, `${base}.ev`);
		} catch {
			// Never let a notification failure take the agent down with it.
		}
	};

	// The user handed this window work.
	pi.on("input", async (event: any) => {
		if (event?.source === "extension") return { action: "continue" };
		emit("prompt_submit");
		return { action: "continue" }; // never alter the input
	});

	// agent_settled, not agent_end: it fires once nothing is left to retry,
	// compact, or follow up, so a mid-turn retry does not read as completion.
	pi.on("agent_settled", async () => {
		emit("stop");
		return undefined;
	});

	pi.on("session_shutdown", async () => {
		emit("session_end");
		return undefined;
	});
}
