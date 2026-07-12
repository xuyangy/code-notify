# Contributing

Thanks for your interest in Code-Notify.

The full contributing guide lives at [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md).

Quick checklist:

- Search existing issues before opening a new one.
- Include your OS, shell, install method, and AI tool when reporting bugs.
- Run `bash scripts/run_tests.sh` before submitting a pull request.
- Update docs when behavior or commands change.

## Publishing a release

Releases are source-only and use CalVer tags in the form
`vYYYY.MM.PATCH`. For example, the first release in July 2026 is
`v2026.07.0`; additional releases that month are `v2026.07.1`,
`v2026.07.2`, and so on. Reset `PATCH` to zero when the month changes.

1. Update the version in `bin/code-notify`, both version declarations in
   `scripts/install-windows.ps1`, `package.json`, and the README badge/examples.
2. Add `docs/releases/vYYYY.MM.PATCH.md` with the user-visible changes since the
   previous release.
3. Run `bash scripts/run_tests.sh`, then merge the version bump and release notes
   to `main`.
4. Create and push a tag such as `v2026.07.0`.

Pushing the tag runs the release workflow. It verifies that the tag matches the
embedded versions, requires the matching release-notes file, runs the test
suite, and creates a GitHub Release with those notes and GitHub's automatic
source `.zip` and `.tar.gz` downloads.
It does not publish to npm or Homebrew.
