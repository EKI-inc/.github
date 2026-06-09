# EKI Default GitHub Templates

This public special repository provides default GitHub community files for repositories in the `EKI-inc` organization.

GitHub uses files from this repository only when a target repository does not define its own file of the same type. If a repository has any local `.github/ISSUE_TEMPLATE` files or config, its local issue template set overrides these defaults.

## Defaults

- [Digital project / IT intake](.github/ISSUE_TEMPLATE/project-intake.yml): rendered issue form for early routing before repository setup, access changes, infrastructure, data/risk review, or IT coordination.
- [Task](.github/ISSUE_TEMPLATE/task.yml): rendered issue form for actionable work, follow-ups, fixes, documentation updates, and implementation steps.
- [Bug fix](.github/ISSUE_TEMPLATE/bug-fix.yml): rendered issue form for defects, regressions, reproduction steps, expected behavior, fix notes, and test cases.
- [Application gallery inventory](.github/ISSUE_TEMPLATE/gallery-inventory.yml): rendered issue form for collecting metadata that can be translated into `.github/eki-inventory.yml` in the source repository.
- [Pull request template](.github/PULL_REQUEST_TEMPLATE.md): default pull request checklist for scope, linked work, review focus, urgency, LOE, risk, validation, merge ownership, and follow-up work.

## Automation

- [Create gallery inventory PR](.github/workflows/create-gallery-inventory-pr.yml): when an organization member or collaborator opens a `Gallery inventory:` issue in this repository, the workflow parses the issue form and opens or updates a pull request adding `.github/eki-inventory.yml` in the submitted `EKI-inc` repository URL.

The gallery inventory workflow requires a repository secret named `ORG_INVENTORY_PR_TOKEN`. Use a GitHub App token or fine-grained personal access token with access to the target repositories and these permissions:

- Contents: read/write
- Pull requests: read/write
- Metadata: read

## Notes For Maintainers

- Keep this repository public and free of private scripts, internal runbooks, secrets, or client-specific material.
- Automation workflows do not become org-wide defaults from this repository; each target repository must still define or call its own workflows.
- Labels and assignees are intentionally omitted from the shared issue forms so the templates render reliably across repositories that do not share the same label set or collaborator list.
