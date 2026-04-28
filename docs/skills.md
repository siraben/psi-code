# psi skills

psi supports lightweight Agent Skills-style instruction bundles.

A skill is a directory containing `SKILL.md`. psi discovers the skill,
adds its name/description/path to the system prompt, and lets users load
it explicitly with `/skill:name`. The full skill body stays out of steady-
state context until the model reads it or the user invokes it.

## Discovery

psi scans these locations, in order:

1. `$PSI_SKILLS_DIR` (colon-separated list)
2. `~/.config/psi/skills/`
3. `~/.agents/skills/`
4. `~/.codex/skills/`
5. `./.agents/skills/` in the current directory and its ancestors
6. `./.psi/skills/` in the current directory and its ancestors

Later locations win on name collisions, so a project-local skill can
override a global one.

## Skill format

Each skill lives in its own directory:

```text
web-search/
├── SKILL.md
└── scripts/
    ├── search.sh
    └── fetch.sh
```

Minimal `SKILL.md`:

````markdown
---
name: web-search
description: Search the web with Brave Search and fetch pages with curl.
---

# Web Search

Run:
```bash
./scripts/search.sh "query"
```
````

Recognized frontmatter:

- `name`
- `description`
- `disable-model-invocation: true`

Skills without a non-empty `description` are ignored.

## Using skills

There are two paths:

1. Automatic model use: if `read` is active, the system prompt lists the
   available skills and tells the model to read the matching `SKILL.md`
   when a task fits.
2. Explicit user invocation: `/skill:web-search latest lua ffi docs`

`/skill:name args` expands to a `<skill ...>` block whose body is the
skill file contents without frontmatter, followed by the user-supplied
arguments.

## Reloading

`/reload` rescans extensions, skills, prompt templates, and keybindings.
