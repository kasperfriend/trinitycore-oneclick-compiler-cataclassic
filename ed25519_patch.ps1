# ============================================================================
# ed25519_patch.ps1  --  WoW Classic 4.4.2 (build 60895) Ed25519 key tool  v2
# ============================================================================
# Purpose
#   TrinityCore (cata_classic) signs SMSG_ENTER_ENCRYPTED_MODE with its own
#   Ed25519 private key. The stock 4.4.2 client verifies that signature
#   against Blizzard's Ed25519 public key embedded in WowClassic.exe.
#   wow-patcher deliberately skips the Ed25519 key patch for "Classic"
#   clients (it only RE'd 1.13.x), which is why the client aborts with
#   reason 24 right after AUTH success.
#
#   This script finds the embedded stock key (anchor: 15 D6 18 BD 7D B5 77 BD)
#   and replaces the 32 bytes at that offset with TrinityCore's public key
#   (02 59 6F 0D 0C 06 1A 8B ... 37 BA FC 69) -- the exact same bytes
#   wow-patcher writes for Retail clients. TC's public key was verified to
#   match TC's hardcoded Ed25519 private key by derivation.
#
#   The client layout around the key (confirmed by scan):
#     [anchor-48 .. anchor-32]  EnableEncryptionSeed  (32 B, TC value embedded)
#     [anchor-16 .. anchor]     EnableEncryptionContext (16 B, matches TC)
#     [anchor .. anchor+32]     Blizzard Ed25519 public key  <-- patched here
#
# Usage
#   Scan only (default):
#     powershell -ExecutionPolicy Bypass -File ed25519_patch.ps1
#   Patch (picks the first file that contains the anchor):
#     powershell -ExecutionPolicy Bypass -File ed25519_patch.ps1 -Patch
#   Patch a specific exe:
#     powershell -ExecutionPolicy Bypass -File ed25519_patch.ps1 -Patch -Exe "E:\CataC\CataClassic\_whitemane-60895_\WowPrivate.exe"
# ============================================================================

param(
    [string]$Base  = "E:\CataC\CataClassic\_whitemane-60895_",
    [string]$Exe   = "",
    [switch]$Patch,
    [switch]$ScanAll,
    [int]$Index    = 0,
    [string]$Out   = ""
)

# --- patterns ---------------------------------------------------------------
$STOCK_ANCHOR_HEX  = "15D618BD7DB577BD"   # first 8 bytes of Blizzard's Ed25519 pubkey
$TC_KEY_HEX        = "02596F0D0C061A8B30745988FD72C59E29EC367FB0F341F28E0F08D037BAFC69" # TrinityCore pubkey (verified == derive(TC private key))
$TC_PREFIX_HEX     = $TC_KEY_HEX.Substring(0, 16)
$TC_SEED_HEX       = "66BE2979EFF2D5B56153F65F45AE81CB32EC94EC75B35F446A63436717204434" # TC EnableEncryptionSeed (32 B)
$TC_CTX_HEX        = "A71FB69BC97CDD96E9BBB821398D5AD4"                                   # TC EnableEncryptionContext (16 B)

function HexToBytes([string]$h) {
    $b = New-Object byte[] ($h.Length / 2)
    for ($i = 0; $i -lt $b.Length; $i++) { $b[$i] = [Convert]::ToByte($h.Substring($i * 2, 2), 16) }
    return $b
}

function BytesToHex([byte[]]$b, [int]$start, [int]$len) {
    $sb = New-Object System.Text.StringBuilder ($len * 3)
    for ($i = $start; $i -lt $start + $len; $i++) {
        [void]$sb.Append($b[$i].ToString("X2"))
        [void]$sb.Append(" ")
    }
    return $sb.ToString().Trim()
}

# --- scanning ---------------------------------------------------------------
function Scan-File([string]$path, [string]$anchorHex, [string]$label) {
    if (-not [System.IO.File]::Exists($path)) {
        Write-Host ("  {0}: (not present: {1})" -f $label, $path) -ForegroundColor Yellow
        return $null
    }
    $fi = Get-Item $path -ErrorAction SilentlyContinue
    Write-Host ("  {0}: {1}  ({2:N1} MB)" -f $label, $fi.Name, ($fi.Length / 1MB)) -ForegroundColor Cyan
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $str   = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)   # Latin1: byte<->char 1:1, fast regex scan
    $pat   = ""
    for ($i = 0; $i -lt $anchorHex.Length; $i += 2) { $pat += "\x" + $anchorHex.Substring($i, 2) }
    $rx    = New-Object System.Text.RegularExpressions.Regex($pat)
    $ms    = $rx.Matches($str)
    Write-Host ("    pattern {0} -> {1} match(es)" -f $anchorHex, $ms.Count)
    $offsets = @()
    foreach ($m in $ms) {
        $offsets += $m.Index
        $key = BytesToHex $bytes $m.Index 32
        Write-Host ("    @ 0x{0:X8}  key32: {1}" -f $m.Index, $key) -ForegroundColor Gray
        $isTC = ($key -replace " ", "").StartsWith($TC_PREFIX_HEX, [System.StringComparison]::OrdinalIgnoreCase)
        if ($isTC) { Write-Host "              ^^ ALREADY TRINITYCORE KEY" -ForegroundColor Green }
    }
    return @{ Path = $path; Offsets = $offsets; Anchor = $anchorHex; Bytes = $bytes }
}

Write-Host "=== WoW Classic 4.4.2 (60895) Ed25519 scan ===" -ForegroundColor White
Write-Host "Stock anchor: $STOCK_ANCHOR_HEX (Blizzard key prefix)"
Write-Host "TC key:       $TC_KEY_HEX"

$files = @()
if ($ScanAll) {
    Write-Host ""
    Write-Host "ScanAll mode: walking $Base for *.exe / *.dll (this can take a while)..." -ForegroundColor Yellow
    $files = Get-ChildItem -Path $Base -Recurse -Include *.exe,*.dll -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
} elseif ($Exe -ne "") {
    $files = @($Exe)
} else {
    $files = @(
        (Join-Path $Base "WowPrivate.exe"),
        (Join-Path $Base "WowClassic.clean.exe"),
        (Join-Path $Base "WowClassic.exe")
    )
}

$stockResults = @()
foreach ($f in $files) {
    $r = Scan-File $f $STOCK_ANCHOR_HEX "stock"
    if ($r -and $r.Offsets.Count -gt 0) { $stockResults += $r }
}

# Region dump around the first found key (shows seed/context/next constants)
if ($stockResults.Count -gt 0) {
    $r0 = $stockResults[0]
    $a  = $r0.Offsets[$Index]
    $bb = $r0.Bytes
    if ($a -ge 64) {
        Write-Host ""
        Write-Host ("Region around key in {0} (offset 0x{1:X8}):" -f (Split-Path $r0.Path -Leaf), $a) -ForegroundColor Cyan
        Write-Host ("  [-64 .. -33] seed?   : {0}" -f (BytesToHex $bb ($a - 64) 32))
        Write-Host ("  [-32 .. -17] unknown : {0}" -f (BytesToHex $bb ($a - 32) 16))
        Write-Host ("  [-16 .. -1 ] ctx     : {0}" -f (BytesToHex $bb ($a - 16) 16))
        Write-Host ("  [  0 ..  31] KEY     : {0}" -f (BytesToHex $bb $a 32))
        Write-Host ("  [ 32 ..  47] after   : {0}" -f (BytesToHex $bb ($a + 32) 16))
        Write-Host ("  TC seed value        : {0}" -f $TC_SEED_HEX)
        Write-Host ("  TC ctx value         : {0}" -f $TC_CTX_HEX)
        $seedAt = BytesToHex $bb ($a - 48) 32
        $seedOk = (($seedAt -replace " ", "") -eq $TC_SEED_HEX)
        $ctxOk  = (($(BytesToHex $bb ($a - 16) 16) -replace " ", "") -eq $TC_CTX_HEX)
        Write-Host ("  seed matches TC (at -48)? {0}    ctx matches TC? {1}" -f $seedOk, $ctxOk) -ForegroundColor $(if ($seedOk -and $ctxOk) { "Green" } else { "Yellow" })
    }
}

# --- patching ---------------------------------------------------------------
if ($Patch) {
    if ($stockResults.Count -eq 0) {
        Write-Host ""
        Write-Host "!!! Stock Ed25519 anchor NOT found in any scanned file." -ForegroundColor Red
        Write-Host "    Patching aborted. Report this result back."
        exit 1
    }
    $src = $stockResults[0].Path
    $off = $stockResults[0].Offsets[$Index]
    if ($Out -eq "") { $Out = ($src -replace '\.exe$', '-ed25519.exe') }

    Write-Host ""
    Write-Host ("Patching: {0}" -f $src) -ForegroundColor Cyan
    Write-Host ("  anchor @ 0x{0:X8} -> writing 32-byte TrinityCore key" -f $off)

    Copy-Item $src $Out -Force
    $fs = [System.IO.File]::Open($Out, 'Open', 'ReadWrite')
    try {
        $fs.Seek($off, [System.IO.SeekOrigin]::Begin) | Out-Null
        $keyBytes = HexToBytes $TC_KEY_HEX
        $fs.Write($keyBytes, 0, $keyBytes.Length)
    } finally {
        $fs.Close()
    }

    $verify = Scan-File $Out $TC_PREFIX_HEX "verify"
    if ($verify -and $verify.Offsets.Count -gt 0) {
        Write-Host ""
        Write-Host "SUCCESS: TrinityCore Ed25519 key written." -ForegroundColor Green
        Write-Host ("Output:  {0}" -f $Out)
        Write-Host "Next: run the output exe and try to enter the realm."
    } else {
        Write-Host ""
        Write-Host "!!! Verification failed -- key not found in output. Do NOT use this file." -ForegroundColor Red
    }
} else {
    Write-Host ""
    Write-Host "Scan complete (no -Patch given). To patch, re-run with: -Patch" -ForegroundColor Yellow
}
