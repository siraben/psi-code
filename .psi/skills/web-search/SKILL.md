---
name: web-search
description: Search the web and fetch pages with Brave Search plus curl. Use when the user needs current external facts, documentation, or URLs outside the repo.
allowed-tools: bash read
---

# Web Search

## When To Use This Skill

Use this skill when the task depends on live external information rather than repository files, for example:

- current documentation, API changes, or release notes
- vendor or standards references that are not checked into the repo
- verifying a URL, error message, or product behavior on the public web

Do not use this skill when the answer is already available from local files.

## Required Environment

- `curl`
- `python3`
- `BRAVE_SEARCH_API_KEY` or `PSI_BRAVE_SEARCH_API_KEY`

If the Brave API key is missing, say that live web search is unavailable in the current environment instead of fabricating results.

## Workflow

1. Run the search helper to get a concise result list.
2. Inspect the top result URLs.
3. Fetch only the pages you actually need.
4. Quote or summarize the fetched source, and include the URL in the final answer.

## Commands

Basic search:

```bash
./scripts/search.sh "lua 5.4 coroutine.yield"
```

More results:

```bash
./scripts/search.sh --count 8 "site:openai.com responses api tools"
```

Fetch a page body:

```bash
./scripts/fetch.sh https://example.com/docs
```

## Operating Notes

- Prefer precise queries over broad ones.
- Fetch only the most relevant pages instead of crawling many URLs.
- Treat helper script paths as relative to this skill directory.
- Use the existing `bash` tool to execute the helper scripts.
