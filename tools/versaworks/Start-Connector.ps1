#requires -Version 5.1
[CmdletBinding()]
param([string[]]$AllowedOrigin = @())
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$authority = '127.0.0.1:43127'
$queue = 'C:\ProgramData\Roland DG Versaworks7\Printers\VG4-540\Input-A'
$parent = [IO.Path]::GetDirectoryName($queue)
$limit = 64MB
$ascii = [Text.Encoding]::ASCII
$origins = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($value in $AllowedOrigin) {
    $uri = $null
    if (![uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin 'http','https' -or $value.Contains('*') -or
        $uri.UserInfo -or $value -cne $uri.GetLeftPart([UriPartial]::Authority) -or
        $value -cnotmatch '\A[\x21-\x7e]+\z') { throw "Expected a canonical http(s) browser origin, not '$value'" }
    [void]$origins.Add($value)
}
if (!$origins.Count) { throw 'Specify -AllowedOrigin (see README.md).' }
if ($env:OS -ne 'Windows_NT') { throw 'This connector requires Windows.' }
# Flags=0: no replacement and, unlike MoveFile, no cross-volume copy fallback.
if (-not ('PdfTools.QueueRename' -as [type])) {
    Add-Type -Namespace PdfTools -Name QueueRename -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, SetLastError=true)]
public static extern bool MoveFileEx(string existing, string destination, uint flags);
'@
}
function Test-Queue {
    try {
        for ($dir = [IO.DirectoryInfo]::new($queue); $null -ne $dir; $dir = $dir.Parent) {
            if (!$dir.Exists -or ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
        }
        return $true
    } catch { return $false }
}
function Reject([int]$code) {
    $ex = [Exception]::new('Request rejected'); $ex.Data['status'] = $code; throw $ex
}
function Set-Deadline([int]$ms) {
    $left = $ms - $clock.ElapsedMilliseconds
    if ($left -le 0) { Reject 408 }
    $net.ReadTimeout = [int][Math]::Min([long]5000, $left)
}
function Reply([int]$code, [string]$body) {
    $reason = @{200='OK';201='Created';204='No Content';400='Bad Request';403='Forbidden';404='Not Found';405='Method Not Allowed';408='Request Timeout';411='Length Required';413='Content Too Large';415='Unsupported Media Type';422='Unprocessable Content';431='Headers Too Large';503='Service Unavailable'}[$code]
    $text = "HTTP/1.1 $code $reason`r`nConnection: close`r`nCache-Control: no-store`r`nVary: Origin, Access-Control-Request-Method, Access-Control-Request-Headers, Access-Control-Request-Private-Network`r`n"
    foreach ($key in $cors.Keys) { $text += "${key}: $($cors[$key])`r`n" }
    if ($code -ne 204) { $text += "Content-Type: application/json`r`nContent-Length: $($body.Length)`r`n" }
    $bytes = $ascii.GetBytes("$text`r`n$body"); $net.Write($bytes,0,$bytes.Length)
}
function Read-Head {
    $bytes = [byte[]]::new(16384)
    for ($i=0; $i -lt $bytes.Length; $i++) {
        Set-Deadline 10000
        $b = $reader.ReadByte()
        if ($b -lt 0 -or $b -gt 126 -or ($b -lt 32 -and $b -notin 9,10,13)) { Reject 400 }
        $bytes[$i] = $b
        if ($i -ge 3 -and $b -eq 10 -and $bytes[$i-1] -eq 13 -and $bytes[$i-2] -eq 10 -and $bytes[$i-3] -eq 13) {
            return $ascii.GetString($bytes,0,$i-3)
        }
    }
    Reject 431
}
function Publish([long]$length) {
    if (!(Test-Queue)) { Reject 503 }
    $id = [guid]::NewGuid().ToString('N'); $name = "pdf-tools-$id.pdf"
    $temp = [IO.Path]::Combine($parent,"pdf-tools-$id.part")
    $owned = $false
    try {
        $file = [IO.File]::Open($temp,'CreateNew','ReadWrite','None'); $owned = $true
        try {
            $buf = [byte[]]::new(65536); $left = $length
            while ($left -gt 0) {
                Set-Deadline 120000
                $n = $reader.Read($buf,0,[int][Math]::Min([long]$buf.Length,$left))
                if (!$n) { Reject 400 }
                $file.Write($buf,0,$n); $left -= $n
            }
            # Envelope checks only; no attempt to interpret or render untrusted PDFs.
            $file.Position = 0; $r = $file.Read($buf,0,9)
            if ($ascii.GetString($buf,0,$r) -cnotmatch '\A%PDF-(1\.[0-7]|2\.0)[\r\n]') { Reject 422 }
            $r = [int][Math]::Min([long]1024,$length); $file.Position = $length-$r
            $r = $file.Read($buf,0,$r)
            if ($ascii.GetString($buf,0,$r) -cnotmatch '(?:\r|\n)%%EOF[\x00\t\n\f\r ]*\z') { Reject 422 }
            $file.Flush($true)
        } finally { $file.Dispose() }
        if (!(Test-Queue) -or ![PdfTools.QueueRename]::MoveFileEx($temp,[IO.Path]::Combine($queue,$name),0)) { Reject 503 }
        $owned = $false; return $name
    } finally { if ($owned) { [IO.File]::Delete($temp) } }
}
function Serve($client) {
    $net = $client.GetStream(); $net.WriteTimeout = 5000
    $reader = [IO.BufferedStream]::new($net,8192); $clock = [Diagnostics.Stopwatch]::StartNew(); $cors = @{}
    try {
        $lines = (Read-Head) -split "`r`n"
        if ($lines[0] -cnotmatch '\A([A-Z]+) (/[^ ]*) HTTP/1\.1\z') { Reject 400 }
        $method = $Matches[1]; $route = $Matches[2]; $h = @{}
        for ($i=1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -cnotmatch '\A([A-Za-z0-9-]+):[ \t]*([^\r\n]*)\z') { Reject 400 }
            $key = $Matches[1]; if ($h.ContainsKey($key)) { Reject 400 }; $h[$key] = $Matches[2].Trim(' ',"`t")
        }
        if ($h['Host'] -cne $authority -or !$h['Origin'] -or !$origins.Contains($h['Origin'])) { Reject 403 }
        $cors['Access-Control-Allow-Origin'] = $h['Origin']
        if ($h.ContainsKey('Transfer-Encoding') -or $h.ContainsKey('Content-Encoding') -or $h.ContainsKey('Expect')) { Reject 400 }
        $length = 0L
        if ($h.ContainsKey('Content-Length')) {
            if ($h['Content-Length'] -notmatch '\A[0-9]+\z') { Reject 400 }
            if (![long]::TryParse($h['Content-Length'],[ref]$length) -or $length -gt $limit) { Reject 413 }
        }
        if ($route -ceq '/status') { $expected = 'GET' } elseif ($route -ceq '/jobs') { $expected = 'POST' } else { Reject 404 }
        if ($method -ceq 'OPTIONS') {
            if ($length -or $h['Access-Control-Request-Method'] -cne $expected) { Reject 403 }
            $headers = @(([string]$h['Access-Control-Request-Headers']).Split(',') | ForEach-Object { $_.Trim().ToLowerInvariant() })
            if ('x-pdf-tools' -notin $headers) { Reject 403 }
            foreach ($header in $headers) { if ($header -ne 'x-pdf-tools' -and !($expected -eq 'POST' -and $header -eq 'content-type')) { Reject 403 } }
            if ($h.ContainsKey('Access-Control-Request-Private-Network')) {
                if ($h['Access-Control-Request-Private-Network'] -cne 'true') { Reject 403 }
                $cors['Access-Control-Allow-Private-Network'] = 'true'
            }
            $cors['Access-Control-Allow-Headers'] = $headers -join ', '; $cors['Access-Control-Allow-Methods'] = $expected
            Reply 204 ''; return
        }
        if ($method -cne $expected) { Reject 405 }
        if ($h['X-Pdf-Tools'] -cne 'versaworks') { Reject 403 }
        if ($method -ceq 'GET') {
            if ($length) { Reject 400 }
            if (Test-Queue) { Reply 200 '{"available":true}' } else { Reply 200 '{"available":false}' }; return
        }
        if ($h['Content-Type'] -ine 'application/pdf') { Reject 415 }
        if (!$h.ContainsKey('Content-Length')) { Reject 411 }; if (!$length) { Reject 422 }
        $name = Publish $length; Reply 201 ('{"filename":"' + $name + '"}')
    } catch {
        $code = 503
        for ($e = $_.Exception; $null -ne $e; $e = $e.InnerException) {
            if ($e.Data.Contains('status')) { $code = $e.Data['status']; break }
            if ($e -is [Net.Sockets.SocketException] -and $e.SocketErrorCode -eq 'TimedOut') { $code = 408 }
        }
        try { Reply $code '{"error":"request failed"}' } catch { }
    } finally { $reader.Dispose() }
}
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,43127)
$listener.ExclusiveAddressUse = $true
try {
    $listener.Start(8); Write-Host "Listening on http://$authority (Ctrl+C to stop)"
    while ($true) {
        if (!$listener.Pending()) { Start-Sleep -Milliseconds 100; continue }
        $client = $listener.AcceptTcpClient()
        try { Serve $client } finally { $client.Dispose() }
    }
} finally { $listener.Stop() }
