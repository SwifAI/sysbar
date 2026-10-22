# Security Policy

## Supported versions

SysBar is maintained by one developer. Security fixes go into the latest release only.

## What SysBar can do on your Mac

Knowing SysBar's privileges helps decide whether something is a vulnerability:

- **Process actions.** SysBar sends `SIGTERM` (Quit) or `SIGKILL` (Force Quit) only to processes you choose, as your user. It has no privileged helper and never runs as root. Before signaling, it re-checks the process's PID, exact start time and executable path, so a recycled PID is never signaled.
- **Listening ports.** SysBar runs `/usr/sbin/lsof` with a fixed argument list, a timeout and an output cap. This is its only subprocess in normal monitoring.
- **Optional AI briefs (off by default).** When you choose Claude or Codex, SysBar runs your installed Claude Code or Codex CLI from fixed locations (`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`). It does so only after checking that the CLI is signed by its vendor's Developer ID, and it re-checks before every call. The CLI runs without a shell, with no tools, MCP servers, settings or session history, a minimal environment without API keys, a private temporary folder, bounded input and output, and a 30-second timeout. The prompt contains the measurements and process or port details for one attention item.
- **Network.** SysBar itself makes no network requests and has no analytics or crash reporting. Only the AI CLI you enable talks to its vendor.

## In scope

- SysBar signaling a process you did not choose, or a process other than the one shown.
- SysBar executing anything other than `lsof` or a signature-verified Claude Code or Codex CLI.
- Argument, path or environment injection into those subprocesses.
- Process names, command lines or other collected data that make the AI CLI do something beyond writing a brief, or make SysBar run an action that wasn't in the list it offered.
- Any data leaving your Mac other than through the AI CLI you enabled.

## Out of scope

- A Quit or Force Quit you confirmed.
- Vulnerabilities in macOS, Claude Code or Codex themselves. Report those to Apple, Anthropic or OpenAI.
- The quality or accuracy of AI-written briefs.
- Gatekeeper warnings caused by release builds being ad-hoc signed rather than notarized.

## Reporting a vulnerability

**Please don't open a public issue.** Report it privately through GitHub instead: open the [Security tab](https://github.com/SwifAI/sysbar/security) and choose **Report a vulnerability**.

Include the SysBar version, your macOS version and the steps to reproduce. You can expect an acknowledgement within 7 days and a fix in the next release. With your permission, you'll be credited in the release notes.
