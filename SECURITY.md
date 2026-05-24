# Security Policy

## Reporting a vulnerability

Please report security issues using GitHub's private vulnerability
reporting feature: navigate to the Security tab of this repository
and click "Report a vulnerability."

This is preferred over public issues, email, or social media because
it creates a private channel where a fix can be coordinated before
disclosure.

## Scope

These workflows are infrastructure for building and publishing .NET
packages. Plausible vulnerability classes include:

- Command injection through caller-supplied inputs.
- Secret exfiltration through workflow output, logs, or artifact
  contents.
- Path traversal in inputs that influence filesystem operations.

Issues in upstream actions (`actions/checkout`, `actions/setup-dotnet`,
etc.) should be reported to those projects directly.

## Response time

Best effort. As a solo-maintained open-source project, response time
depends on availability. Expect acknowledgment within a week and a
fix prioritized based on severity.

## Supported versions

Only the current `v0` (latest) and the current major (`v1`, `v2`, etc.)
moving tags are supported. Older majors are frozen and will not receive
fixes; consumers pinned to them should upgrade.