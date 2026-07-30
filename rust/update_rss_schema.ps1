$old = @"
    articleStyle INTEGER NOT NULL DEFAULT 0,
    singleUrl INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(sourceUrl)
"@

$new = @"
    articleStyle INTEGER NOT NULL DEFAULT 0,
    singleUrl INTEGER NOT NULL DEFAULT 0,
    jsLib TEXT,
    enabledCookieJar INTEGER DEFAULT 0,
    contentWhitelist TEXT,
    contentBlacklist TEXT,
    shouldOverrideUrlLoading TEXT,
    injectJs TEXT,
    preloadJs TEXT,
    startHtml TEXT,
    startStyle TEXT,
    startJs TEXT,
    showWebLog INTEGER NOT NULL DEFAULT 0,
    type INTEGER NOT NULL DEFAULT 0,
    preload INTEGER NOT NULL DEFAULT 0,
    cacheFirst INTEGER NOT NULL DEFAULT 0,
    searchUrl TEXT,
    PRIMARY KEY(sourceUrl)
"@

$content = Get-Content -Path "legado-db\src\schema.rs" -Raw
$content = $content -replace [regex]::Escape($old), $new
Set-Content -Path "legado-db\src\schema.rs" -Value $content -NoNewline -Encoding UTF8
Write-Output "Schema updated"
