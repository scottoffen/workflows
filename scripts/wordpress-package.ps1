#Requires -Version 5.1

<#
.SYNOPSIS
    Packages every theme and plugin under src into an installable zip.

.DESCRIPTION
    Each folder directly under the source directory is treated as one
    WordPress package. The script detects whether it is a theme (style.css
    with a Theme Name header) or a plugin (a root PHP file with a Plugin Name
    header), reads the version from that header, and writes a zip to the
    output directory named <folder>-<version>.zip.

    Inside the zip, every file is under a single top-level folder named after
    the source folder, and WordPress installs the package into a folder with
    that name when the zip is uploaded in the admin. Entry names always use
    forward slashes, so the zips also unpack correctly on Linux hosts.
    Compress-Archive in Windows PowerShell 5.1 writes backslashes, so the
    script does not use it.

    The script uses .NET, plus Composer for a package that has a
    composer.json, and it runs the same on Windows PowerShell 5.1, PowerShell 7
    on Windows, and PowerShell 7 on Linux or macOS, so a GitHub Actions runner
    can call it directly.

    Before anything is written, the script checks every package folder under
    the source directory, whether or not -Name is given. It fails when no
    package is found, when two folder names differ only by case, and when two
    packages have the same Text Domain. It warns when a package has no
    Version header, or has a Text Domain that differs from its folder name.
    When -Version is given, those two warnings are errors. The script reports
    every problem it finds before it stops.

    When -Version is given, the value of the first Version header in each
    package's style.css or main plugin file is replaced inside the zip. The
    file on disk is not changed, and the zip name uses the given version.

    When a package folder has a composer.json, the script runs composer install
    in that folder before it writes the zip, so the zip includes the vendor
    folder. Composer must be on the PATH. The install uses --no-dev, so the
    zip does not contain development dependencies. The script warns when the
    package has no composer.lock, and it stops with an error when Composer is
    missing or the install fails. A folder that is not a theme or a plugin is
    skipped before any install runs.

    Every .zip file in the output directory is deleted before packaging,
    including when -Name is given.

    Files can be left out of a package by adding a .distignore file to that
    package's folder. See the Notes section.

.PARAMETER SourcePath
    The directory that contains one folder per package. Defaults to src at the
    repository root.

.PARAMETER OutputPath
    The directory the zips are written to. It is created if it does not exist,
    and every .zip file in it is deleted before packaging. Defaults to dist at
    the repository root.

.PARAMETER Name
    Package only the named folders. Every folder under the source directory is
    still validated. The script fails when a named folder does not exist.

.PARAMETER Version
    The version to write into the Version header of every package, as three
    numbers with an optional suffix, such as 1.2.3 or 1.2.3-beta.1. The zip
    names use this version. When omitted, each package keeps the version from
    its own header.

.PARAMETER ValidateOnly
    Runs the checks and stops. It does not run Composer, delete anything from
    the output directory, or write a zip.

.EXAMPLE
    ./scripts/wordpress-package.ps1

    Packages everything under src into dist.

.EXAMPLE
    ./scripts/wordpress-package.ps1 -Name example-theme

    Packages only the theme, after deleting old zips from dist.

.EXAMPLE
    ./scripts/wordpress-package.ps1 -Version 0.2.0

    Packages everything under src with 0.2.0 as the version in every package.

.EXAMPLE
    ./scripts/wordpress-package.ps1 -Version 0.2.0 -ValidateOnly

    Runs the checks for packaging every package as 0.2.0, without writing
    any zips.

.NOTES
    The .distignore format: one pattern per line, blank lines and lines
    starting with # are ignored. Patterns use PowerShell wildcards (* and ?).
      - A pattern with no slash matches a file or folder of that name at any
        depth, for example node_modules or *.map.
      - A pattern that starts with a slash matches from the package root only,
        for example /composer.json.
      - A pattern that ends with a slash matches folders only, for example
        tests/.
    A small set of files is always left out: operating system and editor
    files, version control files, node_modules, and any .zip files.

    composer.json, composer.lock, and the vendor folder are packaged like any
    other file. Add /composer.json and /composer.lock to .distignore to leave
    the two files out.
#>
[CmdletBinding()]
param(
    [string]$SourcePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'src'),
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist'),
    [string[]]$Name,
    [string]$Version,
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Headers are read from, and replaced in, the first 8192 characters of a file.
$HeaderLength = 8192

# Three numbers with an optional suffix, such as 1.2.3 or 1.2.3-beta.1.
$VersionPattern = '^\d+\.\d+\.\d+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$'

# Always left out of every package.
$DefaultExcludes = @(
    '.DS_Store', 'Thumbs.db', 'desktop.ini',
    '.git', '.gitignore', '.gitattributes', '.github',
    '.editorconfig', '.vscode', '.idea', 'node_modules',
    '*.log', '*.zip', '.distignore'
)

function Get-HeaderValue {
    <# Reads a "Label: value" line from the top of a file. Returns $null if absent. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    $head = [System.IO.File]::ReadAllText($Path)
    if ($head.Length -gt $HeaderLength) {
        $head = $head.Substring(0, $HeaderLength)
    }

    $pattern = '(?im)^[ \t/*#@]*' + [regex]::Escape($Label) + ':[ \t]*(.+?)[ \t]*$'
    $match = [regex]::Match($head, $pattern)

    if ($match.Success) {
        return $match.Groups[1].Value.Trim()
    }

    return $null
}

function Set-VersionHeader {
    <# Replaces the value of the first Version line in the text. Returns $null if the start of the text has no Version line. #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Version
    )

    $head = $Text
    if ($head.Length -gt $HeaderLength) {
        $head = $head.Substring(0, $HeaderLength)
    }

    # Group 1 is everything before the value and group 2 is the whitespace
    # after it. The lookahead matches before an optional carriage return, so
    # the replacement leaves Windows line endings unchanged.
    $pattern = '(?im)^([ \t/*#@]*Version:[ \t]*)[^\r\n]*?([ \t]*)(?=\r?$)'
    $match = [regex]::Match($head, $pattern)

    if (-not $match.Success) {
        return $null
    }

    return $Text.Substring(0, $match.Index) +
        $match.Groups[1].Value + $Version + $match.Groups[2].Value +
        $Text.Substring($match.Index + $match.Length)
}

function Get-PackageInfo {
    <# Determines whether a folder is a theme or a plugin, and reads its headers. #>
    param([Parameter(Mandatory)][System.IO.DirectoryInfo]$Directory)

    $styleCss = Join-Path $Directory.FullName 'style.css'
    if ((Test-Path -LiteralPath $styleCss) -and (Get-HeaderValue -Path $styleCss -Label 'Theme Name')) {
        return [pscustomobject]@{
            Type       = 'theme'
            HeaderFile = $styleCss
            Version    = Get-HeaderValue -Path $styleCss -Label 'Version'
            TextDomain = Get-HeaderValue -Path $styleCss -Label 'Text Domain'
        }
    }

    foreach ($phpFile in Get-ChildItem -LiteralPath $Directory.FullName -Filter '*.php' -File) {
        if (Get-HeaderValue -Path $phpFile.FullName -Label 'Plugin Name') {
            return [pscustomobject]@{
                Type       = 'plugin'
                HeaderFile = $phpFile.FullName
                Version    = Get-HeaderValue -Path $phpFile.FullName -Label 'Version'
                TextDomain = Get-HeaderValue -Path $phpFile.FullName -Label 'Text Domain'
            }
        }
    }

    return $null
}

function Test-PackageSet {
    <# Checks all packages together. Writes warnings, and throws one error that lists every problem. #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Package,
        [string]$Version
    )

    $problems = New-Object System.Collections.Generic.List[string]

    if ($Package.Count -eq 0) {
        $problems.Add('No theme or plugin folders were found.')
    }

    $sameFolder = @($Package | Group-Object -Property { $_.Directory.Name.ToLowerInvariant() } | Where-Object { $_.Count -gt 1 })
    foreach ($group in $sameFolder) {
        $names = ($group.Group | ForEach-Object { $_.Directory.Name }) -join ', '
        $problems.Add("These folders have the same name when case is ignored: $names.")
    }

    $sameDomain = @($Package | Where-Object { $_.Info.TextDomain } |
        Group-Object -Property { $_.Info.TextDomain.ToLowerInvariant() } |
        Where-Object { $_.Count -gt 1 })
    foreach ($group in $sameDomain) {
        $names = ($group.Group | ForEach-Object { $_.Directory.Name }) -join ', '
        $problems.Add("These packages have the same Text Domain '$($group.Name)': $names.")
    }

    foreach ($item in $Package) {
        $folder = $item.Directory.Name

        if ($item.Info.TextDomain -and $item.Info.TextDomain -ne $folder) {
            $message = "'$folder' has Text Domain '$($item.Info.TextDomain)'. The Text Domain must match the folder name."
            if ($Version) {
                $problems.Add($message)
            }
            else {
                Write-Warning $message
            }
        }

        if (-not $item.Info.Version) {
            if ($Version) {
                $problems.Add("'$folder' has no Version header, so there is no version to replace.")
            }
            else {
                Write-Warning "'$folder' has no Version header, so the zip name will not include a version."
            }
        }
    }

    if ($problems.Count -gt 0) {
        throw ("The packages did not pass validation:`n  - " + ($problems -join "`n  - "))
    }
}

function Install-ComposerDependency {
    <# Runs composer install in a package folder that has a composer.json. #>
    param([Parameter(Mandatory)][System.IO.DirectoryInfo]$Directory)

    if (-not (Get-Command composer -ErrorAction SilentlyContinue)) {
        throw "'$($Directory.Name)' has a composer.json, but composer was not found on the PATH. Install Composer from https://getcomposer.org and run the script again."
    }

    if (-not (Test-Path -LiteralPath (Join-Path $Directory.FullName 'composer.lock'))) {
        Write-Warning "'$($Directory.Name)' has no composer.lock, so composer will resolve the newest versions that composer.json allows. Commit a composer.lock to make the build repeatable."
    }

    Write-Host "Running composer install in '$($Directory.Name)'"

    # Out-Host writes composer's output straight to the console, so it does
    # not become part of the script's output.
    $workingDirectory = $Directory.FullName
    & composer install "--working-dir=$workingDirectory" --no-dev --no-interaction --no-progress --prefer-dist --optimize-autoloader | Out-Host

    if ($LASTEXITCODE -ne 0) {
        throw "composer install failed in '$($Directory.Name)' with exit code $LASTEXITCODE."
    }
}

function Read-IgnorePattern {
    <# Reads the .distignore file for a package, if it has one. #>
    param([Parameter(Mandatory)][string]$PackageRoot)

    $file = Join-Path $PackageRoot '.distignore'
    if (-not (Test-Path -LiteralPath $file)) {
        return @()
    }

    return @(
        Get-Content -LiteralPath $file |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') }
    )
}

function Test-IsExcluded {
    <# Returns whether a path, relative to the package root, is left out. #>
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][bool]$IsDirectory,
        [string[]]$Pattern
    )

    $segments = $RelativePath.Split('/')

    foreach ($entry in $Pattern) {
        $text = $entry
        $directoryOnly = $text.EndsWith('/')
        if ($directoryOnly) {
            $text = $text.TrimEnd('/')
        }

        if ($directoryOnly -and -not $IsDirectory) {
            # A folder pattern also excludes every file inside that folder.
            $parents = $segments[0..($segments.Count - 2)]
            if ($text.StartsWith('/')) {
                if ($parents.Count -gt 0 -and $parents[0] -like $text.TrimStart('/')) { return $true }
            }
            elseif ($parents | Where-Object { $_ -like $text }) {
                return $true
            }
            continue
        }

        if ($text.StartsWith('/')) {
            if ($RelativePath -like $text.TrimStart('/')) { return $true }
        }
        elseif ($text.Contains('/')) {
            if ($RelativePath -like $text) { return $true }
        }
        elseif ($segments | Where-Object { $_ -like $text }) {
            return $true
        }
    }

    return $false
}

function Get-PackageFile {
    <# Returns the files in a package folder that are not excluded. #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$Pattern
    )

    $rootLength = $Root.TrimEnd('\', '/').Length + 1
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Root)
    $found = New-Object System.Collections.Generic.List[object]

    while ($stack.Count -gt 0) {
        $current = $stack.Pop()

        foreach ($item in Get-ChildItem -LiteralPath $current -Force) {
            $relative = $item.FullName.Substring($rootLength).Replace('\', '/')

            if (Test-IsExcluded -RelativePath $relative -IsDirectory $item.PSIsContainer -Pattern $Pattern) {
                continue
            }

            if ($item.PSIsContainer) {
                $stack.Push($item.FullName)
            }
            else {
                $found.Add([pscustomobject]@{ FullName = $item.FullName; Relative = $relative })
            }
        }
    }

    return $found | Sort-Object -Property Relative
}

function New-PackageZip {
    <# Writes the zip, with every entry under a single top-level folder. When Version is given, the entry for VersionFile has its Version header replaced. #>
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][object[]]$File,
        [string]$VersionFile,
        [string]$Version
    )

    if (Test-Path -LiteralPath $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force
    }

    # Latin-1 maps every byte to one character, so the header file is written
    # back byte for byte except for the version.
    $latin1 = [System.Text.Encoding]::GetEncoding('iso-8859-1')
    $replaced = $false

    $stream = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::Create)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($entry in $File) {
                $entryName = "$Slug/$($entry.Relative)"

                if ($Version -and $entry.FullName -eq $VersionFile) {
                    $text = $latin1.GetString([System.IO.File]::ReadAllBytes($entry.FullName))
                    $changed = Set-VersionHeader -Text $text -Version $Version
                    if ($null -eq $changed) {
                        throw "'$Slug' has no Version header in the first $HeaderLength characters of '$($entry.Relative)'."
                    }

                    $bytes = $latin1.GetBytes($changed)
                    $zipEntry = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
                    $zipEntry.LastWriteTime = [DateTimeOffset]([System.IO.File]::GetLastWriteTime($entry.FullName))

                    $entryStream = $zipEntry.Open()
                    try {
                        $entryStream.Write($bytes, 0, $bytes.Length)
                    }
                    finally {
                        $entryStream.Dispose()
                    }

                    $replaced = $true
                    continue
                }

                $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $archive, $entry.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal)
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }

    if ($Version -and -not $replaced) {
        throw "The file with the Version header for '$Slug' is left out of the zip by the ignore patterns, so there is no version to replace."
    }
}

# ---- main ----

$SourcePath = (Resolve-Path -LiteralPath $SourcePath).Path

if ($Version -and $Version -notmatch $VersionPattern) {
    throw "The version '$Version' is not three numbers with an optional suffix, such as 1.2.3 or 1.2.3-beta.1."
}

$directories = @(Get-ChildItem -LiteralPath $SourcePath -Directory | Sort-Object -Property Name)

if ($Name) {
    $missing = $Name | Where-Object { $directories.Name -notcontains $_ }
    if ($missing) {
        throw "No folder named '$($missing -join "', '")' exists under $SourcePath."
    }
}

$packages = New-Object System.Collections.Generic.List[object]

foreach ($directory in $directories) {
    $info = Get-PackageInfo -Directory $directory

    if ($null -eq $info) {
        if (-not $Name -or $Name -contains $directory.Name) {
            Write-Warning "Skipping '$($directory.Name)': it is not a theme (style.css with Theme Name) or a plugin (a root PHP file with Plugin Name)."
        }
        continue
    }

    $packages.Add([pscustomobject]@{ Directory = $directory; Info = $info })
}

Test-PackageSet -Package $packages.ToArray() -Version $Version

if ($ValidateOnly) {
    Write-Host "Validated $($packages.Count) package(s) under $SourcePath"
    return
}

$selected = @($packages | Where-Object { -not $Name -or $Name -contains $_.Directory.Name })

if ($selected.Count -eq 0) {
    throw "None of the named folders is a theme or a plugin."
}

$null = New-Item -ItemType Directory -Path $OutputPath -Force
$OutputPath = (Resolve-Path -LiteralPath $OutputPath).Path

Get-ChildItem -LiteralPath $OutputPath -Filter '*.zip' -File | Remove-Item -Force

$results = New-Object System.Collections.Generic.List[object]

foreach ($item in $selected) {
    $directory = $item.Directory
    $info = $item.Info

    $packageVersion = $info.Version
    if ($Version) {
        $packageVersion = $Version
    }

    $zipName = $directory.Name
    if ($packageVersion) { $zipName += "-$packageVersion" }
    $zipPath = Join-Path $OutputPath "$zipName.zip"

    if (Test-Path -LiteralPath (Join-Path $directory.FullName 'composer.json')) {
        Install-ComposerDependency -Directory $directory
    }

    $patterns = @($DefaultExcludes) + @(Read-IgnorePattern -PackageRoot $directory.FullName)
    $files = @(Get-PackageFile -Root $directory.FullName -Pattern $patterns)

    if ($files.Count -eq 0) {
        Write-Warning "Skipping '$($directory.Name)': no files to package."
        continue
    }

    New-PackageZip -ZipPath $zipPath -Slug $directory.Name -File $files -VersionFile $info.HeaderFile -Version $Version

    $results.Add([pscustomobject]@{
        Package = $directory.Name
        Type    = $info.Type
        Version = $packageVersion
        Files   = $files.Count
        SizeKB  = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1KB, 1)
    })
}

if ($results.Count -eq 0) {
    throw 'No packages were created.'
}

Write-Host ''
Write-Host "Packaged $($results.Count) item(s) into $OutputPath"
($results | Format-Table -Property Package, Type, Version, Files, SizeKB -AutoSize | Out-String -Width 200).TrimEnd() | Write-Host
