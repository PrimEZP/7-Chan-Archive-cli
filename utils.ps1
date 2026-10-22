# 7chan Thread Archiver Utility Functions

$SiteRoot = "https://7chan.org"
$UserAgent = "7chan-archiver/1.0"

# Matches https://7chan.org/{board}/res/{id}.html, plus www., the +50 / -100 "last posts" pages, and #anchors
$ThreadUrlPattern = '(?:www\.)?7chan\.org/([a-z0-9]+)/res/(\d+)(?:[+-]\d+)?(?:\.html)?'

# Escape HTML entities
function Escape-Html($text) {
    if (-not $text) { return "" }
    return ([string]$text).Replace("&","&amp;").Replace("<","&lt;").Replace(">","&gt;").Replace('"',"&quot;").Replace("'","&#39;")
}

# Strip tags, decode entities and collapse whitespace
function ConvertFrom-HtmlText($html) {
    if (-not $html) { return "" }
    $text = $html -replace '<[^>]+>', ' '
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    return ($text -replace '\s+', ' ').Trim()
}

# Turn a relative or protocol-relative 7chan link into an absolute https URL
function Resolve-7chanUrl($url) {
    if (-not $url) { return $null }
    $url = [System.Net.WebUtility]::HtmlDecode($url)
    if ($url -match '^https?://') { return $url }
    if ($url.StartsWith('//')) { return "https:$url" }
    if ($url.StartsWith('/')) { return "$SiteRoot$url" }
    return "$SiteRoot/$url"
}

# Cloudflare in front of 7chan rejects the .NET HTTP stack (Invoke-WebRequest / HttpClient) with 403,
# so every request goes through curl, which ships with Windows 10+ and macOS/Linux
function Get-CurlPath {
    $cmd = Get-Command curl.exe, curl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-CurlErrorText($exitCode, $httpCode) {
    switch ($exitCode) {
        6  { return "Could not resolve host" }
        7  { return "Failed to connect" }
        22 { return "HTTP $httpCode" }
        28 { return "Timed out" }
        35 { return "TLS handshake failed" }
        52 { return "Empty reply from server" }
        56 { return "Connection reset" }
        default { return "curl exit code $exitCode" }
    }
}

# GET a page. Returns @{ StatusCode; Content; Error }
function Invoke-7chanRequest($Url, $TimeoutSec = 30) {
    $curl = Get-CurlPath
    if (-not $curl) {
        return @{ StatusCode = 0; Content = $null; Error = "curl not found" }
    }
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        # -s without -S keeps curl off stderr, which Windows PowerShell turns into terminating errors
        $httpCode = & $curl -s -L --compressed -A $UserAgent --connect-timeout 15 --max-time $TimeoutSec -o $tmp -w "%{http_code}" $Url
        $exitCode = $LASTEXITCODE
        $status = 0
        [void][int]::TryParse(($httpCode | Out-String).Trim(), [ref]$status)
        if ($exitCode -ne 0) {
            return @{ StatusCode = $status; Content = $null; Error = (Get-CurlErrorText $exitCode $status) }
        }
        $content = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8)
        $err = if ($status -ge 400) { "HTTP $status" } else { $null }
        return @{ StatusCode = $status; Content = $content; Error = $err }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# Fetch a thread page with retries. Returns @{ Success; Is404; Html }
function Get-7chanThreadPage($board, $threadId, $Indent = "  ") {
    $url = "$SiteRoot/$board/res/$threadId.html"
    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $res = Invoke-7chanRequest $url
        if ($res.StatusCode -eq 404) {
            return @{ Success = $false; Is404 = $true; Html = $null }
        }
        if ($res.StatusCode -eq 200 -and $res.Content) {
            return @{ Success = $true; Is404 = $false; Html = $res.Content }
        }

        $msg = if ($res.Error) { $res.Error } else { "HTTP $($res.StatusCode)" }
        if ($res.StatusCode -eq 403) { $msg += " (blocked by Cloudflare)" }
        Write-Host "${Indent}Attempt $attempt failed: $msg" -ForegroundColor Yellow
        if ($attempt -lt $maxAttempts) {
            $sleepSec = $attempt * 2
            Write-Host "${Indent}Retrying in $sleepSec seconds..." -ForegroundColor DarkGray
            Start-Sleep -Seconds $sleepSec
        }
    }
    return @{ Success = $false; Is404 = $false; Html = $null }
}

# Parse "(66.03KB, 1200x1327, original name.png)" - dimensions are absent for non-image files
function Get-FileDetails($text) {
    $details = @{ Size = ""; W = 0; H = 0; OrigName = "" }
    if ($text -match '\(\s*([\d.]+\s*[KMG]?B)\s*,?(.*)\)') {
        $details.Size = $Matches[1] -replace '\s', ''
        $rest = $Matches[2].Trim()
        if ($rest -match '^(\d+)x(\d+)\s*,?\s*(.*)$') {
            $details.W = [int]$Matches[1]
            $details.H = [int]$Matches[2]
            $rest = $Matches[3]
        }
        $details.OrigName = $rest.Trim()
    }
    return $details
}

# Local file name for a 7chan URL. Non-image uploads keep their original names, which can hold spaces or
# characters Windows rejects
function Get-LocalFileName($url) {
    if (-not $url) { return "" }
    $name = [uri]::UnescapeDataString([System.IO.Path]::GetFileName(([uri]$url).AbsolutePath))
    # Use Windows' rules on every OS so an archive stays valid when copied between systems
    $name = $name -replace '[<>:"/\\|?*\x00-\x1F]', '_'
    if ($name -eq "." -or $name -eq "..") { return "" }
    return $name
}

function New-FileEntry($src, $thumbSrc, $idAttr, $downloadName, $detailsText, $deleted) {
    $url = Resolve-7chanUrl $src
    $thumbUrl = Resolve-7chanUrl $thumbSrc
    $details = Get-FileDetails $detailsText
    $w = $details.W
    $h = $details.H
    # expandimg_{post}[-{n}]_{w}_{h}_{thumbW}_{thumbH}
    if ($idAttr -match '_(\d+)_(\d+)_\d+_\d+$') {
        $w = [int]$Matches[1]
        $h = [int]$Matches[2]
    }
    $orig = if ($downloadName) { [System.Net.WebUtility]::HtmlDecode($downloadName) } else { $details.OrigName }
    $file = Get-LocalFileName $url
    if ($file -match '^removed\.') { $deleted = $true }

    return [pscustomobject]@{
        file     = $file
        url      = $url
        thumb    = Get-LocalFileName $thumbUrl
        thumbUrl = $thumbUrl
        filename = if ($orig) { $orig } else { $file }
        w        = $w
        h        = $h
        size     = $details.Size
        deleted  = [bool]$deleted
    }
}

# Extract every attachment from the part of a post between its header and its message
# The file's own URL. Flash posts link to 7chan's Ruffle player page (play.html?swf=...), so prefer the
# download link, then any direct /src/ link
function Get-FileSourceUrl($html) {
    $m = [regex]::Match($html, '<a href="([^"]+)" download=')
    if ($m.Success) { return $m.Groups[1].Value }
    $m = [regex]::Match($html, 'href="([^"?]*/src/[^"?]+)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return [regex]::Match($html, 'href="([^"]+)"').Groups[1].Value
}

function Get-PostFiles($filesHtml) {
    $files = [System.Collections.ArrayList]::new()

    # Posts with several files use one "multithumb" block per file
    $multi = [regex]::Matches($filesHtml, '<span class="multithumb(?:first)?">')
    if ($multi.Count -gt 0) {
        for ($i = 0; $i -lt $multi.Count; $i++) {
            $start = $multi[$i].Index
            $end = if ($i + 1 -lt $multi.Count) { $multi[$i + 1].Index } else { $filesHtml.Length }
            $seg = $filesHtml.Substring($start, $end - $start)

            $src = Get-FileSourceUrl $seg
            $idAttr = [regex]::Match($seg, 'id="(expandimg_[^"]+)"').Groups[1].Value
            $download = [regex]::Match($seg, 'download="([^"]*)"').Groups[1].Value
            $img = [regex]::Match($seg, '<img[^>]*>').Value
            $thumbSrc = [regex]::Match($img, 'src="([^"]+)"').Groups[1].Value
            $title = [System.Net.WebUtility]::HtmlDecode([regex]::Match($img, 'title="([^"]*)"').Groups[1].Value)
            if (-not $src) { continue }
            [void]$files.Add((New-FileEntry $src $thumbSrc $idAttr $download $title $false))
        }
        return $files.ToArray()
    }

    # Single file: <div class="post_thumb"> (or <div class="nothumb">) followed by <p class="file_size">
    $sizeMatch = [regex]::Match($filesHtml, '(?s)<p class="file_size">(.*?)</p>')
    if ($sizeMatch.Success) {
        $sizeHtml = $sizeMatch.Groups[1].Value
        $src = Get-FileSourceUrl $sizeHtml
        $idAttr = [regex]::Match($sizeHtml, 'id="(expandimg_[^"]+)"').Groups[1].Value
        $download = [regex]::Match($sizeHtml, 'download="([^"]*)"').Groups[1].Value
        $thumbSrc = [regex]::Match($filesHtml, '(?s)class="post_thumb"[^>]*>.*?<img[^>]*src="([^"]+)"').Groups[1].Value
        $deleted = $filesHtml -match '(?s)class="nothumb">\s*File<br\s*/?>\s*Removed'
        # Drop the inline webm/flash player's [Close] control before reading the "(size, WxH, name)" part
        $text = ConvertFrom-HtmlText ($sizeHtml -replace '(?s)<span class="(?:webm|swf)close".*?</span>', '')
        if ($src) {
            [void]$files.Add((New-FileEntry $src $thumbSrc $idAttr $download $text $deleted))
        }
    }
    return $files.ToArray()
}

function ConvertFrom-7chanPost($block, $no, $threadId) {
    $header = [regex]::Match($block, '(?s)<div class="post_header">(.*?)<span class="reflink">').Groups[1].Value

    $sub = ConvertFrom-HtmlText ([regex]::Match($header, '(?s)<span class="subject">(.*?)</span>').Groups[1].Value)
    $nameHtml = [regex]::Match($header, '(?s)<span class="postername">(.*?)</span>').Groups[1].Value
    $email = [System.Net.WebUtility]::HtmlDecode([regex]::Match($nameHtml, 'href="mailto:([^"]*)"').Groups[1].Value)
    $trip = ConvertFrom-HtmlText ([regex]::Match($header, '(?s)<span class="postertrip">(.*?)</span>').Groups[1].Value)
    $capcode = [regex]::Match($header, 'class="capcode_([a-z]+)"').Groups[1].Value
    $capLabel = ConvertFrom-HtmlText ([regex]::Match($header, '(?s)class="capcode">(.*?)</span>').Groups[1].Value)

    # Dates look like 25/05/13(Tue)08:18
    $headerText = ConvertFrom-HtmlText ($header -replace '(?s)<span.*?</span>', '')
    $dateMatch = [regex]::Match($headerText, '\d{2}/\d{2}/\d{2}\s*\(\w+\)\s*\d{2}:\d{2}(?::\d{2})?')
    $now = if ($dateMatch.Success) { $dateMatch.Value } else { $headerText }

    $msgIndex = $block.IndexOf('<p class="message">')
    $com = ""
    $filesHtml = $block
    if ($msgIndex -ge 0) {
        $filesHtml = $block.Substring(0, $msgIndex)
        $com = [regex]::Match($block.Substring($msgIndex), '(?s)<p class="message">(.*)</p>').Groups[1].Value.Trim()
    }
    $headerEnd = $filesHtml.IndexOf('</div>', [Math]::Max(0, $filesHtml.IndexOf('<div class="post_header">')))
    if ($headerEnd -ge 0) { $filesHtml = $filesHtml.Substring($headerEnd) }

    return [pscustomobject]@{
        no       = [long]$no
        resto    = if ([long]$no -eq [long]$threadId) { 0 } else { [long]$threadId }
        sub      = $sub
        name     = ConvertFrom-HtmlText $nameHtml
        email    = $email
        trip     = $trip
        capcode  = $capcode
        capLabel = $capLabel
        now      = $now
        com      = $com
        files    = @(Get-PostFiles $filesHtml)
    }
}

# Parse a 7chan (Kusaba X) thread page into the structure saved as thread.json
function ConvertFrom-7chanThread($html, $board, $threadId) {
    $boardTitle = ""
    $titleMatch = [regex]::Match($html, '<a title="([^"]*)" href="/' + [regex]::Escape($board) + '/">')
    if ($titleMatch.Success) { $boardTitle = [System.Net.WebUtility]::HtmlDecode($titleMatch.Groups[1].Value) }

    $starts = [regex]::Matches($html, '<div class="post" id="?(\d+)"?>')
    $posts = [System.Collections.ArrayList]::new()
    $opBlock = ""
    for ($i = 0; $i -lt $starts.Count; $i++) {
        $start = $starts[$i].Index
        $end = if ($i + 1 -lt $starts.Count) { $starts[$i + 1].Index } else { $html.Length }
        $block = $html.Substring($start, $end - $start)
        # Every post ends with <br class="clear-both" />; cut there so the last post doesn't swallow the page footer
        $clear = $block.IndexOf('<br class="clear-both"')
        if ($clear -ge 0) { $block = $block.Substring(0, $clear) }
        if ($i -eq 0) { $opBlock = $block }
        [void]$posts.Add((ConvertFrom-7chanPost $block $starts[$i].Groups[1].Value $threadId))
    }

    if ($posts.Count -eq 0 -or [string]$posts[0].no -ne [string]$threadId) {
        throw "Could not find thread #$threadId in the page (7chan's layout may have changed)"
    }

    return [pscustomobject]@{
        source     = "7chan"
        board      = $board
        boardTitle = $boardTitle
        threadId   = [long]$threadId
        sticky     = [bool]($opBlock -match 'class="stickied"')
        locked     = [bool]($opBlock -match 'locked\.gif|class="locked"')
        posts      = $posts.ToArray()
    }
}

# Emoticons are images on 7chan's servers embedded in message HTML
function Get-EmoteUrls($com) {
    if (-not $com) { return @() }
    return @([regex]::Matches($com, "<img src=['""](https?://(?:www\.)?7chan\.org/[^'""]+)['""]") | ForEach-Object { $_.Groups[1].Value })
}

function ConvertTo-ThreadJson($thread) {
    return ($thread | ConvertTo-Json -Depth 10)
}

# Every file the thread references, as paths relative to images/: attachments, thumbnails and emoticons.
# Files 7chan shows as "File Removed" are left out, so they are never downloaded.
function Get-ThreadFiles($thread) {
    $list = [System.Collections.ArrayList]::new()
    $seen = @{}
    foreach ($post in $thread.posts) {
        foreach ($f in @($post.files)) {
            if (-not $f -or $f.deleted -or -not $f.url -or -not $f.file) { continue }
            if (-not $seen.ContainsKey($f.file)) {
                $seen[$f.file] = $true
                [void]$list.Add(@{ Url = $f.url; Name = $f.file; Type = "image" })
            }
            if ($f.thumbUrl -and $f.thumb -and -not $seen.ContainsKey($f.thumb)) {
                $seen[$f.thumb] = $true
                [void]$list.Add(@{ Url = $f.thumbUrl; Name = $f.thumb; Type = "thumb" })
            }
        }
        foreach ($emoteUrl in (Get-EmoteUrls $post.com)) {
            $emoteName = Get-LocalFileName $emoteUrl
            $key = "emotes/$emoteName"
            if ($emoteName -and -not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                [void]$list.Add(@{ Url = $emoteUrl; Name = $key; Type = "thumb" })
            }
        }
    }
    return $list.ToArray()
}

function Get-DownloadTasks($thread, $imgDir) {
    $tasks = [System.Collections.ArrayList]::new()
    foreach ($item in (Get-ThreadFiles $thread)) {
        [void]$tasks.Add(@{ Url = $item.Url; Dest = Join-Path $imgDir $item.Name; Name = $item.Name; Type = $item.Type })
    }
    return $tasks.ToArray()
}

# Delete saved files that the previous archive referenced but the fresh page no longer does,
# so posts and files removed by 7chan's moderators are removed from the archive as well.
# Only files named in the old thread.json are touched. Returns how many attachments were removed.
function Remove-DeletedFiles($oldThread, $newThread, $imgDir) {
    if (-not $oldThread -or -not $oldThread.posts) { return 0 }
    $keep = @{}
    foreach ($item in (Get-ThreadFiles $newThread)) { $keep[$item.Name] = $true }

    $removed = 0
    foreach ($item in (Get-ThreadFiles $oldThread)) {
        if ($keep.ContainsKey($item.Name)) { continue }
        $path = Join-Path $imgDir $item.Name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
            if ($item.Type -eq "image") { $removed++ }
        }
    }
    return $removed
}

# Download files in parallel through curl. Returns the names of attachments that failed.
function Invoke-ParallelDownloads($pending, $Concurrency, $DelayMs, $Indent = "  ") {
    $failedImages = [System.Collections.ArrayList]::new()
    $curl = Get-CurlPath

    foreach ($task in $pending) {
        $dir = Split-Path $task.Dest -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }

    $pool = [RunspaceFactory]::CreateRunspacePool(1, $Concurrency)
    $pool.Open()

    $downloadScript = {
        param($Curl, $Url, $Dest, $UserAgent, $DelayMs)
        if ($DelayMs -gt 0) {
            Start-Sleep -Milliseconds $DelayMs
        }
        # Write to .part and rename on success so an interrupted download is never mistaken for a finished one
        $part = "$Dest.part"
        # --retry backs off exponentially on timeouts, 429 and 5xx
        $httpCode = & $Curl -s -f -L -A $UserAgent --connect-timeout 15 --max-time 600 --retry 3 -o $part -w "%{http_code}" $Url
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0 -and (Test-Path -LiteralPath $part)) {
            Move-Item -LiteralPath $part -Destination $Dest -Force
            return @{ Success = $true }
        }
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        $err = if ($exitCode -eq 22) { "HTTP $httpCode" } elseif ($exitCode -eq 28) { "Timed out" } else { "curl exit code $exitCode" }
        return @{ Success = $false; Error = $err }
    }

    $runspaces = [System.Collections.ArrayList]::new()
    $total = @($pending).Count
    $completed = 0

    try {
        foreach ($task in $pending) {
            $ps = [PowerShell]::Create().AddScript($downloadScript).AddArgument($curl).AddArgument($task.Url).AddArgument($task.Dest).AddArgument($UserAgent).AddArgument($DelayMs)
            $ps.RunspacePool = $pool

            [void]$runspaces.Add(@{
                Pipe   = $ps
                Handle = $ps.BeginInvoke()
                Task   = $task
            })

            if ($DelayMs -gt 0) {
                Start-Sleep -Milliseconds $DelayMs
            }
        }

        while ($runspaces.Count -gt 0) {
            $done = @()
            for ($i = 0; $i -lt $runspaces.Count; $i++) {
                $rs = $runspaces[$i]
                if ($rs.Handle.IsCompleted) {
                    $result = $rs.Pipe.EndInvoke($rs.Handle)
                    $rs.Pipe.Dispose()
                    $completed++

                    if ($result -and $result[0].Success) {
                        if ($rs.Task.Type -eq "image") {
                            Write-Host "${Indent}[$completed/$total] $($rs.Task.Name)" -ForegroundColor Green
                        }
                    } elseif ($rs.Task.Type -eq "image") {
                        [void]$failedImages.Add($rs.Task.Name)
                        $err = if ($result) { $result[0].Error } else { "unknown" }
                        Write-Host "${Indent}[$completed/$total] FAILED: $($rs.Task.Name) - $err" -ForegroundColor Red
                    }

                    $done += $i
                }
            }

            for ($j = $done.Count - 1; $j -ge 0; $j--) {
                $runspaces.RemoveAt($done[$j])
            }

            if ($runspaces.Count -gt 0) {
                Start-Sleep -Milliseconds 200
            }
        }
    } finally {
        $pool.Close()
        $pool.Dispose()
    }

    return $failedImages.ToArray()
}

# Generate a clean, filesystem-safe slug from thread title or comment text
function Get-SanitizedSlug($text) {
    if (-not $text) { return "" }
    # Strip HTML tags
    $clean = $text -replace '<[^>]+>', ' '
    # Decode HTML entities
    try {
        $clean = [System.Net.WebUtility]::HtmlDecode($clean)
    } catch {
        $clean = $clean.Replace("&amp;", "&").Replace("&lt;", "<").Replace("&gt;", ">").Replace("&quot;", '"').Replace("&#39;", "'")
    }
    # Lowercase
    $clean = $clean.ToLowerInvariant()
    # Replace non-alphanumeric chars (keep hyphens and spaces) with spaces
    $clean = $clean -replace '[^a-z0-9\s-]', ' '
    # Replace spaces and multiple hyphens/underscores with single hyphens
    $clean = $clean -replace '[\s_]+', '-'
    $clean = $clean -replace '-+', '-'
    # Trim leading/trailing hyphens
    $clean = $clean.Trim('-')
    # Truncate to max 50 chars
    if ($clean.Length -gt 50) {
        $clean = $clean.Substring(0, 50).TrimEnd('-')
    }
    return $clean
}

# Find existing archive directory for a given board and thread ID regardless of title slug
function Get-ExistingArchiveDir($archiveRoot, $board, $threadId) {
    if (-not (Test-Path $archiveRoot)) { return $null }
    $matching = Get-ChildItem $archiveRoot -Directory | Where-Object { $_.Name -match "^${board}_${threadId}(?:_.*)?$" } | Select-Object -First 1
    if ($matching) {
        return $matching.FullName
    }
    return $null
}

# Parse board, thread ID, and optional title slug from an archive folder name
function Parse-ArchiveFolderName($folderName) {
    if ($folderName -match '^([a-z0-9]+)_(\d+)(?:_(.*))?$') {
        return @{
            Board    = $Matches[1]
            ThreadId = $Matches[2]
            Slug     = $Matches[3]
        }
    }
    return $null
}
