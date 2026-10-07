# Shared GitHub Actions Workflows

Reusable GitHub Actions workflows for the OSS projects under [@scottoffen](https://github.com/scottoffen). The workflows are grouped by ecosystem: .NET, Docusaurus, PHP, and WordPress, plus a group for general repository hygiene.

This repository is public because GitHub requires a personal-account reusable workflow to be public if any caller repo is public. Public visibility does not expose secrets. Secrets are referenced from the calling repo's settings, not from this one.

## Contents

- [Overview](#overview)
- [Using the Workflows](#using-the-workflows)
  - [Calling a Workflow](#calling-a-workflow)
  - [Responsibilities of the Caller](#responsibilities-of-the-caller)
  - [Required Status Checks](#required-status-checks)
- [.NET Workflows](#net-workflows)
  - [Build and Publish](#build-and-publish)
  - [Cleanup Packages](#cleanup-packages)
  - [.NET Secrets](#net-secrets)
  - [.NET Setup](#net-setup)
- [Docusaurus Workflows](#docusaurus-workflows)
  - [Docusaurus Deploy](#docusaurus-deploy)
- [PHP Workflows](#php-workflows)
  - [PHP Tests](#php-tests)
  - [PHP Release](#php-release)
- [WordPress Workflows](#wordpress-workflows)
  - [WordPress Packaging Script](#wordpress-packaging-script)
  - [WordPress Package](#wordpress-package)
- [Repository Hygiene Workflows](#repository-hygiene-workflows)
  - [Stale](#stale)
- [License](#license)

---

## Overview

| Category | Name | File | Purpose |
|---|---|---|---|
| .NET | [Build and Publish](#build-and-publish) | `.github/workflows/dotnet-build-and-publish.yml` | Restore, build, test, and optionally push to GitHub Packages and/or NuGet.org. Tags and creates a GitHub Release on a successful NuGet push. |
| .NET | [Cleanup Packages](#cleanup-packages) | `.github/workflows/dotnet-cleanup-packages.yml` | Delete prerelease versions from GitHub Packages, either all of them or those older than N days. Never touches release versions. |
| Docusaurus | [Docusaurus Deploy](#docusaurus-deploy) | `.github/workflows/docusaurus-deploy-pages.yml` | Build a Docusaurus site and deploy it to GitHub Pages. |
| PHP | [PHP Tests](#php-tests) | `.github/workflows/php-tests.yml` | Run a PHP package's tests with Composer on a matrix of PHP versions. |
| PHP | [PHP Release](#php-release) | `.github/workflows/php-release.yml` | Check the version, run the PHP tests on the exact commit, then create the tag and the GitHub Release for a package published on Packagist. |
| WordPress | [WordPress Packaging Script](#wordpress-packaging-script) | `scripts/wordpress-package.ps1` | PowerShell script that builds an installable zip for every theme and plugin under `src/`. It runs the same way locally and in CI. |
| WordPress | [WordPress Package](#wordpress-package) | `.github/workflows/wordpress-package.yml` | Run the repo's packaging script in CI and upload the zips it writes as one artifact. Pull request builds label each zip with the PR number. |
| Repository hygiene | [Stale](#stale) | `.github/workflows/stale.yml` | Mark and close stale issues and pull requests on a schedule. |

The `examples/` directory contains ready-to-copy caller templates for each workflow. The `scripts/` directory contains the scripts that the workflows rely on. When a workflow expects a script to exist in each consuming repo, the copy here is the template to start from. The section for each workflow describes the scripts it needs.

---

## Using the Workflows

### Calling a Workflow

Every workflow is called from a small caller workflow in the consuming repo. The general procedure is the same for all of them and consists of the following steps:

1. Copy the matching file from `examples/` to `.github/workflows/` in the consuming repo.
2. Edit the inputs that differ from the defaults.
3. Add any secrets the workflow requires.

Each category section below lists the specifics under its Setup heading.

A caller references a workflow by repository, path, and ref, as in the following example:

```yaml
jobs:
  example:
    uses: scottoffen/workflows/.github/workflows/<file>@main
```

Callers track `main`, so a change merged to this repository applies to every consumer on its next run. The `lint.yml` workflow in this repository runs actionlint on every pull request to catch mistakes before they reach `main`.

### Responsibilities of the Caller

A reusable workflow cannot define everything about how it runs. The caller is responsible for the following:

- **Triggers.** A reusable workflow has no triggers of its own. The caller defines the events, schedules, and `workflow_dispatch` form fields, and passes the values in as inputs.
- **Concurrency.** The caller sets `concurrency` for the workflows where it matters. The exception is the Docusaurus deploy, where the Pages deployment model fixes it. See [Docusaurus Deploy](#docusaurus-deploy).
- **Permissions.** A reusable workflow cannot grant itself more access than the job that calls it. Where a workflow needs specific permissions, the example caller grants them.
- **Secrets.** Secrets are passed from the caller. The .NET examples use `secrets: inherit`.

### Required Status Checks

A required status check is a check that must pass before a pull request can be merged. A branch protection rule lists the checks it requires by name, and each name must match exactly.

When a workflow runs on a pull request, GitHub lists every job as a check named in the form `<caller job key> / <job name>`. The first part is the key of the job in the caller's workflow file. The second part is the `name` of the job inside the reusable workflow. For example, the `tests` job in a PHP package's caller runs the PHP tests workflow, and it produces checks named `tests / PHP 8.1`, `tests / PHP 8.2`, and so on. A branch protection rule must use these full names.

Renaming the key of the caller's job changes the names of its checks. The rule then waits for a name that never appears, and pull requests cannot be merged until the rule is updated.

A workflow trigger can include a path filter, such as running only when files under `src/` change. When a pull request does not touch those paths, the workflow does not run, so its checks never appear. If one of those checks is required, GitHub waits for it indefinitely, and the pull request cannot be merged. For this reason, the callers for the build, test, and package workflows have no path filter, and their checks run on every pull request. The .NET build workflow still avoids unnecessary builds by deciding inside the workflow whether to do the work. See [Preflight and Branch Protection](#preflight-and-branch-protection).

---

## .NET Workflows

Two workflows cover the .NET build, publish, and cleanup cycle: [Build and Publish](#build-and-publish) and [Cleanup Packages](#cleanup-packages). Both use secrets, described in [.NET Secrets](#net-secrets). The [.NET Setup](#net-setup) section is the procedure for wiring a new repo.

### Build and Publish

Restores, builds, and tests a solution. It can push the resulting packages to GitHub Packages and/or NuGet.org. A successful NuGet push also creates a git tag and a GitHub Release.

#### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `solution-path` | string | (required) | Path to the `.sln` file. |
| `dotnet-version` | string | `10.0.x` | SDK version for `actions/setup-dotnet`. |
| `runs-on` | string | `ubuntu-latest` | Runner label for the build job. Override for `windows-latest`, `macos-latest`, or a self-hosted label. The job pins `shell: bash` for its run steps regardless, since the scripts use bash-only syntax. Both Windows and macOS GitHub-hosted images ship bash. |
| `check-paths` | boolean | `false` | Run the preflight gate and only build when relevant files changed. Set to `true` for PR builds. Leave `false` for push and manual runs. |
| `include-paths` | string | `src/**` | Multi-line glob list of paths that count as relevant changes. |
| `ignore-paths` | string | `**/*.md` | Multi-line glob list of paths to ignore even if they match `include-paths`. |
| `artifacts-search-root` | string | `src` | Directory under which to find produced `.nupkg` and `.snupkg` files. |
| `test-filter` | string | `Category!=Integration` | Value passed to `dotnet test --filter`. An empty string runs all tests. |
| `push-github` | boolean | `false` | Push the built packages to GitHub Packages. |
| `push-nuget` | boolean | `false` | Push to NuGet.org. On a successful push, creates a git tag and a GitHub Release. |
| `environment` | string | `''` | Optional environment name. Leave empty for repository secrets. Set to a name such as `nuget-org` to use environment-scoped secrets and protection rules. See [.NET Secrets](#net-secrets). |
| `verify-format` | boolean | `false` | Run `dotnet format --verify-no-changes` as a gate before build. Opt-in: enabling it on a codebase that has never been formatted fails every PR until `dotnet format` is run locally and the result committed. |
| `upload-coverage` | boolean | `false` | Collect coverage during `dotnet test` and upload to Codecov. Requires a one-time Codecov signup for the consuming repo. Public repos can upload tokenless. Private repos need `CODECOV_TOKEN` set. |

#### Requirements in the Consuming Repo

The workflow assumes a layout that matches the OSS .NET conventions in use across these projects. The consuming repo must meet the following requirements:

- **A solution file.** The solution file exists somewhere under the repo, at the path given by the `solution-path` input.
- **A `Directory.Build.props` file.** The file sits at the solution root with `GeneratePackageOnBuild=true` and `TreatWarningsAsErrors=true`. Packages are produced as a side effect of `dotnet build`, and no separate `dotnet pack` runs.
- **Nerdbank.GitVersioning.** [Nerdbank.GitVersioning](https://github.com/dotnet/Nerdbank.GitVersioning) is configured at the solution root. The publish path uses `dotnet nbgv get-version` to derive the tag name.
- **No `global.json`.** The solution root has no `global.json`, because the workflow installs the SDK specified by the `dotnet-version` input regardless of any `global.json` present. If a consuming repo adds a `global.json`, either remove it or align it with the input value to avoid "SDK not found" errors.
- **A test discriminator on integration tests.** The discriminator is needed only when integration tests should be excluded from the gate. The default `test-filter` is `Category!=Integration`, and an empty string runs everything.

#### Preflight and Branch Protection

Branch protection on `main` requires a `build` status check. The build workflow has no path filter on its trigger, so it runs on every PR, which satisfies branch protection. Inside the workflow, a preflight job decides whether the build job actually runs. When the preflight says no, the build job is skipped, and a skipped job reports as success to branch protection. Documentation-only PRs pass without rebuilding.

The following two details apply:

- The required status check name comes from the **caller's** job name, not from anything inside the reusable workflow. The example caller names the job `build`. Renaming it means updating the branch protection rule.
- `should-run` comes from [scottoffen/should-run](https://github.com/scottoffen/should-run), which uses the Compare API rather than local git. It works correctly on shallow clones.

### Cleanup Packages

Deletes prerelease versions of NuGet packages from GitHub Packages. Release versions (no `-` segment in the SemVer string) are never deleted, regardless of mode.

#### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `package-names` | string | (required) | Multi-line list of NuGet package IDs to sweep, one per line. |
| `mode` | string | (required) | `prerelease-only` deletes every prerelease version. `older-than-days` deletes prereleases older than `days` days. |
| `days` | number | `30` | Only used with `older-than-days`. |
| `dry-run` | boolean | `true` | List what would be deleted without actually deleting. |
| `environment` | string | `''` | Optional environment name. Leave empty for repository secrets. Set to a name such as `package-cleanup` to use environment-scoped secrets and protection rules. See [.NET Secrets](#net-secrets). |

### .NET Secrets

The .NET workflows use the secrets below. `GITHUB_TOKEN` is provisioned automatically. The others are set on each consuming repo.

#### Secret Reference

| Secret | Required for | Setup needed |
|---|---|---|
| `GITHUB_TOKEN` | GitHub Packages push, tagging, releases | None. Auto-provisioned by Actions on every run. |
| `NUGET_API_KEY` | NuGet.org push | Set per repo. Only required when `push-nuget: true`. |
| `PACKAGES_DELETE_TOKEN` | Cleanup Packages | Set per repo. A PAT with the `delete:packages` scope. The default `GITHUB_TOKEN` cannot delete user-scoped package versions, which is why a PAT is needed. |
| `CODECOV_TOKEN` | Coverage upload | Optional for public repos, since Codecov accepts tokenless uploads, but recommended to avoid rate limits. Required for private repos. Only relevant when `upload-coverage: true`. |

The example callers use `secrets: inherit`, which forwards every secret defined on the calling repo. An explicit `secrets:` block scopes the forwarded secrets more tightly.

#### Where to Put Secrets

On a personal GitHub account, two storage locations are available for Actions secrets: **repository secrets** and **environment secrets**. There is no account-level shared store for Actions. That is an organization feature. Each consuming repo needs its own copy of each secret either way.

Repository secrets are the default for a solo maintainer. Environment secrets add gates designed for teams, such as approval reviewers, branch restrictions, and wait timers, which give a single maintainer little protection. The cost is friction on every publish. The team approach is documented below for repos where more than one person can trigger publishes.

#### Repository Secrets

Run the following commands for each consuming repo:

```bash
gh secret set NUGET_API_KEY         --repo scottoffen/<repo>
gh secret set PACKAGES_DELETE_TOKEN --repo scottoffen/<repo>
```

The CLI prompts for the value, or the value can be piped in. The web UI equivalent is **Settings → Secrets and variables → Actions → New repository secret**.

#### Environment Secrets

When more than one person can trigger publishes, environment-scoped secrets add approval and branch restrictions. The following two environments are useful:

- **`nuget-org`** wraps `NUGET_API_KEY`. It protects against accidental or malicious pushes to NuGet.org, which are reputationally hard to recover from.
- **`package-cleanup`** wraps `PACKAGES_DELETE_TOKEN`. It protects against accidental destruction of prerelease history.

Setup for each repo consists of the following steps:

1. In **Settings → Environments → New environment**, create `nuget-org`. Repeat for `package-cleanup`.
2. On each environment, configure protection rules: required reviewers (at least one maintainer) and "Deployment branches" set to `main` only.
3. Add the secret to the environment rather than the repo: **Settings → Environments → nuget-org → Add secret**, named `NUGET_API_KEY`. Do the same for `PACKAGES_DELETE_TOKEN` under `package-cleanup`.

The CLI equivalent of adding the secrets is as follows:

```bash
gh secret set NUGET_API_KEY         --repo scottoffen/<repo> --env nuget-org
gh secret set PACKAGES_DELETE_TOKEN --repo scottoffen/<repo> --env package-cleanup
```

The reusable workflow's job must declare which environment it deploys to for the secret to be available. Both the build and cleanup workflows accept an optional `environment` input for this. Set it in the caller, as in the following example:

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

Leave `environment:` unset on the PR build caller. PR builds do not push to NuGet and do not need a gate.

#### Environment Secret Limits

Environment secrets have the following limits, which the GitHub documentation does not make obvious:

- They are not encrypted differently from repository secrets.
- They are not shared across repos. Each repo still needs its own copy.
- They are not invisible to the workflow once the gate passes. After approval, the secret is a normal environment variable.
- They do not protect against a malicious workflow change merged to `main`. Once a malicious workflow is on the allowed branch, an environment gate only delays it until someone approves.

The protection is real but narrow. It blocks workflow runs on unapproved branches, and runs triggered by unapproved users, from using the secret at all. It also creates a deliberate moment to notice something wrong before the push happens.

### .NET Setup

This procedure assumes the repo already exists on GitHub with source code, a solution file, `Directory.Build.props`, and Nerdbank.GitVersioning configured. Substitute the new repo name for `<repo>` throughout. Repos that do not publish documentation or use the stale workflow can skip those setups. See [Docusaurus Deploy](#docusaurus-deploy) and [Stale](#stale).

#### 1. Copy the Caller Templates

```bash
gh repo clone scottoffen/<repo>
cd <repo>
mkdir -p .github/workflows

# from a local clone of scottoffen/workflows
cp /path/to/workflows/examples/{pr-build,publish,cleanup}.yml .github/workflows/
```

#### 2. Edit the Inputs

Open each copied workflow and update the project-specific values. Most edits are in `pr-build.yml` and `publish.yml`. `cleanup.yml` usually needs one change.

- `pr-build.yml` and `publish.yml`: set `solution-path` (for example `src/<repo>.sln`). Adjust `include-paths`, `ignore-paths`, and `paths:` if the source tree differs from `src/`.
- `cleanup.yml`: replace the `package-names` block with the NuGet IDs the repo ships.

#### 3. Add the Secrets

```bash
gh secret set NUGET_API_KEY         --repo scottoffen/<repo>
gh secret set PACKAGES_DELETE_TOKEN --repo scottoffen/<repo>
```

`GITHUB_TOKEN` is auto-provisioned and needs no setup. See [.NET Secrets](#net-secrets) for environment-scoped alternatives.

#### 4. Set Branch Protection

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

The `"build"` context name must match the job key in `pr-build.yml`. If the job was renamed, the context must be renamed to match.

#### 5. Commit and Push

```bash
git add .github/workflows/
git commit -m "Add CI workflows"
git push
```

#### 6. Verify

1. Open a throwaway PR with any small change under `src/` and confirm the `build` check runs and passes.
2. Merge to `main` and confirm the publish workflow pushes the branch package to GitHub Packages. Both steps should complete with no manual intervention.

The first NuGet.org publish is manual: **Actions → Publish → Run workflow → push to NuGet.org: true**. Subsequent publishes follow the same pattern.

---

## Docusaurus Workflows

### Docusaurus Deploy

Builds a Docusaurus site and deploys it to GitHub Pages. The workflow deploys only from `main` and from manual `workflow_dispatch` runs, never from pull requests, so there is no preview deploy from forks.

#### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `docs-path` | string | `docs` | Path to the Docusaurus project root, which is the directory containing `package.json`. |
| `build-output-subdir` | string | `build` | Subdirectory of `docs-path` containing the built site. The Docusaurus default is `build`. |
| `node-version` | string | `20` | Node.js version for `actions/setup-node`. |
| `install-command` | string | `npm ci` | Command to install dependencies. Override for Yarn or pnpm. |
| `build-command` | string | `npm run build` | Command to build the site. |

#### Why Concurrency and Permissions Are Not Inputs

The Pages deployment model fixes the following values:

- The `concurrency: pages` group is required to serialize Pages deploys within a repo. GitHub Pages accepts only one in-progress deployment at a time, so the workflow's concurrency setting matches that constraint.
- `pages: write` and `id-token: write` are exactly what `actions/deploy-pages` requires, the latter for OIDC. `contents: read` is needed for checkout.
- The `environment: github-pages` name is mandatory. `actions/deploy-pages` rejects any other name.

Treating any of these as inputs would invite misconfiguration without enabling any real flexibility.

#### Setup

1. Copy `examples/deploy-docs.yml` to `.github/workflows/deploy-docs.yml` in the consuming repo. No changes are usually needed. Set `docs-path` only if Docusaurus lives somewhere other than `docs/`.
2. In the repo's web UI, set **Settings → Pages → Source: GitHub Actions**. Without this, the first deploy fails with an error that does not clearly point at the source setting.
3. Push to `main` and confirm the deploy succeeds.

The first deploy creates a `github-pages` environment automatically. It does not need to be created manually, and it appears under **Settings → Environments** after the first successful run.

---

## PHP Workflows

Two workflows cover PHP packages published on Packagist: [PHP Tests](#php-tests) and [PHP Release](#php-release). The release workflow calls the tests workflow, so a release is gated on the same matrix that pull requests get.

### PHP Tests

Runs a PHP package's test suite on a matrix of PHP versions. It does not publish or release anything. A repo's own tests workflow calls it for pushes and pull requests, and [PHP Release](#php-release) calls it to gate a release.

#### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `php-versions` | string | `["8.1","8.2","8.3","8.4"]` | JSON array of PHP versions to test against. It is a JSON string because workflow inputs cannot be arrays. |
| `test-command` | string | `composer test` | Command that runs the tests. |
| `runs-on` | string | `ubuntu-latest` | Runner label for the jobs. The run steps pin `shell: bash`, which every GitHub-hosted image ships. |

#### How It Works

Each version in `php-versions` gets its own job, named `PHP <version>`. Every job runs the following steps in order:

1. The job checks out the repo.
2. The job sets up that PHP version, with coverage turned off.
3. The job runs `composer install --no-interaction --no-progress --prefer-dist`.
4. The job runs the test command.

`fail-fast` is off, so one failing PHP version does not hide the results for the others. The job needs only `contents: read`.

#### Requirements

- **A test command.** By default this is a `test` script in `composer.json`. Set `test-command` if the repo uses something else.
- **No lock file required.** Without a committed `composer.lock`, every run installs the newest dependencies `composer.json` allows, which is what users of the library get.

#### Setup

1. Copy `examples/php-tests.yml` to `.github/workflows/tests.yml` in the consuming repo.
2. Open a throwaway PR and confirm there is one check per PHP version.

The caller has no path filter, so the checks are safe to require. The check names are built from the **caller's** job key and the job name in this workflow, for example `tests / PHP 8.4`.

### PHP Release

Releases a PHP package that is published on Packagist. The workflow is run by hand from the Actions tab. It checks the version, runs the tests on the exact commit it will release, then creates the tag and the GitHub Release. Packagist picks up the new tag through its webhook, so nothing is pushed to Packagist directly.

#### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `version` | string | (required) | Version to release, such as `0.1.0` or `1.0.0-beta.1`. A leading `v` is accepted. A suffix after a dash makes it a pre-release. |
| `dry-run` | boolean | `false` | Run every check, but do not create the release. |
| `php-version` | string | `8.4` | PHP version used to validate `composer.json`. |
| `php-versions` | string | `["8.1","8.2","8.3","8.4"]` | JSON array of PHP versions the tests run on. Passed to [PHP Tests](#php-tests), so keep it in step with the tests caller. |
| `test-command` | string | `composer test` | Command that runs the tests. Passed to [PHP Tests](#php-tests). |
| `runs-on` | string | `ubuntu-latest` | Runner label for every job. The run steps pin `shell: bash`. |

#### How It Works

The following three jobs run in order:

1. **Check the version.** The run must be on the default branch. The version has its whitespace and leading `v` removed, then must be three numbers with an optional suffix. The tag must not already exist. A stable version lower than the latest stable tag produces a warning only, since that is normal for a backport. The job then verifies that `composer.json` has no `version` key and passes `composer validate --strict`.
2. **Tests.** Calls [PHP Tests](#php-tests) on the same commit.
3. **Create the release.** Skipped on a dry run. Creates the `v<version>` tag at that commit and a GitHub Release with generated notes, marked as a pre-release when the version has a suffix. The release link is written to the job summary.

#### Caller Responsibilities

A reusable workflow cannot define the form shown on the Actions tab, so the caller owns the `workflow_dispatch` trigger and its fields and passes the values in. The following two settings also stay in the caller:

- **`concurrency`.** The caller's group prevents two releases from running at once, and is set to never cancel a release that is already running.
- **`permissions`.** The caller's job must grant `contents: write`. Inside this workflow, only the job that creates the release gets it. The others stay on `contents: read`.

#### Requirements

- **A Packagist package with a working webhook.** Packagist watches the repo for new tags. If a new version does not appear on the package page after a couple of minutes, use the Update button there.
- **No `version` key in `composer.json`.** Packagist takes versions from Git tags, and the check fails the run if it finds one.
- **A test command.** The same requirement as [PHP Tests](#php-tests).

#### Setup

1. Copy `examples/php-release.yml` to `.github/workflows/release.yml` in the consuming repo.
2. Go to **Actions → Release → Run workflow**, enter a version, and select the dry run option. Confirm the checks and tests pass and that no release is created.
3. Run the workflow again without the dry run to make the release.

---

## WordPress Workflows

WordPress packaging has two parts. The [WordPress Packaging Script](#wordpress-packaging-script) builds the zips and runs the same way on a developer machine and in CI. The [WordPress Package](#wordpress-package) workflow calls that script in CI and uploads the result.

### WordPress Packaging Script

The script `scripts/wordpress-package.ps1` packages every WordPress theme and plugin under `src/` into an installable zip. It uses only .NET, and it runs the same on Windows PowerShell 5.1, PowerShell 7 on Windows, and PowerShell 7 on Linux or macOS. Repository owners run it locally to build the same zips that CI produces, and the [WordPress Package](#wordpress-package) workflow calls it.

The script is kept in each consuming repo, so the same file runs locally and in CI. The cost is one copy of the script per repo, and the copies can drift apart. The copy in this repository's `scripts/` folder is the template to start from.

#### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-SourcePath` | string | `src` at the repo root | The directory that contains one folder per package. |
| `-OutputPath` | string | `dist` at the repo root | The directory the zips are written to. It is created if it does not exist. |
| `-Name` | string[] | (all folders) | Package only the named folders. The script fails if a named folder does not exist. |
| `-Suffix` | string | `''` | Text appended to each zip name, such as `pr-12` or a short commit hash. |
| `-Clean` | switch | off | Delete existing zips in the output directory before packaging. |
| `-PassThru` | switch | off | Write one object per zip to the pipeline, in addition to the summary. |

The default paths are resolved relative to the folder that contains the script, so they point at the repo root when the script lives in `scripts/`.

#### Usage

The following commands show the common ways to run the script:

```powershell
# Package everything under src into dist
./scripts/wordpress-package.ps1

# Package only the theme, after clearing old zips from dist
./scripts/wordpress-package.ps1 -Name example-theme -Clean

# Add a pull request label to every zip name
./scripts/wordpress-package.ps1 -Suffix "pr-$env:PR_NUMBER"
```

Run `Get-Help ./scripts/wordpress-package.ps1 -Full` for the complete reference.

#### Package Requirements

The script treats each folder directly under the source directory as one package. A folder qualifies as a package under the following rules:

- **One package per folder.** A theme is a folder with a `style.css` that has a `Theme Name` header. A plugin is a folder with a PHP file at its root that has a `Plugin Name` header. A folder that is neither is skipped with a warning.
- **A `Version` header.** The script reads the version from the header for the zip name. Without one, the zip name has no version and the script warns.
- **A matching `Text Domain` header.** WordPress expects the text domain to match the folder name, so the script warns when the header is present and differs.

#### Output

Each zip is named `<folder>-<version>[-<suffix>].zip`, for example `example-theme-0.1.0-pr-12.zip` when a suffix is given and `example-theme-0.1.0.zip` when it is not.

Inside the zip, everything sits under a single top-level folder named after the source folder, which is what WordPress expects when a zip is uploaded in the admin. Entry names always use forward slashes, so the zips also unpack correctly on Linux hosts. The script does not use `Compress-Archive`, because that command writes backslashes in Windows PowerShell 5.1.

When the script finishes, it prints a table of the packages it wrote. It exits with an error when it finds no package folders or creates no zips, so an empty build fails instead of passing silently.

#### Excluding Files

Files are left out of a package by adding a `.distignore` file to that package's folder. The format follows these rules:

- Each line holds one pattern. Blank lines and lines that start with `#` are ignored.
- Patterns use PowerShell wildcards (`*` and `?`).
- A pattern with no slash matches a file or folder of that name at any depth, for example `node_modules` or `*.map`.
- A pattern that starts with a slash matches from the package root only, for example `/composer.json`.
- A pattern that ends with a slash matches folders only, for example `tests/`.

A small set of files is always left out: operating system and editor files, version control files, `node_modules`, any `.zip` files, and the `.distignore` file itself.

### WordPress Package

Runs the packaging script in CI and uploads every zip it writes as a single artifact. The workflow contains no packaging logic of its own. It calls the [WordPress Packaging Script](#wordpress-packaging-script) and expects to find it at `./scripts/wordpress-package.ps1` in the consuming repo. The `script-path` input points the workflow at a different location. The workflow does not publish or deploy anything. A release or deploy workflow can pick the artifact up later.

#### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `script-path` | string | `./scripts/wordpress-package.ps1` | Path to the packaging script, relative to the repo root. |
| `runs-on` | string | `ubuntu-latest` | Runner label for the job. The script uses only .NET, so `windows-latest` and `macos-latest` also work. The job pins `shell: pwsh` for its run steps, which every GitHub-hosted image ships. |
| `suffix` | string | `''` | Text appended to every zip name. Overrides the automatic pull request label. |
| `artifact-name` | string | `packages` | Name of the uploaded artifact. Artifact names must be unique within a run, so change it if one run calls this workflow more than once. |
| `retention-days` | number | `14` | How long GitHub keeps the artifact. |

#### How It Works

The workflow runs the following steps in order:

1. The workflow checks out the repo.
2. The workflow works out the zip suffix. A pull request run gets `pr-<number>`, any other event gets none, and the `suffix` input overrides both.
3. The workflow runs the script with `-Clean`, which empties `dist/` first so the artifact holds only zips from this run, and with `-Suffix` when a suffix applies. The script exits with an error when it packages nothing, so an empty build fails the job.
4. The workflow writes a table of zip names and sizes to the job summary.
5. The workflow uploads `dist/*.zip` as the artifact, and fails if there is nothing to upload.

The job needs only `contents: read`. The example caller sets that explicitly.

The script must write its zips to `dist/` at the repo root and accept the `-Clean` and `-Suffix` parameters. The template in this repository's `scripts/` folder does both. See [Package Requirements](#package-requirements) for what the script expects of each package folder.

#### The Artifact

GitHub downloads an artifact as a zip, so the package zips arrive inside another zip. Uploading them unwrapped works only for a single file, and the number of packages is not fixed. If the wrapper becomes a problem, the alternative is a matrix with one upload per package.

#### Setup

1. Copy `scripts/wordpress-package.ps1` from this repository to `scripts/wordpress-package.ps1` in the consuming repo, and copy `examples/wordpress-package.yml` to `.github/workflows/`.
2. Check that each package folder under `src/` has the header the script looks for. Run `./scripts/wordpress-package.ps1` locally to see what it picks up.
3. Open a throwaway PR and confirm the `package` check runs, the job summary lists the zips, and the artifact downloads.

The caller has no path filter, so it is safe to make `package` a required status check. As with the other workflows, the required check name is derived from the **caller's** job name.

---

## Repository Hygiene Workflows

### Stale

Marks and closes stale issues and pull requests on a schedule. The caller supplies the schedule, typically a daily cron.

#### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `days-before-issue-stale` | number | `60` | Days of inactivity before an issue is marked stale. |
| `days-before-issue-close` | number | `7` | Days after stale-marking before an issue is closed. |
| `days-before-pr-stale` | number | `30` | Days of inactivity before a PR is marked stale. PRs default to a shorter timeline than issues because inactive PRs are usually abandoned. |
| `days-before-pr-close` | number | `7` | Days after stale-marking before a PR is closed. |
| `exempt-issue-labels` | string | `pinned,security,help wanted,good first issue` | Comma-separated labels that exempt an issue from staling. |
| `exempt-pr-labels` | string | `pinned,security,work in progress` | Comma-separated labels that exempt a PR from staling. |

The stale label applied to flagged items is fixed at `stale` for both issues and PRs, so there is one label to filter on. The stale and close messages are also fixed, to keep the tone consistent across repos.

#### Setup

Copy `examples/stale.yml` to `.github/workflows/` in the consuming repo. The example runs daily at 06:00 UTC and can also be started manually. The schedule has no special meaning, so any hour works. Add a `with:` block only when the defaults do not fit.

---

## License

MIT. See [LICENSE](LICENSE).
