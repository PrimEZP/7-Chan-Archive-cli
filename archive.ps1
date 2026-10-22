param(
    [Parameter(Position=0)]
    [string]$Url,
    [ValidateRange(1,16)]
    [int]$Concurrency = 4,
    [ValidateRange(0,10000)]
    [int]$DelayMs = 0
)

if (-not $Url) {
    Write-Host "`n  7chan Thread Archiver" -ForegroundColor Cyan
    Write-Host "  Paste a 7chan thread URL and press Enter.`n"
    $Url = Read-Host "URL"
    if (-not $Url) {
        Write-Host "No URL provided. Exiting."
        exit 0
    }
}

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\utils.ps1"

if (-not (Get-CurlPath)) {
    Write-Host "ERROR: curl was not found. It ships with Windows 10 (1803) and later; on older systems install it from https://curl.se/windows/" -ForegroundColor Red
    exit 1
}

# --- Parse URL ---
if ($Url -match $ThreadUrlPattern) {
    $board = $Matches[1]
    $threadId = $Matches[2]
} else {
    Write-Host "ERROR: Invalid 7chan thread URL." -ForegroundColor Red
    Write-Host "Expected format: https://7chan.org/{board}/res/{id}.html"
    exit 1
}

# --- Create folder structure ---
$archiveRoot = Join-Path $PSScriptRoot "archives"
$existingDir = Get-ExistingArchiveDir -archiveRoot $archiveRoot -board $board -threadId $threadId
$threadDir = $null
$isUpdate = $false

if ($existingDir) {
    $threadDir = $existingDir
    Write-Host "Thread already archived at: $threadDir" -ForegroundColor Yellow
    $reply = Read-Host "Update with new posts? (Y/n)"
    if ($reply -match '^(n|no)$') {
        Write-Host "Aborted."
        exit 0
    }
    $isUpdate = $true
}

# --- Load existing posts for efficient updating ---
$existingPostIds = @{}
$savedThread = $null
if ($isUpdate -and $threadDir) {
    $savedJsonPath = Join-Path $threadDir "thread.json"
    if (Test-Path $savedJsonPath) {
        try {
            $savedThread = (Get-Content $savedJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json)
            foreach ($p in $savedThread.posts) {
                $existingPostIds[[string]$p.no] = $true
            }
            Write-Host "  Loaded $($existingPostIds.Count) existing posts from cache" -ForegroundColor DarkGray
        } catch {
            Write-Host "  Could not read cached thread.json, will re-download all" -ForegroundColor Yellow
        }
    }
}

# --- Fetch and parse the thread page ---
Write-Host "Fetching thread /$board/$threadId ..." -ForegroundColor Cyan
$page = Get-7chanThreadPage $board $threadId

if (-not $page.Success) {
    if ($page.Is404) {
        Write-Host "ERROR: Thread not found (404). It may have been deleted or pruned." -ForegroundColor Red
        if ($isUpdate) { Write-Host "  Your existing archive was left untouched." -ForegroundColor DarkGray }
    } else {
        Write-Host "ERROR: Failed to fetch thread after 3 attempts. It may not exist, has been deleted, or network is down." -ForegroundColor Red
    }
    exit 1
}

try {
    $thread = ConvertFrom-7chanThread $page.Html $board $threadId
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$posts = @($thread.posts)
$op = $posts[0]
$newPostCount = @($posts | Where-Object { -not $existingPostIds.ContainsKey([string]$_.no) }).Count
$goneCount = 0
if ($savedThread) {
    $freshNos = @{}
    foreach ($p in $posts) { $freshNos[[string]$p.no] = $true }
    $goneCount = @($savedThread.posts | Where-Object { -not $freshNos.ContainsKey([string]$_.no) }).Count
}

# --- Determine folder name if new archive ---
if (-not $isUpdate) {
    $slug = Get-SanitizedSlug $op.sub
    if (-not $slug -and $op.com) {
        $slug = Get-SanitizedSlug $op.com
    }
    $folderName = if ($slug) { "${board}_${threadId}_${slug}" } else { "${board}_${threadId}" }
    $threadDir = Join-Path $archiveRoot $folderName
}

$imgDir = Join-Path $threadDir "images"
New-Item -ItemType Directory -Path $imgDir -Force | Out-Null

Write-Host "Found $($posts.Count) posts" -ForegroundColor Cyan

if ($isUpdate) {
    Write-Host "  $newPostCount new post(s) found" -ForegroundColor Cyan
    if ($goneCount -gt 0) {
        Write-Host "  $goneCount post(s) deleted from 7chan since last update (removed from archive)" -ForegroundColor Yellow
    }
    # The archive mirrors 7chan: drop saved copies of files that moderators have since removed
    $removedFiles = Remove-DeletedFiles $savedThread $thread $imgDir
    if ($removedFiles -gt 0) {
        Write-Host "  Deleted $removedFiles saved file(s) that were removed from 7chan" -ForegroundColor Yellow
    }
}

# --- Download images ---
$tasks = @(Get-DownloadTasks $thread $imgDir)
$pending = @($tasks | Where-Object { -not (Test-Path -LiteralPath $_.Dest) })
$skipped = $tasks.Count - $pending.Count
$failedImages = @()

if ($skipped -gt 0) {
    Write-Host "  Skipping $skipped already-downloaded files" -ForegroundColor DarkGray
}

if ($pending.Count -gt 0) {
    $delayMsg = if ($DelayMs -gt 0) { ", ${DelayMs}ms delay" } else { "" }
    Write-Host "  Downloading $($pending.Count) files ($Concurrency concurrent$delayMsg) ..." -ForegroundColor Cyan
    $failedImages = @(Invoke-ParallelDownloads $pending $Concurrency $DelayMs "  ")
}

$imageCount = @($tasks | Where-Object { $_.Type -eq "image" -and (Test-Path -LiteralPath $_.Dest) }).Count

Write-Host "`nDownloaded $imageCount images ($($failedImages.Count) failed)" -ForegroundColor Cyan

# --- Save parsed thread for future updates (BOM-less UTF-8) ---
$jsonPath = Join-Path $threadDir "thread.json"
[System.IO.File]::WriteAllText($jsonPath, (ConvertTo-ThreadJson $thread))

# --- Generate HTML by delegating to update-html.ps1 ---
Write-Host "Generating HTML ..." -ForegroundColor Cyan
try {
    $archiveName = Split-Path $threadDir -Leaf
    & "$PSScriptRoot\update-html.ps1" -ArchiveName $archiveName
} catch {
    Write-Host "ERROR: Failed to generate HTML: $($_.Exception.Message)" -ForegroundColor Red
}

# --- Summary ---
Write-Host "`n========================================" -ForegroundColor Green
if ($isUpdate) {
    Write-Host " Update complete! ($newPostCount new posts)" -ForegroundColor Green
} else {
    Write-Host " Archive complete!" -ForegroundColor Green
}
Write-Host "========================================" -ForegroundColor Green
Write-Host " Location: $threadDir" -ForegroundColor White
Write-Host " HTML:     thread.html" -ForegroundColor White
Write-Host " Images:   $(@($tasks | Where-Object { $_.Type -eq 'image' }).Count) total files in images/" -ForegroundColor White

if ($failedImages.Count -gt 0) {
    Write-Host "`n Failed downloads:" -ForegroundColor Yellow
    foreach ($f in $failedImages) {
        Write-Host "   - $f" -ForegroundColor Yellow
    }
}

Write-Host "`nOpen thread.html in your browser to view the archive." -ForegroundColor Cyan
