# ADR-013: Opt-in, signature-validated, sandboxed Codex CLI boundary for AI health explanations

**Status:** Superseded by ADR-022
**Date:** 2026-09-28 (feature removed 2026-10-16)

## Context

SysBar's first AI feature was a plain-language explanation of a health condition, written
by the user's own Codex CLI. Sending evidence to a third-party process capable of network
egress was the highest-security-bar integration in the codebase, so the boundary around it
was the real decision.

## Decision

The Codex integration was strictly opt-in. Before every call SysBar located the `codex`
binary at one of three fixed candidate paths and validated it against OpenAI's Developer ID
designated requirement; built a minimal environment from scratch (no ambient secrets or API
keys forwarded); ran the CLI with `--sandbox read-only` and its tool features disabled;
sent only a categorical, digit-free, PII-free projection of the evidence; bounded the call
in time and bytes; and re-validated the response against a JSON schema and content
allowlist regardless of exit status.

## Why it was replaced

The categorical health brief was removed on 2026-10-16 and replaced by the attention
briefs of ADR-022. Explaining one aggregate health state turned out less useful than
raising specific items, each with the action that fixes it.

What carried over, now in `AIProviders.swift` and `BoundedProcessRunner.swift`: opt-in
only; Developer ID signature validation of the CLI (Anthropic team `Q6L2SF6YDW` for Claude
Code, OpenAI team `2DC432GLL2` for Codex) re-checked before every call; a restricted
environment and a private temporary working directory; no tools, MCP servers, settings or
saved session; Codex's `--sandbox read-only`; bounded stdin/stdout/stderr, a 30-second
timeout, cancellation and child reaping; and strict JSON-schema validation of the reply.
What changed: evidence is now SysBar's own numbers, unredacted by the owner's choice but
bounded to what SysBar already collects and capped at 20 KB, and the reply must choose
from a closed action catalog.

The accepted residual risk is unchanged: the user-writable candidate paths
(`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`) leave an exec-by-path TOCTOU
window between signature validation and `process.run()`, because the check and the launch
cannot be made atomic.
