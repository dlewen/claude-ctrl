<p align="center">
  <img src="assets/banner.jpeg" alt="The Systems Thinker's Deterministic Claude Code Control Plane" width="100%">
</p>

# The Systems Thinker's Deterministic Claude Code Control Plane

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/juanandresgs/claude-ctrl)](https://github.com/juanandresgs/claude-ctrl/stargazers)
[![Last commit](https://img.shields.io/github/last-commit/juanandresgs/claude-ctrl)](https://github.com/juanandresgs/claude-ctrl/commits/main)
[![Shell](https://img.shields.io/badge/language-bash-green.svg)](hooks/)

**Instructions guide. Hooks enforce.**

A deterministic governance layer for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that uses shell-script hooks to intercept every tool call —bash commands, file writes, agent dispatches, session boundaries— and mechanically enforce sound principles. Responsibilities are divided between specialized agents (Planner, Implementer, Tester, Guardian) to ensure quality work. The hooks enforce the process so the model can focus on the task at hand.

---

## Design Philosophy

Telling a model to 'never commit on main' works... until context pressure erases the rule. After compaction, under heavy cognitive load, after 40 minutes of deep implementation, the constraints that live in the model's context aren't constraints. At best, they're suggestions. Most of the time, they're prayers.

LLMs are not deterministic systems with probabilistic quirks. They are **probabilistic systems** — and the only way to harness them into producing reliably good outcomes is through deterministic, event-based enforcement. Wiring a hook that fires before every bash command and mechanically denies commits on main works regardless of what the model remembers or forgets or decides to prioritize. Cybernetics gave us a framework to harness these systems decades ago. The hook system enforces standards determinitically. The observatory jots down traces to analyze for each run. That feedback improves performance and guides how the gates adapt. 

Every version teaches me something about how to govern probabilistic systems, and those lessons feed into the next iteration. The end-state goal is an instantiation of what I call **Self-Evaluating Self-Adaptive Programs (SESAPs)**: probabilistic systems constrained to deterministically produce a range of desired outcomes.

Most AI coding harnesses today rely entirely on prompt-level guidance for constraints. So far, Claude Code has the more comprehensive event-based hooks support that serves as the mechanical layer that makes deterministic governance possible. Without it, every session is a bet against context pressure. This project is meant to address the disturbing gap between developers at the frontier and the majority of token junkies vibing at the roulette wheel hoping for a payday.

I've never been much of a gambler myself.

*— [JAGS](https://x.com/juanandres_gs)*

---

<h2 align="center">Metanoia v3.0</h2>

<p align="center"><em>metanoia (n.) — a fundamental change in thinking; a transformative shift in approach</em></p>

<p align="center"><strong>617 commits over v2.0</strong> — a ground-up refactor of the hook architecture,<br>state management, and agent governance.</p>

---

### The Headline

17 individual hook scripts consolidated into **4 entry points** backed by **10 lazy-loaded domain libraries**.

The result: **74% less hook overhead** per session. Zero governance loss.

### Before and After

```
v2.0                                    v3.0 (Metanoia)
────────────────────────────────────    ────────────────────────────────────
17 hooks firing independently           4 consolidated entry points
~26s hook overhead/session              ~6.7s hook overhead/session
54 tests                                160+ tests
macOS only                              macOS + Ubuntu CI
Flat-file state                         Per-worktree isolated state store
3 agents                                4 agents (+ Tester with auto-verify)
Manual worktree management              Auto-sweep, roster, CWD recovery
```

### New Capabilities

- **Lint-on-write** — shellcheck/ruff/cargo clippy runs synchronously on every Write/Edit
- **Dispatch enforcement** — hooks mechanically block the orchestrator from writing source code directly
- **Cross-project isolation** — SHA-256 project hashing prevents state contamination across concurrent sessions
- **Proof-before-commit chain** — Implement → Test → Verify → Commit, each gate enforced by hooks
- **Self-validation** — version sentinels, `bash -n` preflight, hooks-gen integrity check at startup
- **Observatory** — self-improving flywheel that analyzes agent traces and surfaces improvement signals

See the full [CHANGELOG](CHANGELOG.md) for the complete list.

---

## How It Works

**Default Claude Code** — you describe a feature and:

```
idea → code → commit → push → discover the mess
```

The model writes on main, skips tests, force-pushes, and forgets the plan once the context window fills up. Every session is a coin flip.

**With claude-ctrl** — the same feature request triggers a self-correcting pipeline:

```
                ┌─────────────────────────────────────────┐
                │           You describe a feature         │
                └──────────────────┬──────────────────────┘
                                   ▼
                ┌──────────────────────────────────────────┐
                │  Planner agent:                          │
                │    1a. Problem decomposition (evidence)   │
                │    1b. User requirements (P0/P1/P2)      │
                │    1c. Success metrics                   │
                │    2.  Research gate → architecture       │
                │  → MASTER_PLAN.md + GitHub Issues         │
                └──────────────────┬───────────────────────┘
                                   ▼
                ┌──────────────────────────────────────────┐
                │  Guardian agent creates isolated worktree │
                └──────────────────┬───────────────────────┘
                                   ▼
              ┌────────────────────────────────────────────────┐
              │              Implementer codes                  │
              │                                                 │
              │   write src/ ──► test-gate: tests passing? ─┐   │
              │       ▲              no? warn, then block   │   │
              │       └──── fix tests, write again ◄────────┘   │
              │                                                 │
              │   write src/ ──► plan-check: plan stale? ───┐   │
              │       ▲              yes? block              │   │
              │       └──── update plan, write again ◄──────┘   │
              │                                                 │
              │   write src/ ──► doc-gate: documented? ─────┐   │
              │       ▲              no? block               │   │
              │       └──── add headers + @decision ◄───────┘   │
              └────────────────────────┬───────────────────────┘
                                       ▼
                ┌──────────────────────────────────────────────┐
                │  Tester agent: live E2E verification          │
                │  → proof-of-work evidence written to disk     │
                │  → check-tester.sh: auto-verify or           │
                │    surface report for user approval           │
                └──────────────────────┬───────────────────────┘
                                       ▼
                ┌──────────────────────────────────────────────┐
                │  Guardian agent: commit (requires verified    │
                │  proof-of-work + approval) → merge to main   │
                └──────────────────────────────────────────────┘
```

Every arrow is a hook. Every feedback loop is automatic. The model doesn't choose to follow the process — the hooks won't let it skip. Try to write code without a plan and you're pushed back. Try to commit with failing tests and you're pushed back. Try to skip documentation and you're pushed back. Try to commit without tester sign-off and you're pushed back. The system self-corrects until the work is right.

**The result:** you move faster because you never think about process. The hooks think about it for you. Dangerous commands get denied with corrections (`--force` → use `--force-with-lease`, `/tmp/` → use project `tmp/`). Everything else either flows through or gets caught. You just describe what you want and review what comes out.

---

## Sacred Practices

Ten rules. Each one enforced by hooks that fire every time, regardless of what the model remembers.

| # | Practice | What Enforces It |
|---|----------|-------------|
| 1 | **Always Use Git** | `session-init.sh` injects git state; `pre-bash.sh` blocks destructive operations |
| 2 | **Main is Sacred** | `pre-write.sh` blocks writes on main; `pre-bash.sh` blocks commits on main |
| 3 | **No /tmp/** | `pre-bash.sh` denies `/tmp/` paths and directs to project `tmp/` |
| 4 | **Nothing Done Until Tested** | `pre-write.sh` warns then blocks when tests fail; `pre-bash.sh` requires test evidence for commits |
| 5 | **Solid Foundations** | `pre-write.sh` detects and escalates internal mocking (warn → deny) |
| 6 | **No Implementation Without Plan** | `pre-write.sh` denies source writes without MASTER_PLAN.md |
| 7 | **Code is Truth** | `pre-write.sh` enforces headers and @decision annotations on 50+ line files |
| 8 | **Approval Gates** | `pre-bash.sh` blocks force push; Guardian requires approval for all permanent ops |
| 9 | **Track in Issues** | `post-write.sh` checks plan alignment; `check-planner.sh` validates issue creation |
| 10 | **Proof Before Commit** | `check-tester.sh` auto-verify; `prompt-submit.sh` user approval gate; `pre-bash.sh` evidence gate |

---

## Getting Started

### 1. Clone

```bash
git clone --recurse-submodules git@github.com:juanandresgs/claude-ctrl.git ~/.claude
```

Back up first if you already have a `~/.claude` directory.

### 2. Configure

```bash
cp settings.local.example.json settings.local.json
```

Edit `settings.local.json` to set your model preference and MCP servers. This file is gitignored — your overrides stay local.

### 3. API Keys (optional)

The `deep-research` skill queries OpenAI, Perplexity, and Gemini in parallel for multi-model synthesis. Copy the example and fill in your keys:

```bash
cp .env.example .env
```

Everything works without these — research just won't be available.

### 4. Verify

Run `bash scripts/check-deps.sh` to confirm dependencies. On your first `claude` session, the SessionStart hook will inject git state, plan status, and worktree info.

### Staying Updated

Auto-updates on every session start. Same-MAJOR-version updates apply automatically; breaking changes notify you first. Create `~/.claude/.disable-auto-update` to opt out. Fork users: your `origin` points to your fork — add `upstream` to track the original.

### Uninstall

Remove `~/.claude` and restart Claude Code. It recreates a default config. Your projects are unaffected.

---

## Go Deeper

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — System architecture, design decisions, subsystem deep-dive
- [`hooks/HOOKS.md`](hooks/HOOKS.md) — Full hook reference: protocol, state files, shared libraries
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — How to contribute
- [`CHANGELOG.md`](CHANGELOG.md) — Release history
