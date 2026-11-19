# VersaWorks 7 local connector (Windows)

Run this on the **printer workstation**, in the same Windows session as the browser. In VersaWorks, configure the VG4-540's Input-A hot folder first. The only destination is `C:\ProgramData\Roland DG Versaworks7\Printers\VG4-540\Input-A`. The helper never creates it, changes permissions, or selects a fallback printer.

1. Use a normal user account with permission to create/delete staging files in `VG4-540` and move files into `Input-A`. VersaWorks must be able to read the published files (they retain their staging ACL on NTFS). Use a trusted local NTFS directory tree, not a junction, mount point, or share. Do not grant broad write permissions or run as Administrator to fix an ACL problem.
2. Open Windows PowerShell 5.1 or PowerShell 7 in this directory. Replace the example origin with the exact `location.origin` of your trusted PDF Tools page (scheme, host, and non-default port; no path or trailing slash):

   ```powershell
   .\Start-Connector.ps1 -AllowedOrigin 'https://pdf-tools.example.org'
   ```

   Multiple trusted origins can be passed as a PowerShell array. There is no default origin. No installation, URL reservation, firewall exception, or service is needed. If policy blocks scripts or `Add-Type`, use your organization's approved signing/launch process, not a machine-wide execution-policy change.
3. Leave the window open; Ctrl+C stops the helper. Only one instance can own the port. Always address it as `http://127.0.0.1:43127`, not `localhost`. Restart with the same command after logging in again.

## Browser contract

Both requests require an exactly allowlisted `Origin`, `Host: 127.0.0.1:43127`, and `X-Pdf-Tools: versaworks`. The browser supplies Origin and Host. Use `credentials: 'omit'`. Send a Blob/File body so the browser supplies Content-Length; not FormData, base64, a compressed body, or a chunked stream.

- `GET /status` -> `200 {"available":true}` or `false`. This only inspects directory metadata. It doesn't write a test file, launch VersaWorks, or prompt for a directory. True does not guarantee write access, printer readiness, or a running RIP.
- `POST /jobs`, `Content-Type: application/pdf` -> `201 {"filename":"pdf-tools-<unique id>.pdf"}` after publication, **not** confirmation of printing. Submit only on deliberate operator action. If a response is lost, check the queue before retrying to avoid duplicate jobs.
- `OPTIONS` handles route-specific CORS preflight, including `Access-Control-Request-Private-Network: true`. No wildcard origins or credential grants. Browser local-network permissions, secure-context rules, site CSP (`connect-src`), and enterprise policy still apply. The helper cannot suppress browser permission prompts; avoid background polling if a check might prompt. Origins and custom headers protect against other web pages, not against native software on the workstation.

## Limits and recovery

HTTP/1.1 only, one request at a time, 16 KiB headers, fixed-length PDFs up to 64 MiB, 5 s idle read/write timeout, 10 s header and 120 s total request-read budgets. Envelope validation requires a PDF 1.0-1.7 or 2.0 header and a final `%%EOF` line; this is not a PDF parser, malware scan, or guarantee of printability. Only submit trusted PDFs.

A job is streamed into an exclusively created `pdf-tools-<id>.part` directly in `VG4-540`, **outside** the watched `Input-A`. Only after validation, flush, and close does a same-volume Windows rename publish the complete file, without replacement or copy fallback. Normal failures clean up the helper's temporary file. After a hard kill, power loss, or cleanup denied by Windows, stop the helper and inspect leftover matching `.part` files in the parent before manually removing them. A `503` can indicate a missing queue, ACL failure, disk full, or sharing violation. Do not configure watchers on the staging parent or permit untrusted users to replace the queue directories.

## Verification without printing

With the helper running, from another PowerShell window in this directory (Python 3 optional):

```powershell
py -3 smoke.py 'https://pdf-tools.example.org'
```

This exercises status, origin/Host/header rejection, method and media restrictions, empty jobs, and CORS/private-network preflights without publishing a file. Without Python, use `curl.exe -i -H "Origin: https://pdf-tools.example.org" -H "X-Pdf-Tools: versaworks" http://127.0.0.1:43127/status`. A successful publication test requires a real configured Windows queue and may start a real print job.
