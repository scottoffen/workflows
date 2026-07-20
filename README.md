# Shared GitHub Actions workflows

Reusable workflows for the .NET OSS projects under [@scottoffen](https://github.com/scottoffen). They cover the build/test/publish cycle, prerelease package cleanup, and Docusaurus documentation deploys.

This repository is public because GitHub requires a personal-account reusable workflow to be public if any caller repo is public. Public visibility does not expose secrets; secrets are referenced from the calling repo's settings, not from this one.

## Contents

- [What's in here](#whats-in-here)
- [Quick setup checklist](#quick-setup-checklist)
- [Requirements in the consuming repo](#requirements-in-the-consuming-repo)
  - [Secrets](#secrets)
  - [Where to put the secrets](#where-to-put-the-secrets)
  - [Solo setup: repository secrets](#solo-setup-repository-secrets)
  - [Team setup: environment secrets](#team-setup-environment-secrets)
  - [What environment secrets don't do](#what-environment-secrets-dont-do)
- [Build and publish workflow](#build-and-publish-workflow)
  - [How the preflight skip plays with branch protection](#how-the-preflight-skip-plays-with-branch-protection)
- [Cleanup workflow](#cleanup-workflow)
- [Docusaurus deploy workflow](#docusaurus-deploy-workflow)
  - [First-time Pages setup in the consuming repo](#first-time-pages-setup-in-the-consuming-repo)
  - [Why `concurrency` and `permissions` aren't inputs](#why-concurrency-and-permissions-arent-inputs)
- [Stale workflow](#stale-workflow)
- [License](#license)

## What's in here

| Workflow | File | Purpose |
|---|---|---|
| Build and publish | `.github/workflows/dotnet-build-and-publish.yml` | Restore, build, test, optionally push to GitHub Packages and/or NuGet.org. Tags and creates a GitHub Release on a successful NuGet push. |
| Cleanup packages | `.github/workflows/dotnet-cleanup-packages.yml` | Delete prerelease versions from GitHub Packages, either all of them or those older than N days. Never touches release versions. |
| Docusaurus deploy | `.github/workflows/docusaurus-deploy-pages.yml` | Build a Docusaurus site and deploy it to GitHub Pages. |
| Stale | `.github/workflows/stale.yml` | Mark and close stale issues and pull requests on a schedule. |

The `examples/` directory contains ready-to-copy caller templates that wire these workflows up for a typical project.

---

## Quick setup checklist

For when it's not my first rodeo. Assumes the repo already exists on GitHub with source code, a solution file, `Directory.Build.props`, and NBGV configured. I substitute the new repo name for `<repo>` throughout. For docs-only repos, I skip steps that mention packages or NuGet. For repos without docs, I skip step 4.

### 1. Copy the caller templates

```bash
gh repo clone scottoffen/<repo>
cd <repo>
mkdir -p .github/workflows

# from a local clone of scottoffen/workflows
cp /path/to/workflows/examples/{pr-build,publish,cleanup,deploy-docs,stale}.yml .github/workflows/
```

### 2. Edit the inputs

Open each copied workflow and update the project-specific bits. Most edits are in `pr-build.yml` and `publish.yml`; the others are usually a one-line change or no change at all.

- `pr-build.yml` and `publish.yml`: set `solution-path` (e.g. `src/<repo>.sln`). Adjust `include-paths` / `ignore-paths` / `paths:` if the source tree differs from `src/`.
- `cleanup.yml`: replace the `package-names` block with the actual NuGet IDs this repo ships.
- `deploy-docs.yml`: usually no change. Edit `docs-path` only if Docusaurus lives somewhere other than `docs/`.

### 3. Add the secrets

```bash
gh secret set NUGET_API_KEY         --repo scottoffen/<repo>
gh secret set PACKAGES_DELETE_TOKEN --repo scottoffen/<repo>
```

`GITHUB_TOKEN` is auto-provisioned; nothing to do for that one.

### 4. Enable GitHub Pages (docs repos only)

In the repo's web UI: **Settings → Pages → Source: GitHub Actions**. Without this, the first deploy fails with an error that doesn't clearly point at the source setting.

### 5. Set branch protection

```bash
gh api -X PUT "repos/scottoffen/<repo>/branches/main/protection" \
  --input - <<'EOF'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["build"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null
}
EOF
```

The `"build"` context name must match the job key in `pr-build.yml`. If I renamed the job, the context needs to match.

### 6. Commit and push

```bash
git add .github/workflows/
git commit -m "Add CI workflows"
git push
```

### 7. Verify

Open a throwaway PR with any small change under `src/` and confirm the `build` check runs and passes. Then merge to `main` and confirm the publish workflow pushes the branch package to GitHub Packages. Both should happen with no manual intervention.

The first NuGet.org publish is manual: **Actions → Publish → Run workflow → push to NuGet.org: true**. Subsequent ones follow the same pattern.

---

## Requirements in the consuming repo

The reusable build workflow assumes a layout that matches the OSS .NET conventions in use across these projects:

- A solution file somewhere under the repo (path given by the `solution-path` input).
- `Directory.Build.props` at the solution root with `GeneratePackageOnBuild=true` and `TreatWarningsAsErrors=true`. Packages are produced as a side effect of `dotnet build`; no separate `dotnet pack` runs.
- [Nerdbank.GitVersioning](https://github.com/dotnet/Nerdbank.GitVersioning) configured at the solution root. The publish path uses `dotnet nbgv get-version` to derive the tag name.
- No `global.json` at the solution root. The workflow installs the SDK specified by the `dotnet-version` input (default `10.0.x`) regardless of any `global.json` present. If a consuming repo introduces a `global.json` later, either remove it or align it with the input value to avoid "SDK not found" errors.
- A test discriminator on integration tests when I want them excluded from the gate. The default `test-filter` is `Category!=Integration`; an empty string runs everything.

### Secrets

These workflows use three secrets. One is auto-provisioned; I set up the other two.

| Secret | Required for | Setup needed |
|---|---|---|
| `GITHUB_TOKEN` | GitHub Packages push, tagging, releases | None. Auto-provisioned by Actions every run. |
| `NUGET_API_KEY` | NuGet.org push | I set this up. Only required when `push-nuget: true`. |
| `PACKAGES_DELETE_TOKEN` | Cleanup workflow | I set this up. PAT with the `delete:packages` scope. The default `GITHUB_TOKEN` cannot delete user-scoped package versions, which is why a PAT is needed. |
| `CODECOV_TOKEN` | Coverage upload | Optional for public repos (Codecov accepts tokenless uploads), recommended to avoid rate limits. Required for private repos. Only relevant when `upload-coverage: true`. |

The example callers all use `secrets: inherit`, which forwards every secret defined on the calling repo. An explicit `secrets:` block is an option if I ever want to scope forwarded secrets more tightly.

### Where to put the secrets

On a personal GitHub account, two storage locations are available for Actions secrets: **repository secrets** and **environment secrets**. There is no account-level shared store for Actions; that's an organization feature. Each consuming repo gets its own copy of each secret either way.

**I use repository secrets.** As a solo maintainer, environment secrets would add gates designed for teams (approval reviewers, branch restrictions, wait timers) that don't meaningfully protect me from myself. The cost is friction on every publish; the benefit is theoretical.

The team-setup section below documents the environment-secret approach for the day this changes, or for anyone else copying this setup.

### Solo setup: repository secrets

For each consuming repo:

```bash
gh secret set NUGET_API_KEY        --repo scottoffen/<repo>
gh secret set PACKAGES_DELETE_TOKEN --repo scottoffen/<repo>
```

The CLI prompts for the value, or it can be piped in. Or the web UI: **Settings → Secrets and variables → Actions → New repository secret**.

Adding a new project later is two commands. Scripting the rest of the bootstrap (copying the example callers, setting branch protection) makes the whole thing a single shell function.

### Team setup: environment secrets

When more than one person can trigger publishes, environment-scoped secrets let me require approval and restrict which branches can use the key. Two environments are useful here:

- **`nuget-org`** wraps `NUGET_API_KEY`. Protects against accidental or malicious pushes to NuGet.org, which are reputationally hard to recover from.
- **`package-cleanup`** wraps `PACKAGES_DELETE_TOKEN`. Protects against accidental destruction of prerelease history.

Setup per repo:

1. **Settings → Environments → New environment**, name it `nuget-org`. Repeat for `package-cleanup`.
2. On each environment, configure protection rules: required reviewers (myself at minimum) and "Deployment branches" set to `main` only.
3. Add the secret to the environment rather than the repo: **Settings → Environments → nuget-org → Add secret**, name `NUGET_API_KEY`. Same idea for `PACKAGES_DELETE_TOKEN` under `package-cleanup`.

CLI equivalent:

```bash
gh secret set NUGET_API_KEY        --repo scottoffen/<repo> --env nuget-org
gh secret set PACKAGES_DELETE_TOKEN --repo scottoffen/<repo> --env package-cleanup
```

The reusable workflow's job needs to declare which environment it's deploying to for the secret to be available. The build workflow accepts an optional `environment` input for this; the cleanup workflow accepts the same. Set them in the caller:

```yaml
# in publish.yml
jobs:
  publish:
    uses: scottoffen/workflows/.github/workflows/dotnet-build-and-publish.yml@main
    with:
      # ... existing inputs ...
      environment: nuget-org   # only set this when push-nuget might be true
    secrets: inherit
```

When the workflow reaches the NuGet push step, GitHub pauses the run and waits for a reviewer to approve in the Actions UI. After approval, the secret is injected and the step runs.

Leave `environment:` unset on the PR build caller; PR builds don't push to NuGet and don't need a gate.

### What environment secrets don't do

A few things worth being explicit about, since the docs imply more than the feature delivers:

- They're not encrypted differently from repository secrets.
- They don't share across repos; each repo still needs its own copy.
- They're not invisible to the workflow once the gate passes; after approval the secret is a normal env var.
- They don't protect against a malicious workflow change merged to `main`. Once a malicious workflow is on the allowed branch, an environment gate only delays it until someone clicks approve.

The protection is real but narrow: it blocks workflow runs on unapproved branches, and runs triggered by unapproved users, from using the secret at all. It also creates a deliberate moment to notice something off before the push happens.

---

## Build and publish workflow

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `solution-path` | string | (required) | Path to the `.sln` file. |
| `dotnet-version` | string | `10.0.x` | SDK version for `actions/setup-dotnet`. |
| `runs-on` | string | `ubuntu-latest` | Runner label for the build job. Override for `windows-latest`, `macos-latest`, or a self-hosted label. The job pins `shell: bash` for its run steps regardless, since the scripts use bash-only syntax; both Windows and macOS GitHub-hosted images ship bash. |
| `check-paths` | boolean | `false` | Run the preflight gate and only build when relevant files changed. Set to `true` for PR builds; leave `false` for push and manual runs. |
| `include-paths` | string | `src/**` | Multi-line glob list of paths that count as relevant changes. |
| `ignore-paths` | string | `**/*.md` | Multi-line glob list of paths to ignore even if they match `include-paths`. |
| `artifacts-search-root` | string | `src` | Directory under which to find produced `.nupkg` and `.snupkg` files. |
| `test-filter` | string | `Category!=Integration` | Value passed to `dotnet test --filter`. Empty string runs all tests. |
| `push-github` | boolean | `false` | Push the built packages to GitHub Packages. |
| `push-nuget` | boolean | `false` | Push to NuGet.org. On a successful push, creates a git tag and a GitHub Release. |
| `environment` | string | `''` | Optional environment name. Leave empty for repository secrets. Set to e.g. `nuget-org` to use environment-scoped secrets and protection rules. See [Team setup](#team-setup-environment-secrets). |
| `verify-format` | boolean | `false` | Run `dotnet format --verify-no-changes` as a gate before build. Opt-in: enabling on a codebase that has never been formatted will fail every PR until `dotnet format` is run locally and the result committed. |
| `upload-coverage` | boolean | `false` | Collect coverage during `dotnet test` and upload to Codecov. Requires a one-time Codecov signup for the consuming repo. Public repos can upload tokenless; private repos need `CODECOV_TOKEN` set. |

### How the preflight skip plays with branch protection

Branch protection on `main` requires a `build` status check. The build workflow has no path filter on its trigger, so it runs on every PR, which keeps branch protection happy. Inside the workflow, a preflight job decides whether the build job actually runs. When the preflight says no, the build job is skipped, and a skipped job reports as success to branch protection. Doc-only PRs sail through without rebuilding.

Two things to know:

- The required status check name is whatever I call the **caller's** job, not anything inside the reusable workflow. The example caller names it `build`; renaming it means updating the branch protection rule.
- `should-run` comes from [scottoffen/should-run](https://github.com/scottoffen/should-run), which uses the Compare API rather than local git. It works correctly on shallow clones.

---

## Cleanup workflow

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `package-names` | string | (required) | Multi-line list of NuGet package IDs to sweep, one per line. |
| `mode` | string | (required) | `prerelease-only` deletes every prerelease version. `older-than-days` deletes prereleases older than `days` days. |
| `days` | number | `30` | Only used with `older-than-days`. |
| `dry_run` | boolean | `true` | List what would be deleted without actually deleting. |
| `environment` | string | `''` | Optional environment name. Leave empty for repository secrets. Set to e.g. `package-cleanup` to use environment-scoped secrets and protection rules. See [Team setup](#team-setup-environment-secrets). |

Release versions (no `-` segment in the SemVer string) are never deleted, regardless of mode.

---

## Docusaurus deploy workflow

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `docs-path` | string | `docs` | Path to the Docusaurus project root (the directory containing `package.json`). |
| `build-output-subdir` | string | `build` | Subdirectory of `docs-path` containing the built site. Docusaurus default is `build`. |
| `node-version` | string | `20` | Node.js version for `actions/setup-node`. |
| `install-command` | string | `npm ci` | Command to install dependencies. Override for Yarn or pnpm. |
| `build-command` | string | `npm run build` | Command to build the site. |

### First-time Pages setup in the consuming repo

Two pieces of one-time configuration. Both are clicked once and stick:

1. **Settings → Pages → Source: GitHub Actions.** Without this, `actions/deploy-pages` fails with an error that does not clearly point at the source setting.
2. The first deploy creates a `github-pages` environment automatically. No need to create it manually. It appears under **Settings → Environments** after the first successful run.

The workflow itself does not deploy from PRs, only from `main` and from manual `workflow_dispatch` runs, so there's no concern about preview deploys from forks.

### Why `concurrency` and `permissions` aren't inputs

The Pages deployment model fixes these:

- The `concurrency: pages` group is required to serialize Pages deploys within a repo. GitHub Pages itself only accepts one in-progress deployment at a time, so the workflow's concurrency setting matches that constraint.
- `pages: write` and `id-token: write` are exactly what `actions/deploy-pages` requires (the latter for OIDC). `contents: read` is needed for checkout.
- The `environment: github-pages` name is mandatory; `actions/deploy-pages` rejects any other name.

Treating any of these as inputs would invite misconfiguration without enabling any real flexibility.

---

## Stale workflow

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `days-before-issue-stale` | number | `60` | Days of inactivity before an issue is marked stale. |
| `days-before-issue-close` | number | `7` | Days after stale-marking before an issue is closed. |
| `days-before-pr-stale` | number | `30` | Days of inactivity before a PR is marked stale. PRs default to a shorter timeline than issues because inactive PRs are usually dead. |
| `days-before-pr-close` | number | `7` | Days after stale-marking before a PR is closed. |
| `exempt-issue-labels` | string | `pinned,security,help wanted,good first issue` | Comma-separated labels that exempt an issue from staling. |
| `exempt-pr-labels` | string | `pinned,security,work in progress` | Comma-separated labels that exempt a PR from staling. |

The stale label applied to flagged items is hardcoded to `stale` for both issues and PRs so there's only one place to look. Stale and close messages are also hardcoded to keep tone consistent across repos.

---

## License

MIT. See [LICENSE](LICENSE).