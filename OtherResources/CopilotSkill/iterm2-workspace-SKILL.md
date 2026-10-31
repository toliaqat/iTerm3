---
name: iterm2-workspace
description: Orchestrate other agents in the current iTerm2 workspace. Use when the user asks you to split work across parallel Copilot CLI, Claude Code, or shell sessions, to open worker tabs, to send prompts to other tabs, to check on or wait for them, or to read what they printed. Only for the top-level orchestrator session; a worker session must never use it.
---

# iTerm2 workspace orchestration

You can run other agents in tabs of the iTerm2 workspace you’re in and direct them. Everything goes
through one helper:

```
WS="__WS_PATH__"
```

## First: check your role

Run `"$WS" info` before anything else.

- `role orchestrator`: you may use this skill.
- `role code reviewer`: you’re the Code Review session of a workgroup. Don’t use this skill;
  review and add clippings as your instructions say.
- `role worker of …`: you were started by another session’s orchestrator. Don’t use this skill and
  don’t open, message, or close other sessions by any other means either (no `it2`, no AppleScript).
  Do your task and report the result in your reply; the orchestrator reads your screen.

The helper enforces this too: it refuses to run in a worker.

## Copilot CLI workgroup

With iTerm2’s Copilot CLI integration, your session is the Chat of a “Copilot CLI” workgroup. Its
Diff and Code Review sessions belong to you, not the workspace: they don’t appear in `ws list`,
and the user drives them from the workgroup’s toolbar. If the user turns on its automatic review,
Code Review checks your changes when you go idle and its comments come back to you as a prompt;
fix what they flag. Don’t spawn a reviewer of your own for that.

In a workgroup, `spawn` adds each worker to the workgroup itself: it becomes a new segment of the
switcher next to Chat, Diff, and Code Review, not a separate tab. That’s what the user means by a
“workgroup session”. Pass `--tab` only when the user asks for a separate tab.

## The workspace

The workspace is your window, narrowed to your project: the project tab group your tab is in, or
else your git repository or folder. `ws` only acts on sessions in it. Use `"$WS" list` to see them:
ID, role (`worker` for tabs you opened, `worker (peer)` for workgroup segments you opened, `user`
for the user’s own), status, name, job, and folder.

## Commands

| Command | What it does |
|---|---|
| `"$WS" spawn --name NAME [--dir DIR] [--agent copilot\|claude\|shell] [--prompt TEXT] [--flags FLAGS] [--focus] [--tab]` | Opens a worker and prints its session ID: a segment of your workgroup’s switcher when you’re in one, otherwise a tab. Copilot runs with `--yolo` unless you pass `--flags`. What the user is looking at stays in view unless you pass `--focus`. |
| `"$WS" send ID TEXT` | Types TEXT and presses Return, e.g. a follow-up prompt. |
| `"$WS" keys ID TEXT` | Types without Return; `$'\e'` is Esc, which interrupts an agent’s turn. |
| `"$WS" wait [--timeout SECONDS] ID…` | Blocks until one of the sessions is `done`, `waiting` (needs input), `error`, `idle` after working, or `quiet` (not working, screen unchanged for 20 s); prints `ID<TAB>status`. Default timeout 1800 s. |
| `"$WS" status ID` | Status JSON: status, detail (for done, the agent’s last reply), background_tasks. |
| `"$WS" read ID [LINES]` | The last LINES lines of the session’s screen (default 40). |
| `"$WS" focus ID` | Shows the user that session. |
| `"$WS" close ID` | Closes a worker you opened. |

Status needs the agent integration: Copilot CLI and Claude Code report it through iTerm2’s hooks.
A shell worker has no status, so read its screen instead.

## How to orchestrate

1. Split the job into independent tasks with clear outputs. Give each worker a self-contained
   prompt: the goal, the files involved, constraints, and what to report at the end.
2. Spawn one worker per task, with short names (`--name tests`, `--name docs`).
3. `"$WS" wait ID1 ID2 …` to sleep until one needs attention, rather than polling.
4. On `done`, read `status` (its detail is the last reply) or `read` the screen for more. On
   `waiting`, `read` the screen to see the question, then answer with `send` or ask the user.
   On `error`, read the screen and decide whether to retry. On `quiet`, read the screen: a shell
   command finished, or the agent is stuck on a question no hook reports. Copilot CLI asks
   whether to trust a folder it hasn’t seen; answer only if the user said that folder is fine
   (`"$WS" keys ID $'\r'` picks the highlighted Yes).
5. Send follow-ups with `send`, and keep waiting on the rest.
6. Summarize the results for the user. Close workers you’re done with unless the user wants to
   look at them.

## Rules

- Only use `"$WS"`. Don’t drive tabs with raw `it2`, AppleScript, or keystrokes.
- Never send input to, or close, a session whose role is `user` without the user asking you to.
- Don’t spawn more than about five workers at once unless the user asks for more.
- Workers share the working tree. Give parallel workers separate files or separate git worktrees
  so they don’t overwrite each other.
