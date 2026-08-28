# Security policy

psi runs locally with the privileges of the user who starts it. It ships no
sandbox and can execute model-generated shell commands and file writes. Use a
container, virtual machine, or another operating-system boundary when those
privileges are too broad.

psi treats the local user account, and files writable by that account, as
inside the same trust boundary as the psi process itself. If an attacker
can modify files under the user's home directory, shell startup files,
environment, or psi configuration, they can generally influence psi or
other local developer tools. Reports that depend on such prior local
write access are not vulnerabilities unless they demonstrate how psi
grants that write access or crosses an operating-system privilege
boundary.

## Workspace trust

An untrusted checkout can contain prompt-injection text in `AGENTS.md`,
`CLAUDE.md`, or source comments. It can also provide project-local resources
that change psi's behavior. psi therefore gates the following resources behind
a per-directory trust decision
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

In non-interactive use (`--print`, `--agent`, `--eval`), psi denies untrusted
directories by default. It loads `AGENTS.md` and `CLAUDE.md` context files
regardless of trust. Work only in repositories whose content is trusted, or run
psi inside an operating-system security boundary.

## Reporting a vulnerability

Report suspected vulnerabilities privately through
[GitHub Security Advisories](https://github.com/siraben/psi-code/security/advisories/new).
Include the impact, reproduction steps or a proof of concept, the affected
version or commit, and any known mitigations. Do not open a public issue for a
security-sensitive report.

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
