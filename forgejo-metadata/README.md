# Forgejo migration archive

This directory preserves the Forgejo collaboration metadata captured during
the GitHub restoration on 2026-08-28.

- `issues.json`: 40 issues, including bodies, original authors/timestamps, and
  37 comments.
- `pull-requests.json`: 184 pull requests, including bodies, refs, merge state,
  23 conversation comments, and 18 reviews.
- `labels.json`, `milestones.json`, and `releases.json`: the remaining tracker
  metadata (there were no milestones or releases at capture time).
- `open-pr-mapping.tsv`: Forgejo PR numbers mapped to the recreated open GitHub
  PR numbers.
- `issue-mapping.tsv`: Forgejo issue numbers mapped to retained or recreated
  GitHub issue numbers.
- `forgejo-refs.txt`: the Forgejo branch/tag ref snapshot used for the code
  synchronization.

GitHub's supported Git importer copies source and commit history but does not
copy issues or pull requests from Forgejo. GitHub's normal issue/PR APIs also
cannot preserve original item numbers, authors, or timestamps. The live GitHub
tracker therefore contains the actionable open items with explicit Forgejo
provenance, while this archive retains the complete source metadata without
pretending that GitHub-created records are originals.

No pull request was merged as part of this restoration.
