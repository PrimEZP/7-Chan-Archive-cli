param(
    [string]$ArchiveName
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\utils.ps1"

$archiveRoot = Join-Path $PSScriptRoot "archives"

if (-not (Test-Path $archiveRoot)) {
    Write-Host "No archives folder found." -ForegroundColor Yellow
    exit 0
}

# Get list of archive folders
if ($ArchiveName) {
    $folders = @(Get-Item (Join-Path $archiveRoot $ArchiveName) -ErrorAction SilentlyContinue)
    if (-not $folders) {
        Write-Host "Archive not found: $ArchiveName" -ForegroundColor Red
        exit 1
    }
} else {
    $folders = Get-ChildItem $archiveRoot -Directory
}

# Convert 7chan message HTML into archive HTML: local quote links, greentext, absolute site links, local emoticons
function Convert-Comment($com, $threadId, $imgDir) {
    if (-not $com) { return "" }
    # >>links to posts in this thread: <a href="/pr/res/3818.html#5045" class="ref|pr|3818|5045">&gt;&gt;5045</a>
    $com = $com -replace ('<a href="[^"]*" class="ref\|[a-z0-9]+\|' + $threadId + '\|(\d+)">(.*?)</a>'), '<a class="quotelink" href="#p$1">$2</a>'
    # >>links to other threads go back to 7chan
    $com = $com -replace '<a href="[^"]*" class="ref\|([a-z0-9]+)\|(\d+)\|(\d+)">(.*?)</a>', ('<a class="quotelink external" href="' + $SiteRoot + '/$1/res/$2.html#$3" target="_blank">$4</a>')
    $com = $com.Replace('<span class="quote">', '<span class="greentext">')
    $com = $com -replace 'href="//', 'href="https://'
    $com = $com -replace 'href="/(?!/)', ('href="' + $SiteRoot + '/')
    foreach ($emoteUrl in (Get-EmoteUrls $com | Select-Object -Unique)) {
        $emoteName = Get-LocalFileName $emoteUrl
        if (Test-Path -LiteralPath (Join-Path (Join-Path $imgDir "emotes") $emoteName)) {
            $com = $com.Replace($emoteUrl, "images/emotes/" + (ConvertTo-UrlPath $emoteName))
        }
    }
    return $com.Trim()
}

# Percent-encode a file name for use in href/src and in single-quoted JS strings.
# .NET Framework leaves ' unescaped (.NET Core does not), so encode it explicitly.
function ConvertTo-UrlPath($name) {
    return [uri]::EscapeDataString($name).Replace("'", "%27")
}

function Get-FileHtml($f) {
    $name = $f.file
    $orig = if ($f.filename) { $f.filename } else { $name }
    if ($f.deleted) {
        return '  <div class="file"><div class="file-deleted">[File removed: ' + (Escape-Html $orig) + ']</div></div>' + "`n"
    }

    $ext = [System.IO.Path]::GetExtension($name).ToLowerInvariant()
    $isImage = $ext -match '^\.(jpe?g|png|gif|bmp|webp)$'
    $isVid = $ext -match '^\.(webm|mp4)$'
    $isAudio = $ext -match '^\.(mp3|ogg|wav|flac|m4a|opus)$'
    # Percent-encode so quotes, spaces and # in original file names can't break the markup or the link
    $src = "images/" + (ConvertTo-UrlPath $name)
    $thumbSrc = if ($f.thumb) { "images/" + (ConvertTo-UrlPath $f.thumb) } elseif ($isImage) { $src } else { "" }
    $canExpand = ($isImage -or $isVid) -and $thumbSrc

    $meta = @()
    if ($f.size) { $meta += $f.size }
    if ($f.w -and $f.h) { $meta += "$($f.w)x$($f.h)" }
    $metaStr = if ($meta.Count -gt 0) { " (" + ($meta -join ', ') + ")" } else { "" }

    $h = '  <div class="file">' + "`n"
    $h += '    <div class="file-info">File: <a href="' + $src + '" title="' + (Escape-Html $orig) + '">' + (Escape-Html $orig) + '</a>' + $metaStr
    if ($canExpand) { $h += ' <span class="expand-btn" onclick="toggleExpand(this)" title="Expand image inline">+</span>' }
    $h += '</div>' + "`n"

    if ($canExpand) {
        $h += '    <div class="post-image" data-w="' + $f.w + '" data-h="' + $f.h + '">' + "`n"
        $h += '      <a href="' + $src + '"><img src="' + $thumbSrc + '" alt="' + (Escape-Html $orig) + '" loading="lazy" onclick="return showFullImage(this, ''' + $src + ''')"></a>' + "`n"
        $h += '      <div class="resize-handle" title="Drag to resize"></div>' + "`n"
        $h += '    </div>' + "`n"
    } elseif ($isAudio) {
        $h += '    <div class="post-audio"><audio controls preload="none" src="' + $src + '"></audio></div>' + "`n"
    } elseif ($thumbSrc) {
        # Flash, PDFs and other downloads: the thumbnail (or 7chan's file-type icon) links to the file
        $h += '    <div class="post-file"><a href="' + $src + '"><img src="' + $thumbSrc + '" alt="' + (Escape-Html $orig) + '" loading="lazy"></a></div>' + "`n"
    } else {
        $label = if ($ext) { $ext.TrimStart('.').ToUpperInvariant() } else { "FILE" }
        $h += '    <div class="post-file"><a class="file-icon" href="' + $src + '">' + (Escape-Html $label) + '</a></div>' + "`n"
    }
    $h += '  </div>' + "`n"
    return $h
}

$styles = @'
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }

  body {
    background: #EEF2FF;
    color: #000000;
    font-family: Helvetica, Arial, sans-serif;
    font-size: 13px;
    line-height: 1.5;
  }

  a { color: #34345C; text-decoration: none; }
  a:hover { color: #DD0000; }

  .board-banner {
    background: #F1F1FA;
    border-bottom: 1px solid #C5C8D2;
    padding: 6px 12px;
    font-size: 11px;
    color: #4F5260;
    min-height: 32px;
    position: relative;
  }
  .board-banner .site-label { font-weight: bold; font-size: 13px; color: #4F5260; line-height: 20px; }

  .layout-toggle {
    position: absolute;
    right: 10px;
    top: 50%;
    transform: translateY(-50%);
    display: flex;
    gap: 4px;
    align-items: center;
  }
  .layout-toggle span { font-size: 10px; color: #666; margin-right: 2px; }
  .layout-btn {
    background: #D6DAF0;
    border: 1px solid #C5C8D2;
    color: #333;
    font-size: 11px;
    padding: 2px 8px;
    cursor: pointer;
    border-radius: 2px;
    user-select: none;
  }
  .layout-btn:hover { background: #C5C8E8; }
  .layout-btn.active { background: #9988EE; color: #fff; border-color: #7766CC; }

  .logo {
    text-align: center;
    font-size: 24pt;
    color: #AF0A0F;
    margin: 10px 0 4px 0;
    line-height: 1.2;
  }
  .logo-rule {
    height: 1px;
    border: 0;
    margin: 8px 0 10px 0;
    background: linear-gradient(to right, rgba(199,202,212,0.05), #C7CAD4 50%, rgba(199,202,212,0.05));
  }

  .archive-notice {
    background: #F9F9F9;
    border: 1px solid #C5C8D2;
    padding: 6px 10px;
    margin: 0 0 8px 0;
    font-size: 11px;
    text-align: center;
    color: #4F5260;
  }

  .container {
    margin: 0 2%;
  }

  .thread { margin-bottom: 20px; }

  .op {
    background: #F9F9F9;
    border: 1px solid #C5C8D2;
    padding: 0 10px 8px 10px;
    margin-bottom: 4px;
    display: flow-root;
  }
  .op .post-info {
    background: #D6DAF0;
    border-bottom: 1px solid #C5C8D2;
    margin: 0 -10px 8px -10px;
    padding: 0 .5em;
    line-height: 2em;
  }
  .op .post-image { float: left; margin: 4px 20px 10px 0; }
  .op .post-image img { max-width: 250px; max-height: 250px; border: 0; cursor: pointer; }
  .op .post-message { overflow: hidden; margin-left: 20px; }

  .reply {
    background: #E6EBFA;
    border: 1px solid #C5C8D2;
    display: table;
    clear: both;
    margin: 4px 0 4px 30px;
    padding: 2px 10px 6px 8px;
    max-width: 95%;
    position: relative;
  }
  .reply::before {
    content: '>>';
    position: absolute;
    left: -26px;
    top: 0;
    font-size: 1.4em;
    color: #4F5260;
  }
  .reply .post-image { float: left; margin: 4px 15px 4px 0; }
  .reply .post-image img { max-width: 200px; max-height: 200px; border: 0; cursor: pointer; }
  .reply .post-message { margin-left: 20px; }

  .files-multi { display: flow-root; }
  .files-multi .file { float: left; margin-right: 12px; max-width: 220px; }
  .files-multi .file .file-info { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .files-multi .post-image { float: none; margin: 2px 0 6px 0; }
  .files-multi .post-image img { max-width: 200px; max-height: 200px; }
  .files-multi .file.is-expanded { float: none; clear: both; max-width: none; }

  .post-audio { margin: 4px 0 6px 0; }
  .post-audio audio { width: 300px; max-width: 100%; }
  .post-file { float: left; margin: 4px 15px 6px 0; }
  .post-file img { max-width: 200px; max-height: 200px; border: 0; }
  .files-multi .post-file { float: none; }
  .file-icon {
    display: inline-block;
    min-width: 64px;
    padding: 18px 10px;
    text-align: center;
    font-weight: bold;
    color: #4F5260;
    background: #F1F1FA;
    border: 1px solid #C5C8D2;
    border-radius: 2px;
  }

  /* --- Grid mode overrides --- */
  body.grid-mode .container {
    margin: 0 2.5vw;
  }
  body.grid-mode .thread {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
    gap: 12px;
    align-items: start;
  }
  body.grid-mode .op {
    grid-column: 1 / -1;
    display: flow-root;
  }
  body.grid-mode .thread-stats {
    grid-column: 1 / -1;
  }
  body.grid-mode .reply {
    display: flex;
    flex-direction: column;
    width: 100%;
    max-width: none;
    margin: 0;
    padding: 10px;
    border-radius: 4px;
    box-shadow: 0 1px 3px rgba(0,0,0,0.08);
    background: #E6EBFA;
    border: 1px solid #C5C8D2;
    transition: transform 0.15s ease, box-shadow 0.15s ease;
  }
  body.grid-mode .reply::before { display: none; }
  body.grid-mode .reply:hover {
    transform: translateY(-2px);
    box-shadow: 0 4px 10px rgba(0,0,0,0.15);
  }
  body.grid-mode .reply .files-multi .file { float: none; max-width: none; margin-right: 0; }
  body.grid-mode .reply .post-image {
    float: none;
    margin: 8px 0;
    text-align: center;
    align-self: center;
    width: 100%;
  }
  body.grid-mode .reply .post-image img {
    max-width: 100%;
    max-height: 200px;
    width: auto;
    height: auto;
    object-fit: contain;
    border-radius: 2px;
  }
  body.grid-mode .reply .post-image.expanded {
    display: block;
    width: 100%;
  }
  body.grid-mode .reply .post-image.expanded img,
  body.grid-mode .reply .post-image.expanded video {
    max-width: 100%;
    max-height: none;
    height: auto;
  }
  body.grid-mode .reply .post-info {
    white-space: normal;
    font-size: 11px;
    border-bottom: 1px solid #C5C8D2;
    padding-bottom: 5px;
    margin-bottom: 6px;
    line-height: 1.3;
  }
  body.grid-mode .reply .file-info {
    font-size: 10px;
    color: #707070;
    margin-bottom: 4px;
    word-break: break-all;
  }
  body.grid-mode .reply .post-message {
    font-size: 12px;
    line-height: 1.4;
    max-height: 160px;
    overflow-y: auto;
    scrollbar-width: thin;
    scrollbar-color: #C5C8D2 transparent;
    border-top: 1px solid #D6DAF0;
    padding-top: 6px;
    margin: 6px 0 0 0;
  }
  body.grid-mode .reply .post-message::-webkit-scrollbar {
    width: 4px;
  }
  body.grid-mode .reply .post-message::-webkit-scrollbar-track {
    background: transparent;
  }
  body.grid-mode .reply .post-message::-webkit-scrollbar-thumb {
    background: #C5C8D2;
    border-radius: 2px;
  }
  body.grid-mode .reply .post-message::-webkit-scrollbar-thumb:hover {
    background: #9988EE;
  }

  .post-info { font-size: 12px; white-space: nowrap; margin-bottom: 2px; }
  .post-subject { color: #4F5260; font-weight: bold; font-size: 16px; }
  .post-name { color: #117743; font-weight: bold; }
  .post-name a { color: inherit; }
  .post-trip { color: #117743; }
  .post-date { color: #000000; }
  .post-number { color: #000000; cursor: pointer; }
  .post-number:hover { color: #DD0000; }
  .capcode { font-weight: bold; }
  .capcode_admin .post-name, .capcode_admin .post-trip, .capcode_admin .capcode { color: #F00000; }
  .capcode_mod .post-name, .capcode_mod .post-trip, .capcode_mod .capcode { color: #900090; }
  .capcode_system .post-name, .capcode_system .post-trip, .capcode_system .capcode { color: purple; }
  .thread-flag { color: #AF0A0F; font-weight: bold; font-size: 11px; }
  .backlink { font-size: 11px; display: inline-block; margin-left: 6px; vertical-align: middle; }
  .backlink a { color: #34345C; margin-right: 4px; }

  .file-info { color: #4F5260; font-size: 11px; margin-bottom: 2px; }
  .file-info a { color: #34345C; text-decoration: underline; }

  .expand-btn {
    display: inline-block;
    color: #707070;
    font-size: 11px;
    font-weight: bold;
    cursor: pointer;
    margin-left: 3px;
    padding: 0 3px;
    border: 1px solid #B8B8B8;
    border-radius: 2px;
    background: #F5F5FA;
    line-height: 14px;
    vertical-align: middle;
    user-select: none;
  }
  .expand-btn:hover { background: #E8E8F0; color: #555; }

  .post-message {
    margin-top: 2px;
    word-wrap: break-word;
    overflow-wrap: break-word;
    font-size: 13px;
    line-height: 1.5;
  }
  .post-message .quotelink { color: #34345C; text-decoration: none; cursor: pointer; }
  .post-message .quotelink:hover { color: #DD0000; text-decoration: underline; }
  .post-message .greentext { color: #789922; }
  .post-message .spoiler, .post-message .spoiler a { color: transparent; background-color: #000; }
  .post-message .spoiler:hover, .post-message .spoiler:hover a { color: #fff; }
  .post-message pre, .post-message code, .post-message .code {
    font-family: Consolas, Monaco, monospace;
    font-size: 12px;
    background: #F9F9F9;
    border: 1px solid #C5C8D2;
    padding: 4px 6px;
    white-space: pre-wrap;
  }
  .post-message img { vertical-align: middle; }

  .file-deleted { color: #707070; font-size: 11px; font-style: italic; margin: 4px 0; }

  .thread-stats {
    color: #4F5260;
    font-size: 11px;
    margin: 4px 0;
    padding: 4px 0;
    border-top: 1px solid #C5C8D2;
    border-bottom: 1px solid #C5C8D2;
  }

  .post-image.expanded {
    float: none !important;
    margin: 4px 0 10px 0 !important;
    position: relative;
    z-index: 100;
    display: inline-block;
  }
  .post-image.expanded img,
  .post-image.expanded video {
    max-width: none;
    max-height: none;
    height: auto;
    cursor: nwse-resize;
  }
  body.is-resizing * {
    pointer-events: none !important;
    cursor: nwse-resize !important;
  }
  img.resizing-target,
  video.resizing-target {
    image-rendering: -moz-crisp-edges;
    image-rendering: -webkit-optimize-contrast;
    image-rendering: pixelated;
    will-change: width;
    backface-visibility: hidden;
    transform: translateZ(0);
  }
  .resize-handle {
    display: none;
    position: absolute;
    bottom: 0;
    right: 0;
    width: 16px;
    height: 16px;
    cursor: nwse-resize;
    z-index: 101;
  }
  .resize-handle::after {
    content: '';
    position: absolute;
    bottom: 3px;
    right: 3px;
    width: 8px;
    height: 8px;
    border-right: 2px solid #888;
    border-bottom: 2px solid #888;
  }
  .post-image.expanded .resize-handle { display: block; }

  .image-full {
    display: none;
    position: fixed;
    top: 0; left: 0;
    width: 100vw; height: 100vh;
    background: rgba(0,0,0,0.85);
    z-index: 9999;
    cursor: zoom-out;
    justify-content: center;
    align-items: center;
  }
  .image-full img { max-width: 95vw; max-height: 95vh; object-fit: contain; }
  .image-full.active { display: flex; }
  .overlay-close {
    position: absolute;
    top: 20px;
    right: 20px;
    font-size: 40px;
    font-weight: bold;
    color: #fff;
    cursor: pointer;
    z-index: 10000;
    transition: color 0.15s ease, transform 0.15s ease;
    user-select: none;
    line-height: 1;
  }
  .overlay-close:hover {
    color: #ff3333;
    transform: scale(1.1);
  }

  .post-preview {
    position: absolute;
    z-index: 9000;
    background: #E6EBFA;
    border: 1px solid #C5C8D2;
    padding: 4px 8px;
    max-width: 420px;
    min-width: 200px;
    font-size: 12px;
    line-height: 1.4;
    box-shadow: 2px 2px 6px rgba(0,0,0,0.2);
    pointer-events: none;
    overflow: hidden;
  }
  .post-preview .pv-info { font-size: 11px; margin-bottom: 2px; white-space: nowrap; }
  .post-preview .pv-info .pv-subject { color: #4F5260; font-weight: bold; }
  .post-preview .pv-info .pv-name { color: #117743; font-weight: bold; }
  .post-preview .pv-image { float: left; margin: 2px 8px 2px 0; }
  .post-preview .pv-image img { max-width: 120px; max-height: 120px; }
  .post-preview .pv-msg { overflow: hidden; font-size: 12px; color: #000; word-wrap: break-word; max-height: 200px; overflow-y: auto; }
  .post-preview .pv-msg .greentext { color: #789922; }
  .post-preview .pv-msg .quotelink { color: #34345C; }

  .post-highlight { background: #D6BAD0 !important; }

  @media (max-width: 600px) {
    .container { margin: 0 4px; }
    .logo { font-size: 18pt; }
    .op .post-image img { max-width: 85vw; max-height: 50vh; }
    .reply { margin-left: 0; }
    .reply::before { display: none; }
    .reply .post-image img { max-width: 60vw; max-height: 40vh; }
    .post-info { white-space: normal; }
    .post-preview { max-width: 80vw; }
    .layout-toggle span { display: none; }
  }
</style>
'@

$viewerScript = @'
<script>
(function() {
  window.setLayout = function(mode) {
    document.body.classList.remove('list-mode', 'grid-mode');
    document.body.classList.add(mode + '-mode');
    document.getElementById('btn-list').classList.toggle('active', mode === 'list');
    document.getElementById('btn-grid').classList.toggle('active', mode === 'grid');
    try { localStorage.setItem('archive-layout', mode); } catch(e) {}
  };
  (function() {
    var saved = 'list';
    try { saved = localStorage.getItem('archive-layout') || 'list'; } catch(e) {}
    setLayout(saved);
  })();

  function isVideo(src) {
    return src.match(/\.(webm|mp4)$/i);
  }

  window.closeOverlay = function() {
    var overlay = document.getElementById('imageOverlay');
    overlay.classList.remove('active');
    overlay.innerHTML = ''; // Stop video playback and release resource
  };

  window.showFullImage = function(el, src) {
    if (el.closest('.post-image.expanded')) return false;

    var overlay = document.getElementById('imageOverlay');
    overlay.innerHTML = ''; // Clear previous contents

    // Create and append close button
    var closeBtn = document.createElement('span');
    closeBtn.className = 'overlay-close';
    closeBtn.innerHTML = '&times;';
    closeBtn.title = 'Close overlay (Esc)';
    closeBtn.onclick = function(ev) {
      ev.stopPropagation();
      closeOverlay();
    };
    overlay.appendChild(closeBtn);

    if (isVideo(src)) {
      var video = document.createElement('video');
      video.src = src;
      video.controls = true;
      video.autoplay = true;
      video.loop = true;
      video.style.maxWidth = '95vw';
      video.style.maxHeight = '95vh';
      video.style.objectFit = 'contain';
      // Prevent clicks on the video player/controls from closing the overlay
      video.onclick = function(ev) {
        ev.stopPropagation();
      };
      overlay.appendChild(video);
    } else {
      var img = document.createElement('img');
      img.src = src;
      img.alt = 'Full size';
      img.id = 'fullImg';
      img.style.maxWidth = '95vw';
      img.style.maxHeight = '95vh';
      img.style.objectFit = 'contain';
      overlay.appendChild(img);
    }

    overlay.classList.add('active');
    return false;
  };

  document.addEventListener('keydown', function(e) {
    if (e.key === 'Escape') {
      var overlay = document.getElementById('imageOverlay');
      overlay.classList.remove('active');
      overlay.innerHTML = '';
    }
  });

  // Each attachment lives in its own .file block; 7chan posts can carry several
  function fileParts(btn) {
    var fileEl = btn.closest('.file');
    if (!fileEl) return null;
    var imgDiv = fileEl.querySelector('.post-image');
    if (!imgDiv) return null;
    var aLink = imgDiv.querySelector('a');
    if (!aLink) return null;
    return { fileEl: fileEl, imgDiv: imgDiv, aLink: aLink, fullSrc: aLink.getAttribute('href') || aLink.getAttribute('data-href') };
  }

  window.toggleExpand = function(btn) {
    var parts = fileParts(btn);
    if (!parts) return;
    var imgDiv = parts.imgDiv, aLink = parts.aLink, fullSrc = parts.fullSrc;
    var media = imgDiv.querySelector('img, video');
    if (!media) return;
    var isVid = isVideo(fullSrc);

    if (imgDiv.classList.contains('expanded')) {
      imgDiv.classList.remove('expanded');
      parts.fileEl.classList.remove('is-expanded');
      if (isVid) {
        var thumbSrc = media.getAttribute('data-thumb');
        var altText = media.getAttribute('alt');
        aLink.innerHTML = '<img src="' + thumbSrc + '" alt="' + altText + '" loading="lazy" onclick="return showFullImage(this, \'' + fullSrc + '\')">';
        aLink.removeAttribute('data-href');
        aLink.setAttribute('href', fullSrc);
        aLink.onclick = null;
      } else {
        media.src = media.getAttribute('data-thumb');
        media.style.width = '';
      }
      btn.textContent = '+';
      btn.title = 'Expand image inline';
    } else {
      imgDiv.classList.add('expanded');
      parts.fileEl.classList.add('is-expanded');
      var w = parseInt(imgDiv.getAttribute('data-w')) || (isVid ? 300 : (media.naturalWidth || 300));
      var h = parseInt(imgDiv.getAttribute('data-h')) || (isVid ? 300 : (media.naturalHeight || 300));
      var aspect = w / h;
      var maxW = window.innerWidth * 0.9;
      var maxH = window.innerHeight * 0.8;
      var targetW = w;
      if (targetW > maxW) {
        targetW = maxW;
      }
      var targetH = targetW / aspect;
      if (targetH > maxH) {
        targetH = maxH;
        targetW = targetH * aspect;
      }
      var initialWidth = Math.round(targetW) + 'px';

      if (isVid) {
        var thumbSrc = media.src;
        var altText = media.alt;
        var video = document.createElement('video');
        video.src = fullSrc;
        video.controls = true;
        video.autoplay = true;
        video.loop = true;
        video.muted = true;
        video.setAttribute('data-thumb', thumbSrc);
        video.setAttribute('alt', altText);
        video.style.width = initialWidth;
        aLink.innerHTML = '';
        aLink.appendChild(video);

        aLink.setAttribute('data-href', fullSrc);
        aLink.removeAttribute('href');
        aLink.onclick = function(ev) {
          ev.preventDefault();
          return false;
        };
      } else {
        media.setAttribute('data-thumb', media.src);
        media.src = fullSrc;
        media.style.width = initialWidth;
      }
      btn.textContent = '\u2013';
      btn.title = 'Collapse image';
    }
  };

  window.toggleExpandAll = function() {
    var buttons = document.querySelectorAll('.expand-btn');
    var anyCollapsed = false;

    // Check if there is any static image that is currently collapsed
    for (var i = 0; i < buttons.length; i++) {
      var parts = fileParts(buttons[i]);
      if (parts && parts.fullSrc && !isVideo(parts.fullSrc) && !parts.imgDiv.classList.contains('expanded')) {
        anyCollapsed = true;
        break;
      }
    }

    var targetState = anyCollapsed; // true to expand, false to collapse

    for (var i = 0; i < buttons.length; i++) {
      var parts = fileParts(buttons[i]);
      if (!parts || !parts.fullSrc || isVideo(parts.fullSrc)) continue;
      var isExpanded = parts.imgDiv.classList.contains('expanded');
      if (targetState !== isExpanded) {
        toggleExpand(buttons[i]);
      }
    }

    var btnAll = document.getElementById('btn-expand-all');
    if (btnAll) {
      btnAll.textContent = targetState ? 'Collapse Images' : 'Expand Images';
      btnAll.classList.toggle('active', targetState);
    }
  };

  // --- High-Performance Drag-to-resize on expanded images using requestAnimationFrame ---
  document.addEventListener('mousedown', function(e) {
    var imgDiv = e.target.closest('.post-image.expanded');
    if (!imgDiv) return;
    var img = imgDiv.querySelector('img, video');
    if (!img || e.target !== img) return;

    e.preventDefault();
    var startX = e.clientX;
    var startW = img.offsetWidth;
    var currentX = e.clientX;
    var ticking = false;

    function onMove(ev) {
      currentX = ev.clientX;
      if (!ticking) {
        window.requestAnimationFrame(updateResize);
        ticking = true;
      }
    }

    function updateResize() {
      var multiplier = Math.max(1, startW / 200);
      img.style.width = Math.max(50, startW + (currentX - startX) * multiplier) + 'px';
      ticking = false;
    }

    function onUp() {
      document.removeEventListener('mousemove', onMove);
      document.removeEventListener('mouseup', onUp);
      document.body.style.cursor = '';
      document.body.style.userSelect = '';
      document.body.classList.remove('is-resizing');
      img.classList.remove('resizing-target');
    }

    document.body.style.cursor = 'nwse-resize';
    document.body.style.userSelect = 'none';
    document.body.classList.add('is-resizing');
    img.classList.add('resizing-target');
    document.addEventListener('mousemove', onMove);
    document.addEventListener('mouseup', onUp);
  });

  var previewEl = document.getElementById('postPreview');
  var previewTimer = null;
  document.addEventListener('mouseover', function(e) {
    var link = e.target.closest('.quotelink');
    if (!link) return;
    var href = link.getAttribute('href');
    if (!href || href.charAt(0) !== '#') return;
    var target = document.getElementById(href.substring(1));
    if (!target) return;
    clearTimeout(previewTimer);
    previewTimer = setTimeout(function() {
      previewEl.innerHTML = buildPreview(target);
      previewEl.style.display = 'block';
      positionPreview(link);
    }, 250);
  });
  document.addEventListener('mouseout', function(e) {
    if (!e.target.closest('.quotelink')) return;
    clearTimeout(previewTimer);
    previewEl.style.display = 'none';
  });
  function positionPreview(link) {
    var rect = link.getBoundingClientRect();
    var left = rect.left + window.scrollX;
    var top = rect.bottom + window.scrollY + 4;
    if (left + previewEl.offsetWidth > window.innerWidth - 10) left = window.innerWidth - previewEl.offsetWidth - 10;
    if (left < 5) left = 5;
    if (top + previewEl.offsetHeight > window.innerHeight + window.scrollY - 10) top = rect.top + window.scrollY - previewEl.offsetHeight - 4;
    previewEl.style.left = left + 'px';
    previewEl.style.top = top + 'px';
  }
  function buildPreview(post) {
    var info = post.querySelector('.post-info');
    var imgEl = post.querySelector('.post-image img');
    var msgEl = post.querySelector('.post-message');
    var h = '<div class="pv-info">';
    var s;
    if (info && (s = info.querySelector('.post-subject'))) h += '<span class="pv-subject">' + s.textContent + '</span> ';
    if (info && (s = info.querySelector('.post-name'))) h += '<span class="pv-name">' + s.textContent + '</span> ';
    if (info && (s = info.querySelector('.post-date'))) h += '<span>' + s.textContent + '</span> ';
    if (info && (s = info.querySelector('.post-number'))) h += '<span>' + s.textContent + '</span>';
    h += '</div>';
    if (imgEl) h += '<div class="pv-image"><img src="' + (imgEl.getAttribute('data-thumb') || imgEl.src) + '" alt=""></div>';
    if (msgEl) h += '<div class="pv-msg">' + msgEl.innerHTML + '</div>';
    return h;
  }

  document.addEventListener('click', function(e) {
    var link = e.target.closest('a.quotelink');
    if (!link) return;
    var href = link.getAttribute('href');
    if (!href || href.charAt(0) !== '#') return;
    var target = document.getElementById(href.substring(1));
    if (!target) return;
    e.preventDefault();
    previewEl.style.display = 'none';
    target.scrollIntoView({ behavior: 'smooth', block: 'center' });
    target.classList.add('post-highlight');
    setTimeout(function() { target.classList.remove('post-highlight'); }, 2000);
    history.replaceState(null, '', href);
  });
  document.addEventListener('click', function(e) {
    var num = e.target.closest('.post-number');
    if (!num) return;
    var post = num.closest('.op, .reply');
    if (!post) return;
    post.classList.add('post-highlight');
    setTimeout(function() { post.classList.remove('post-highlight'); }, 1500);
  });
})();
</script>
'@

$updated = 0
$skipped = 0
$errors = @()

foreach ($folder in $folders) {
    $jsonPath = Join-Path $folder.FullName "thread.json"
    $htmlPath = Join-Path $folder.FullName "thread.html"
    $imgDir = Join-Path $folder.FullName "images"

    if (-not (Test-Path $jsonPath)) {
        Write-Host "  SKIP $($folder.Name) - no thread.json" -ForegroundColor DarkGray
        $skipped++
        continue
    }

    # Parse board and threadId from folder name
    $info = Parse-ArchiveFolderName $folder.Name
    if (-not $info) {
        Write-Host "  SKIP $($folder.Name) - unexpected folder name format" -ForegroundColor DarkGray
        $skipped++
        continue
    }
    $board = $info.Board
    $threadId = $info.ThreadId

    try {
        $thread = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $posts = @($thread.posts)
        $op = $posts[0]

        $boardTitle = if ($thread.boardTitle) { "/$board/ - $($thread.boardTitle)" } else { "/$board/" }
        $threadTitle = if ($op.sub) { $op.sub } else { "Thread #$threadId" }
        $threadUrl = "$SiteRoot/$board/res/$threadId.html"
        $archivedDate = if (Test-Path $htmlPath) {
            # Try to keep original date from existing HTML
            $existing = Get-Content $htmlPath -Raw
            if ($existing -match 'Locally archived on (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
                $Matches[1]
            } else {
                Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }
        } else {
            Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }

        # --- Backlinks: which posts quote each post ---
        $backlinks = @{}
        foreach ($p in $posts) {
            if (-not $p.com) { continue }
            foreach ($m in [regex]::Matches($p.com, 'class="ref\|[a-z0-9]+\|' + $threadId + '\|(\d+)"')) {
                $targetId = $m.Groups[1].Value
                if (-not $backlinks.ContainsKey($targetId)) {
                    $backlinks[$targetId] = [System.Collections.Generic.List[string]]::new()
                }
                if (-not $backlinks[$targetId].Contains($p.no.ToString())) {
                    $backlinks[$targetId].Add($p.no.ToString())
                }
            }
        }

        $sb = [System.Text.StringBuilder]::new()

        [void]$sb.Append(@"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>$(Escape-Html $threadTitle) - $(Escape-Html $boardTitle) - 7chan Archive</title>
$styles
</head>
<body>

  <div class="board-banner">
    <span class="site-label">7chan Archive</span>
    <div class="layout-toggle">
      <button class="layout-btn" onclick="toggleExpandAll()" id="btn-expand-all" title="Expand/Collapse all static images inline">Expand Images</button>
      <span>Layout:</span>
      <button class="layout-btn active" onclick="setLayout('list')" id="btn-list">List</button>
      <button class="layout-btn" onclick="setLayout('grid')" id="btn-grid">Grid</button>
    </div>
  </div>

<div class="container">

<div class="logo">$(Escape-Html $boardTitle)</div>
<hr class="logo-rule">

<div class="archive-notice">
  Locally archived on $archivedDate &mdash;
  Source: <a href="$threadUrl">7chan.org/$board/res/$threadId.html</a>
  &mdash; All images stored locally
</div>

<div class="thread" data-board="$board" data-thread-id="$threadId">

"@)

        foreach ($post in $posts) {
            $isOp = ($post.resto -eq 0)
            $divClass = if ($isOp) { "op" } else { "reply" }

            [void]$sb.Append('<div class="' + $divClass + '" id="p' + $post.no + '" data-postno="' + $post.no + '">' + "`n")
            [void]$sb.Append('  <div class="post-info">')

            if ($post.sub) {
                [void]$sb.Append('<span class="post-subject">' + (Escape-Html $post.sub) + '</span> ')
            }

            if ($post.capcode) {
                [void]$sb.Append('<span class="capcode_' + (Escape-Html $post.capcode) + '">')
            }
            $nameHtml = Escape-Html $post.name
            if ($post.email) {
                $nameHtml = '<a href="mailto:' + (Escape-Html $post.email) + '">' + $nameHtml + '</a>'
            }
            [void]$sb.Append('<span class="post-name">' + $nameHtml + '</span>')
            if ($post.trip) {
                [void]$sb.Append('<span class="post-trip">' + (Escape-Html $post.trip) + '</span>')
            }
            if ($post.capcode) {
                $capLabel = if ($post.capLabel) { $post.capLabel } else { "## $($post.capcode) ##" }
                [void]$sb.Append(' <span class="capcode">' + (Escape-Html $capLabel) + '</span></span>')
            }
            [void]$sb.Append(' ')

            [void]$sb.Append('<span class="post-date">' + (Escape-Html $post.now) + '</span> ')
            [void]$sb.Append('<a class="post-number" href="#p' + $post.no + '">No.' + $post.no + '</a>')

            if ($isOp -and $thread.sticky) { [void]$sb.Append(' <span class="thread-flag">[Sticky]</span>') }
            if ($isOp -and $thread.locked) { [void]$sb.Append(' <span class="thread-flag">[Locked]</span>') }

            $postNoStr = $post.no.ToString()
            if ($backlinks.ContainsKey($postNoStr)) {
                [void]$sb.Append('<span class="backlink">')
                foreach ($quotedBy in $backlinks[$postNoStr]) {
                    [void]$sb.Append('<a class="quotelink" href="#p' + $quotedBy + '">&gt;&gt;' + $quotedBy + '</a>')
                }
                [void]$sb.Append('</span>')
            }

            [void]$sb.Append('</div>' + "`n")

            $files = @($post.files | Where-Object { $_ })
            if ($files.Count -gt 1) {
                [void]$sb.Append('  <div class="files-multi">' + "`n")
                foreach ($f in $files) { [void]$sb.Append((Get-FileHtml $f)) }
                [void]$sb.Append('  </div>' + "`n")
            } elseif ($files.Count -eq 1) {
                [void]$sb.Append((Get-FileHtml $files[0]))
            }

            if ($post.com) {
                $message = Convert-Comment $post.com $threadId $imgDir
                [void]$sb.Append('  <div class="post-message">' + $message + '</div>' + "`n")
            }

            [void]$sb.Append('</div>' + "`n")

            if ($isOp -and $posts.Count -gt 1) {
                $fileCount = 0
                foreach ($p in $posts) { $fileCount += @($p.files | Where-Object { $_ -and -not $_.deleted }).Count }
                $stats = @("$($posts.Count - 1) replies", "$fileCount files")
                if ($thread.sticky) { $stats += "STICKY" }
                if ($thread.locked) { $stats += "LOCKED" }
                [void]$sb.Append('<div class="thread-stats">' + "`n")
                [void]$sb.Append('  ' + ($stats -join ' &mdash; '))
                [void]$sb.Append("`n</div>`n")
            }
        }

        [void]$sb.Append('</div>' + "`n")

        [void]$sb.Append(@"

</div>

<div class="image-full" id="imageOverlay" onclick="closeOverlay(event)">
</div>

<div class="post-preview" id="postPreview" style="display:none"></div>

$viewerScript

</body>
</html>
"@)

        $sb.ToString() | Out-File -FilePath $htmlPath -Encoding UTF8
        Write-Host "  OK   $($folder.Name) ($($posts.Count) posts)" -ForegroundColor Green
        $updated++

    } catch {
        Write-Host "  ERR  $($folder.Name) - $($_.Exception.Message)" -ForegroundColor Red
        $errors += $folder.Name
    }
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host " Updated $updated archive(s)" -ForegroundColor Green
if ($skipped -gt 0) {
    Write-Host " Skipped $skipped (no thread.json)" -ForegroundColor DarkGray
}
if ($errors.Count -gt 0) {
    Write-Host " Errors: $($errors.Count)" -ForegroundColor Red
}
Write-Host "========================================" -ForegroundColor Green
