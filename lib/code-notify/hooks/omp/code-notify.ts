/**
 * Code-Notify bridge for omp (oh-my-pi).
 *
 * Managed by code-notify — `cn on omp` rewrites this file; edits are lost.
 *
 * omp runs inside a container (pi-less-yolo). Nothing in there can deliver a
 * notification: there is no $TMUX, no host tmux socket, and no notifier. The
 * one channel back to the host is the agent state directory, which the
 * launcher bind-mounts. So this hook does the least it possibly can — drop one
 * small file per lifecycle event into the spool directory named by
 * CODE_NOTIFY_SPOOL — and the host-side relay (`code-notify relay omp`),
 * running in the tmux pane the container renders into, turns those files into
 * ordinary notifier invocations.
 *
 * Wire format: a single tab-separated line, "<event>\t<cwd>\t<tool_name>".
 * The relay derives the project name from cwd, which is valid because the
 * launcher mounts the working directory at its real host path.
 *
 * Written as "<name>.tmp" and renamed to "<name>.ev" so the relay never reads
 * a half-written file. Names are "<epoch-ms>-<seq>" so a lexicographic glob
 * yields chronological order, across processes as well as within one.
 *
 * No CODE_NOTIFY_SPOOL means omp was not launched through the relay (a bare
 * `docker run`, or omp on the host): the hook disables itself entirely.
 */

import { mkdirSync, renameSync, writeFileSync } from "node:fs";

const SPOOL = process.env.CODE_NOTIFY_SPOOL;

// Subagents are separate sessions that load this hook again, on their own
// event bus, in this same process — so without a guard every subagent that
// finished would announce the turn complete while the real turn was still
// running. Module scope (shared across those instances, unlike the factory
// closure below) is what makes the first session identifiable as the primary
// one: it starts at boot, before any subagent can exist.
let primarySessionId: string | undefined;

// Also module scope, and that is the whole point: every hook instance in this
// process draws from one counter. A per-instance counter would restart at 0 in
// each subagent, so two instances emitting in the same millisecond would name
// the same file and the second rename would silently destroy the first — and
// approval events are deliberately NOT gated to the primary session, so the
// event lost that way could be a subagent's approval request. The pid keeps
// the name unique even if a future omp spawns subagents as child processes
// sharing the spool.
let spoolSeq = 0;
const SPOOL_PID = typeof process?.pid === "number" ? process.pid : 0;

export default function (pi: any) {
	if (!SPOOL) return;

	let spoolReady = false;

	const sessionId = (ctx: any): string | undefined => {
		try {
			return ctx?.sessionManager?.getSessionId?.();
		} catch {
			return undefined;
		}
	};

	// Fails open in every uncertain case — an unidentifiable session notifies.
	// A duplicate completion is a nuisance; a missed one is the bug this whole
	// bridge exists to prevent.
	const isPrimary = (ctx: any): boolean => {
		const current = sessionId(ctx);
		if (!primarySessionId || !current) return true;
		return current === primarySessionId;
	};

	const claimPrimary = (ctx: any): void => {
		const current = sessionId(ctx);
		if (current) primarySessionId = current;
	};

	// The first session to start owns the pane. /new, /resume and /fork replace
	// it through their own events, which a subagent never emits.
	pi.on("session_start", async (_event: any, ctx: any) => {
		if (!primarySessionId) claimPrimary(ctx);
		return undefined;
	});
	pi.on("session_switch", async (_event: any, ctx: any) => {
		claimPrimary(ctx);
		return undefined;
	});
	pi.on("session_branch", async (_event: any, ctx: any) => {
		claimPrimary(ctx);
		return undefined;
	});

	// Tabs and newlines are the record separators, so they cannot survive in a
	// field. The cap keeps a pathological value from filling the mount.
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
			// A missed notification is bad; an agent that dies because its
			// notification hook threw is worse. Every failure is swallowed.
		}
	};

	// The user handed this window work: starts the running indicator and
	// clears any badge left by the previous turn.
	pi.on("input", async (event: any, ctx: any) => {
		if (event?.source === "extension") return undefined;
		if (isPrimary(ctx)) emit("prompt_submit");
		return undefined; // never alter the input
	});

	// The events that must never be missed: omp is waiting on the user. Not
	// gated on the primary session — a subagent's approval prompt takes over
	// the same screen and needs you just as much.
	pi.on("tool_approval_requested", async (event: any) => {
		emit("permission_request", event?.toolName);
		return undefined;
	});

	pi.on("tool_approval_resolved", async () => {
		emit("permission_replied");
		return undefined;
	});

	// The `ask` tool is omp asking a question rather than requesting approval;
	// the relay maps it to the elicitation_dialog alert.
	pi.on("tool_execution_start", async (event: any) => {
		if (event?.toolName === "ask") emit("question_asked", event?.toolName);
		return undefined;
	});

	// Turn end. willContinue marks an internal continuation (retry, compaction,
	// follow-up), which is not something to notify about; a subagent finishing
	// is not the turn ending either.
	pi.on("agent_end", async (event: any, ctx: any) => {
		if (event?.willContinue) return undefined;
		if (!isPrimary(ctx)) return undefined;
		emit(endedInError(event) ? "stop_failure" : "stop");
		return undefined;
	});

	// Lets the relay retire the running indicator without waiting for its
	// parent-exit sweep when omp exits mid-turn (/exit, Ctrl-C).
	pi.on("session_shutdown", async (_event: any, ctx: any) => {
		if (isPrimary(ctx)) emit("session_end");
		return undefined;
	});
}

// A turn that ended on an API error carries the failure on the last assistant
// message rather than on the event itself. Treated as best-effort: an
// unrecognised shape falls back to a normal completion.
function endedInError(event: any): boolean {
	try {
		const messages = event?.messages;
		if (!Array.isArray(messages)) return false;
		for (let i = messages.length - 1; i >= 0; i--) {
			const message = messages[i];
			if (message?.role !== "assistant") continue;
			return message?.stopReason === "error";
		}
	} catch {
		// fall through
	}
	return false;
}
