# Security Policy

This document describes the security concept behind psi and where the
boundaries are.

psi is a coding agent that runs locally within the security boundary of
the user running it. It is the user's responsibility to monitor its
operations or to contain it within a container, virtual machine, or other
sandbox solution. psi intentionally ships no sandbox: the agent executes
model-generated shell commands and file writes with the user's full
privileges.

psi treats the local user account, and files writable by that account, as
inside the same trust boundary as the psi process itself. If an attacker
can modify files under the user's home directory, shell startup files,
environment, or psi configuration, they can generally influence psi or
other local developer tools. Reports that depend on such prior local
write access are not vulnerabilities unless they demonstrate how psi
grants that write access or crosses an operating-system privilege
boundary.

## Workspace trust

Opening an untrusted checkout is the dangerous case: a repository can
carry prompt-injection content (`AGENTS.md`, `CLAUDE.md`, source
comments) that no coding agent can defend against, and it can ship
project-local resources that change psi's behavior. psi therefore gates
the following behind a per-directory trust decision
(`~/.config/psi/trust.json`, prompted once interactively, `--trust` /
`--no-trust` flags, `PSI_TRUST` for scripts, `/trust` to review):

- `./.psi/extensions/` (Lua code executed at startup)
- `./.psi/settings.json` (provider/model defaults, extension config)
- `./.psi/SYSTEM.md` and `./.psi/APPEND_SYSTEM.md` (system prompt control)
- `./.psi/prompts/` and `./.psi/keybindings.json`

The global `security.default_project_trust` setting accepts `"ask"` (the
default), `"always"`, or `"never"`. Project-local settings cannot choose their
own trust policy. Saved decisions use canonical paths and inherit from the
nearest parent directory with a decision.

In non-interactive use (`--print`, `--agent`, `--eval`) untrusted
directories are denied by default. `AGENTS.md` / `CLAUDE.md` context
files are loaded regardless of trust; like upstream pi, psi accepts
prompt injection via repository content as unprotectable — only work in
repositories you trust, or contain psi.

## Reporting a vulnerability

If you believe you found a security vulnerability in psi, please report
it privately by opening a private report through GitHub Security
Advisories for `siraben/psi`. Please include a description of the issue
and its impact, steps to reproduce or a proof of concept, the affected
version or commit, and any known mitigations. Do not open a public issue
for security-sensitive reports.

## Out of scope

- Local code execution or sandboxing behavior (psi intentionally has no
  sandbox)
- Behavior of extensions, prompts, or skills installed by the user
- Prompt injection attacks via repository or tool-output content
- Risks from working in untrusted repositories beyond the workspace-trust
  surface above
- Exposed secrets that are third-party/user-controlled credentials
- Reports requiring pre-existing local write access to user-controlled
  state
- Vulnerabilities in vendored dependencies that are already publicly
  known; `docs/dependency-audit.md` tracks those separately
