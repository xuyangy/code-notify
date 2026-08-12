/**
 * Code-Notify bridge for opencode.
 *
 * Managed by code-notify — `cn on opencode` rewrites this file; edits are lost.
 *
 * Unlike pi and omp, opencode runs on the host: this plugin lives in the same
 * process tree as the TUI, so it can invoke the notifier directly instead of
 * spooling events for a relay. $TMUX and $TMUX_PANE are inherited from the
 * terminal that started opencode, which is what gives the notifier its window
 * for badges and click-to-focus.
 *
 * The one case that breaks is a pre-existing server (`opencode serve`, or a
 * fixed `server.port` a second TUI attaches to): plugins run inside the
 * server, so the pane it inherited is the server's, not the client's. Desktop,
 * voice and channel delivery are unaffected; only tmux window targeting is.
 *
 * The install renders NOTIFIER below to this install's notifier.sh. An
 * unrendered copy of this file keeps the placeholder and disables itself,
 * because a bridge that guesses a path is worse than one that stays silent.
 *
 * Every notifier run is spawned detached and never awaited. `permission.asked`
 * fires while the user is waiting on an approval dialog, so nothing here may
 * sit in front of opencode's own work.
 *
 * Events (opencode 1.18.x bus names; the ".v2." spellings and the older SDK
 * aliases are folded onto the same handlers, so neither a newer nor an older
 * opencode goes unannounced):
 *
 *   permission.asked            -> permission_prompt notification
 *   question.asked              -> elicitation_dialog notification
 *   permission/question replied -> ResumeAfterInput (running indicator back)
 *   status idle | session.idle  -> stop (task complete)
 *   session.error               -> StopFailure, or silent teardown on abort
 *
 * A turn-active flag per session collapses the two turn-end events (opencode
 * emits both) into exactly one completion, and makes an interrupted turn tear
 * down silently rather than announce a completion the user cancelled. The
 * teardown is only ever sent for a top-level turn this plugin started, because
 * it acts on a tmux pane rather than a session id — see the session.error
 * handler.
 *
 * Which session an event belongs to decides whether it is announced at all:
 *
 *   - subagents (sessions with a parentID) never produce a completion, a
 *     failure alert or a teardown: none of those are the user's turn ending;
 *   - their approval and question prompts DO notify, because those stop and
 *     wait for the user exactly as the main session's do;
 *   - an event carrying no session id is acted on only when it cannot be
 *     misattributed — a prompt notifies, a terminal event does not.
 */

import { spawn } from "node:child_process"

const NOTIFIER = "@@CODE_NOTIFY_NOTIFIER@@"
const TOOL = "opencode"

// Suffix used to spot an unrendered copy without embedding the whole rendered
// marker (which would make the check true for every real install too).
const UNRENDERED = "@@CODE_NOTIFY_NOTIFIER" + "@@"

export const CodeNotify = async (input: any) => {
	// The loader treats EVERY export of this module as a plugin factory and
	// throws on a non-function export, so nothing else may be exported here.
	if (!NOTIFIER || NOTIFIER === UNRENDERED) return {}

	const directory: string = input?.directory ?? process.cwd()

	// Sessions with a parentID are subagents. Their turn ends are not the
	// user's turn end, so they never notify — but their permission and
	// question prompts do, because those still stop and wait for the user.
	const childSessions = new Set<string>()
	// Sessions whose turn is in flight. Set when the user submits and while
	// opencode reports the session busy; cleared by whichever turn-end event
	// arrives first, so the second one is a no-op.
	const active = new Set<string>()
	// Sessions whose current turn was aborted (Esc). The idle that follows an
	// abort must not announce a completion.
	const aborted = new Set<string>()

	// Fire and forget. Failures are swallowed: a broken notifier must never
	// surface as a plugin error inside the user's session.
	const notify = (hook: string, payload?: string) => {
		try {
			const child = spawn("/bin/bash", [NOTIFIER, hook, TOOL], {
				// The notifier derives the project name from its working
				// directory (git worktree root, else basename), so handing it
				// the session's directory is what makes badges, wording and
				// per-project voice line up with the rest of code-notify.
				cwd: directory,
				detached: true,
				stdio: [payload === undefined ? "ignore" : "pipe", "ignore", "ignore"],
				// opencode exports OPENCODE/OPENCODE_PID into everything it
				// spawns, which the notifier normally treats as "a Claude hook
				// replayed by an opencode compatibility plugin — do nothing".
				// This marks the runs that really are opencode's own.
				env: { ...process.env, CODE_NOTIFY_OPENCODE_HOOK: "1" },
			})
			child.on("error", () => {})
			if (payload !== undefined) {
				child.stdin?.on("error", () => {})
				child.stdin?.end(payload)
			}
			child.unref()
		} catch {
			// spawn itself failed (no /bin/bash, fork limit): stay silent.
		}
	}

	const isChild = (sessionID?: string): boolean =>
		typeof sessionID === "string" && childSessions.has(sessionID)

	// Request ids of prompts already announced, so a release that emits both
	// an event and its versioned alias for one request still toasts once.
	// Bounded by discarding the oldest half rather than by time: a permission
	// prompt can sit unanswered for as long as the user is away, so an expiry
	// short enough to bound memory would be short enough to re-toast a prompt
	// still on screen. A request with no id is always announced — a duplicate
	// approval toast is a far smaller failure than a silent one.
	const seenPrompts = new Set<string>()
	const promptSeen = (id: unknown): boolean => {
		if (typeof id !== "string" || !id) return false
		if (seenPrompts.has(id)) return true
		if (seenPrompts.size >= 512) {
			for (const old of [...seenPrompts].slice(0, 256)) seenPrompts.delete(old)
		}
		seenPrompts.add(id)
		return false
	}

	// One completion per turn, and none at all for a turn nobody started or a
	// turn the user cancelled.
	const finish = (sessionID?: string) => {
		if (!sessionID || isChild(sessionID)) return
		if (!active.delete(sessionID)) return
		if (aborted.delete(sessionID)) {
			// Interrupted: take the running indicator down without a toast.
			notify("SessionEnd")
			return
		}
		notify("stop")
	}

	return {
		// A real user submission — the signal that the window was handed work.
		// UserPromptSubmit clears this window's event badge and lights the
		// running indicator. Subagent prompts come through here too, hence the
		// child filter: their sessions are not what the user is looking at.
		"chat.message": async (input: any) => {
			const sessionID = input?.sessionID
			if (!sessionID || isChild(sessionID)) return
			active.add(sessionID)
			aborted.delete(sessionID)
			notify("UserPromptSubmit")
		},

		event: async ({ event }: { event: any }) => {
			// opencode versions the prompt events (permission.v2.asked,
			// question.v2.rejected, ...) while keeping the same shape and
			// meaning. Folding ".v2." away means a version bump cannot make
			// this plugin go silent on approvals — the worst thing it could
			// do — and promptSeen below makes the aliasing safe even if a
			// release ever emits both spellings for one request.
			const type: string = String(event?.type ?? "").replace(".v2.", ".")
			const props: any = event?.properties ?? {}

			switch (type) {
				case "session.created":
				case "session.updated": {
					const info = props.info
					if (!info?.id) return
					if (info.parentID) childSessions.add(info.id)
					return
				}

				case "session.deleted": {
					const id = props.info?.id
					if (!id) return
					childSessions.delete(id)
					active.delete(id)
					aborted.delete(id)
					return
				}

				// A permission request exists only when opencode will actually
				// stop and wait for a reply — calls its ruleset allows never
				// reach this point. That is why this, and not the
				// `permission.ask` hook, is the approval signal: the hook runs
				// during evaluation, including for auto-allowed calls.
				//
				// Deliberately NOT filtered by session: a subagent's approval
				// prompt stops and waits for the user exactly like the main
				// session's, and an approval nobody is told about is the worst
				// thing this integration can do.
				//
				// permission.updated is the name older opencode gave the same
				// event.
				case "permission.asked":
				case "permission.updated":
					if (promptSeen(props.id)) return
					notify("notification", '{"type":"permission_prompt"}')
					return

				// The question tool: opencode is asking the user something
				// mid-turn. Same class of "you are being waited on" as an
				// approval, and it must never be missed either.
				case "question.asked":
					if (promptSeen(props.id)) return
					notify("notification", '{"type":"elicitation_dialog"}')
					return

				// Answered — the turn continues, so put the running indicator
				// back. The notifier ignores this unless it previously paused
				// for input, so it costs nothing in any other situation.
				case "permission.replied":
				case "question.replied":
				case "question.rejected":
					notify("ResumeAfterInput")
					return

				// session.status is the canonical turn-end event; session.idle
				// is marked deprecated upstream and kept here as the
				// compatibility path for opencode versions that still emit
				// only it. They are not co-equal signals — whichever arrives
				// first ends the turn, and the active-set check below makes
				// the other a no-op.
				case "session.idle":
					finish(props.sessionID)
					return

				case "session.status": {
					const sessionID = props.sessionID
					if (!sessionID || isChild(sessionID)) return
					const status = props.status?.type
					if (status === "busy") {
						// Also covers the resumed half of a turn, so a
						// completion is still delivered when the turn began
						// before this plugin loaded. Deliberately do not send
						// UserPromptSubmit here: that hook means the user
						// engaged this window and may clear a pending badge.
						// A status-only transition proves work is running, not
						// that the user has seen the previous notification.
						active.add(sessionID)
						return
					}
					if (status === "idle") finish(sessionID)
					return
				}

				case "session.error": {
					const sessionID = props.sessionID
					const name = String(props.error?.name ?? "")

					// A subagent failing is not the user's turn failing, and an
					// error with no session attached cannot be attributed to
					// one. Both used to fall through: the abort branch tore
					// down whatever pane this process inherited (SessionEnd
					// carries no session, so it hit the still-running parent
					// turn's indicator), and the failure branch toasted
					// "opencode failed" for a turn that was still going.
					if (!sessionID || isChild(sessionID)) return

					if (name === "MessageAbortedError") {
						// The user pressed Esc. Remember it for the idle that
						// follows; if none does, tear down here so the running
						// indicator cannot outlive the turn.
						//
						// Only for a turn this plugin actually started: with no
						// state of our own there is no indicator of ours to
						// take down, and tearing down anyway would clear
						// someone else's.
						if (!active.has(sessionID)) return
						aborted.add(sessionID)
						finish(sessionID)
						return
					}

					active.delete(sessionID)
					aborted.delete(sessionID)
					// StopFailure carries the error class so the notifier can
					// tell a usage limit (its own badge and pause semantics)
					// from an ordinary failure. opencode names errors after
					// their type (APIError, ProviderAuthError, ...), so in
					// practice these all land on the failure alert — and, as
					// with any turn that ends without a Stop, take the running
					// indicator down.
					notify("StopFailure", JSON.stringify({ error: name || "unknown" }))
					return
				}
			}
		},
	}
}
