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

    Inside the zip, every file sits under a single top-level folder named
    after the source folder, which is what WordPress expects when a zip is
    uploaded in the admin. Entry names always use forward slashes, so the
    zips also unpack correctly on Linux hosts. (Compress-Archive in Windows
    PowerShell 5.1 writes backslashes, which is why it is not used here.)

    The script uses only .NET and runs the same on Windows PowerShell 5.1,
    PowerShell 7 on Windows, and PowerShell 7 on Linux or macOS, so a GitHub
    Actions runner can call it directly.

    Files can be left out of a package by adding a .distignore file to that
    package's folder. See the Notes section.

.PARAMETER SourcePath
    The directory that contains one folder per package. Defaults to src at the
    repository root.

.PARAMETER OutputPath
    The directory the zips are written to. Defaults to dist at the repository
    root. It is created if it does not exist.

.PARAMETER Name
    Package only the named folders. When omitted, every folder is packaged.

.PARAMETER Suffix
    Text appended to each zip name, such as pr-12 or a short commit hash. For
    example, greenthumb-theme-0.1.0-pr-12.zip.

.PARAMETER Clean
    Deletes existing zips in the output directory before packaging.

.PARAMETER PassThru
    Writes one object per zip to the pipeline in addition to the summary.

.EXAMPLE
    ./scripts/wordpress-package.ps1

    Packages everything under src into dist.

.EXAMPLE
    ./scripts/wordpress-package.ps1 -Name greenthumb-theme -Clean

    Packages only the theme, after clearing old zips from dist.

.EXAMPLE
    ./scripts/wordpress-package.ps1 -Suffix "pr-$env:PR_NUMBER"

    Adds a pull request label to every zip name.

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
#>
[CmdletBinding()]
param(
    [string]$SourcePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'src'),
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist'),
    [string[]]$Name,
    [string]$Suffix,
    [switch]$Clean,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

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
    if ($head.Length -gt 8192) {
        $head = $head.Substring(0, 8192)
    }

    $pattern = '(?im)^[ \t/*#@]*' + [regex]::Escape($Label) + ':[ \t]*(.+?)[ \t]*$'
    $match = [regex]::Match($head, $pattern)

    if ($match.Success) {
        return $match.Groups[1].Value.Trim()
    }

    return $null
}

function Get-PackageInfo {
    <# Works out whether a folder is a theme or a plugin and reads its headers. #>
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
    <# Decides whether a path, relative to the package root, is left out. #>
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
            # A folder pattern also excludes everything inside that folder.
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
    <# Walks a package folder and returns the files that belong in the zip. #>
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
    <# Writes the zip, with every entry under a single top-level folder. #>
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][object[]]$File
    )

    if (Test-Path -LiteralPath $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force
    }

    $stream = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::Create)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($entry in $File) {
                $entryName = "$Slug/$($entry.Relative)"
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
}

# ---- main ----

$SourcePath = (Resolve-Path -LiteralPath $SourcePath).Path
$null = New-Item -ItemType Directory -Path $OutputPath -Force
$OutputPath = (Resolve-Path -LiteralPath $OutputPath).Path

if ($Clean) {
    Get-ChildItem -LiteralPath $OutputPath -Filter '*.zip' -File | Remove-Item -Force
}

$directories = @(Get-ChildItem -LiteralPath $SourcePath -Directory | Sort-Object -Property Name)

if ($Name) {
    $missing = $Name | Where-Object { $directories.Name -notcontains $_ }
    if ($missing) {
        throw "No folder named '$($missing -join "', '")' exists under $SourcePath."
    }
    $directories = @($directories | Where-Object { $Name -contains $_.Name })
}

if ($directories.Count -eq 0) {
    throw "No package folders found under $SourcePath."
}

$results = New-Object System.Collections.Generic.List[object]

foreach ($directory in $directories) {
    $info = Get-PackageInfo -Directory $directory

    if ($null -eq $info) {
        Write-Warning "Skipping '$($directory.Name)': it is not a theme (style.css with Theme Name) or a plugin (a root PHP file with Plugin Name)."
        continue
    }

    if ($info.TextDomain -and $info.TextDomain -ne $directory.Name) {
        Write-Warning "'$($directory.Name)' has Text Domain '$($info.TextDomain)'. WordPress expects the text domain to match the folder name."
    }

    $version = $info.Version
    if (-not $version) {
        Write-Warning "'$($directory.Name)' has no Version header, so the zip name will not include a version."
    }

    $zipName = $directory.Name
    if ($version) { $zipName += "-$version" }
    if ($Suffix) { $zipName += "-$Suffix" }
    $zipPath = Join-Path $OutputPath "$zipName.zip"

    $patterns = @($DefaultExcludes) + @(Read-IgnorePattern -PackageRoot $directory.FullName)
    $files = @(Get-PackageFile -Root $directory.FullName -Pattern $patterns)

    if ($files.Count -eq 0) {
        Write-Warning "Skipping '$($directory.Name)': no files to package."
        continue
    }

    New-PackageZip -ZipPath $zipPath -Slug $directory.Name -File $files

    $results.Add([pscustomobject]@{
        Package = $directory.Name
        Type    = $info.Type
        Version = $version
        Files   = $files.Count
        SizeKB  = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1KB, 1)
        Path    = $zipPath
    })
}

if ($results.Count -eq 0) {
    throw 'No packages were created.'
}

Write-Host ''
Write-Host "Packaged $($results.Count) item(s) into $OutputPath"
($results | Format-Table -Property Package, Type, Version, Files, SizeKB -AutoSize | Out-String -Width 200).TrimEnd() | Write-Host

if ($PassThru) {
    $results
}