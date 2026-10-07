# Publishing to Packagist

[Packagist](https://packagist.org) is the default Composer package repository. A PHP package must be registered there before `composer require` can find it. The [PHP Release](README.md#php-release) workflow creates a git tag and a GitHub Release. Packagist then publishes the new version from that tag, so nothing is pushed to Packagist directly.

This document covers the one-time setup for a new package, how to confirm that a release arrived, and what to do when it does not.

> [!IMPORTANT]
> The GitHub repository must be public. Packagist.org only lists public packages, and the submission step requires a public repository URL. A private repository cannot be registered there. Private Packagist is the separate paid service for private code, and it is not covered here.

## Contents

- [Requirements](#requirements)
- [Setting Up Packagist](#setting-up-packagist)
  - [Create the Account](#create-the-account)
  - [Choose the Package Name](#choose-the-package-name)
  - [Submit the Package](#submit-the-package)
  - [Confirm Auto-Updates](#confirm-auto-updates)
  - [Manual Webhook](#manual-webhook)
- [After a Release](#after-a-release)
- [Troubleshooting](#troubleshooting)

---

## Requirements

A package needs the following before it can be submitted:

- **A public repository.** See the note above. If the repository is currently private, change it in the repo under **Settings → General → Danger Zone → Change repository visibility**.
- **A Packagist account.** The next section describes how to create one.
- **A `composer.json` file at the repository root.** The file must have a `name` in the form `vendor/package`. It must not have a `version` key, because Packagist takes versions from git tags, and the [PHP Release](README.md#php-release) workflow fails when it finds one.

Run `composer validate --strict` before submitting. The release workflow runs the same check.

---

## Setting Up Packagist

### Create the Account

Log in with GitHub, which lets Packagist configure the update webhook for every repository automatically. The steps are as follows:

1. Go to [packagist.org](https://packagist.org) and select **Log in**, then **Use GitHub**.
2. Grant the permissions that GitHub requests.
3. If the repository belongs to a GitHub organization instead of a personal account, make sure the [Packagist application](https://github.com/settings/connections/applications/a059f127e1c09c04aa5a) has access to that organization.

An existing Packagist account that was created with an email address can be connected to GitHub from the profile page. If you are already logged in when you connect it, log out first and then log in through GitHub again, so that Packagist is granted the required permissions.

### Choose the Package Name

The package name is the `name` value in `composer.json`, and it has two parts joined by a slash, such as `vendor/package`. Choose it carefully, because it cannot be changed after the package is submitted.

- The name must be unique on Packagist.
- The vendor name is protected once a package has been published under it. Only maintainers of an existing package in that vendor can publish more packages under it.
- Names can contain lowercase letters, numbers, and the characters `.`, `-`, and `_`. Each part must start with a letter or a number.

### Submit the Package

Submit the package with the following steps:

1. Confirm that the repository is public and that `composer.json` is committed to the default branch.
2. Go to [packagist.org/packages/submit](https://packagist.org/packages/submit).
3. Enter the repository URL, such as `https://github.com/<owner>/<repo>`, and follow the prompts to submit it.
4. Open the new package page and confirm that it shows the package name and description.

A new package is crawled immediately after submission when JavaScript is enabled in the browser. Branches appear as development versions. Release versions appear once the repository has tags, so a package that has never been released shows no release versions yet.

### Confirm Auto-Updates

When the account was created through GitHub, Packagist sets up the webhook on its own. Confirm that it worked with the following steps:

1. Open the package page. It should state that the package is auto-updated.
2. Open your [profile](https://packagist.org/profile/) and check the package list. A package that is not synced automatically shows a warning.

If a package shows the warning, try the following in order:

1. Check that the Packagist application has access to the GitHub account or organization that owns the repository.
2. Go to [packagist.org/trigger-github-sync](https://packagist.org/trigger-github-sync/) to make Packagist try to set up the hooks on the account again.
3. If the warning remains, set up the [manual webhook](#manual-webhook).

Archived repositories cannot be set up, because GitHub treats them as read-only.

### Manual Webhook

Use a manual webhook when you do not want to log in through GitHub or give Packagist permission to configure webhooks. The webhook is configured in the repo with the following steps:

1. Go to **Settings → Webhooks** and select **Add webhook**.
2. Set **Payload URL** to `https://packagist.org/api/github?username=<packagist-username>`.
3. Set **Content type** to `application/json`.
4. Set **Secret** to the API token shown on your [Packagist profile](https://packagist.org/profile/).
5. Under events, choose only the `push` event, and then save the webhook.

---

## After a Release

The PHP Release workflow creates the tag and the GitHub Release. Packagist is notified by the webhook and then publishes the version. Confirm the release with the following steps:

1. Wait for the PHP Release workflow to finish.
2. Open the package page on Packagist. The new version should appear within a minute or two.

The Packagist search index is rebuilt every five minutes, so a new version can show up on the package page before it shows up in search results.

If the version does not appear, log in as a maintainer, open the package page, and select **Update**. This makes Packagist crawl the repository again immediately.

> [!NOTE]
> An update can also be triggered from the command line. The API token is on the Packagist profile page.
>
> ```bash
> curl -XPOST -H 'content-type:application/json' \
>   'https://packagist.org/api/update-package?username=<packagist-username>&apiToken=<api-token>' \
>   -d '{"repository":{"url":"https://packagist.org/packages/<vendor>/<package>"}}'
> ```

---

## Troubleshooting

- **The package cannot be submitted.** The repository is probably private. Make it public, and then submit it again.
- **A new version does not appear.** The webhook may have failed or been delayed. Select **Update** on the package page. When a webhook is active, Packagist also crawls the package at least once a month in case a crawl failed, and a package without a webhook is crawled only once a week.
- **The package page says it is not auto-updated.** The webhook is missing. Follow the steps under [Confirm Auto-Updates](#confirm-auto-updates), or set up the [manual webhook](#manual-webhook).
- **A tag does not produce a version.** Tag names must look like `1.2.3` or `v1.2.3`, with an optional suffix such as `-RC1`, `-beta.1`, or `-alpha`. The PHP Release workflow creates tags in the `v<version>` form, so tags made by hand are the usual cause.
- **The release workflow fails the version check.** The `composer.json` file has a `version` key. Remove it, because Packagist takes versions from git tags.
