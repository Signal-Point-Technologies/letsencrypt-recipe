# letsencrypt-recipe - https://github.com/Signal-Point-Technologies/letsencrypt-recipe
# Author : Andrew Cohen, Signal Point Technologies
# License: MIT
<#
=====================================================================
 PART 5 - Import an ACME-issued cert into the Windows certificate store
=====================================================================
 RUN AS   : Administrator, ELEVATED (LocalMachine store needs it).
            CurrentUser store works unelevated.
 SHELL    : pwsh 7 preferred. Works in Windows PowerShell 5.1 except
            for -PemFolder mode (needs .NET 5+ PEM loader).
 RUN      : After every issuance/renewal, or call it from a deploy hook.

 WHAT IT DOES
   Takes the PFX Posh-ACME wrote under
   $env:LOCALAPPDATA\Posh-ACME\<server>\<account>\<fqdn>\ and imports it
   into LocalMachine\My with the private key persisted, then (optional)
   drops the intermediates in CA and the root in Root, grants a service
   account read access to the private key, and deletes the superseded
   older certs for the same subject.

 THREE WAYS TO POINT IT AT A CERT
   -MainDomain  web01.example.com   # asks Posh-ACME for the paths (best)
   -PfxFile     C:\path\fullchain.pfx   # explicit file
   -PemFolder   C:\path\               # folder holding cert.cer + cert.key

 EXAMPLES
   # Normal case - everything resolved from Posh-ACME state:
   PS C:\> .\05-Import-CertToStore.ps1 -MainDomain web01.example.com -InstallChain

   # Same, and let the app pool / service read the key, and clean up the old cert:
   PS C:\> .\05-Import-CertToStore.ps1 -MainDomain web01.example.com `
             -InstallChain -GrantAccessTo 'CONTOSO\svc-app' -RemoveSuperseded

   # Explicit PFX with a non-default password:
   PS C:\> .\05-Import-CertToStore.ps1 -PfxFile D:\certs\fullchain.pfx -PfxPass 'poshacme'

   # Preview only:
   PS C:\> .\05-Import-CertToStore.ps1 -MainDomain web01.example.com -WhatIf

 NOTES
   * -MainDomain mode must run as the SAME account that owns the
     Posh-ACME state (the service account from script 02) - the cert
     store it writes to is machine-wide, but the *source* files are not.
   * Posh-ACME's default PFX password is 'poshacme'. Get-PACertificate
     reports the real one; this script reads it automatically.
   * Prints the thumbprint at the end - that is what IIS / Exchange /
     RDP / a FortiGate import step wants next.
=====================================================================
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Domain')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Domain')]
    [string]$MainDomain,

    [Parameter(Mandatory, ParameterSetName = 'Pfx')]
    [string]$PfxFile,

    [Parameter(Mandatory, ParameterSetName = 'Pem')]
    [string]$PemFolder,

    # Only used with -PfxFile / -PemFolder. Domain mode reads the real one.
    [string]$PfxPass = 'poshacme',

    [ValidateSet('LocalMachine', 'CurrentUser')]
    [string]$StoreLocation = 'LocalMachine',

    [string]$StoreName = 'My',

    # Also place intermediates in CA and self-signed roots in Root.
    [switch]$InstallChain,

    # Mark the private key exportable (needed if you must re-export later).
    [switch]$Exportable,

    # Give this account read access to the private key file (LocalMachine only).
    [string]$GrantAccessTo,

    # Delete other certs in the same store with the same subject that expire
    # earlier than the one just imported.
    [switch]$RemoveSuperseded
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$m) Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "[!] $m" -ForegroundColor Yellow }

if ($StoreLocation -eq 'LocalMachine') {
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw 'LocalMachine store requires an ELEVATED session.' }
}

# ---------------------------------------------------------------------
# 1. Resolve the source material
# ---------------------------------------------------------------------
$leafFromPem = $null

switch ($PSCmdlet.ParameterSetName) {

    'Domain' {
        Write-Step "Asking Posh-ACME for the cert files for $MainDomain"
        Import-Module Posh-ACME -ErrorAction Stop
        $pa = Get-PACertificate -MainDomain $MainDomain -ErrorAction Stop
        if (-not $pa) { throw "No Posh-ACME certificate found for '$MainDomain' in this profile ($env:USERNAME). Wrong account?" }

        # Prefer the full-chain PFX so intermediates come along.
        $PfxFile = if ($pa.PfxFullChain -and (Test-Path $pa.PfxFullChain)) { $pa.PfxFullChain } else { $pa.PfxFile }
        if (-not $PfxFile -or -not (Test-Path $PfxFile)) { throw "Posh-ACME reported no readable PFX for '$MainDomain'." }

        if ($pa.PfxPass) {
            $PfxPass = if ($pa.PfxPass -is [securestring]) {
                [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pa.PfxPass))
            } else { [string]$pa.PfxPass }
        }
        Write-Ok "Source: $PfxFile  (expires $($pa.NotAfter))"
    }

    'Pfx' {
        if (-not (Test-Path $PfxFile)) { throw "PFX not found: $PfxFile" }
        Write-Ok "Source: $PfxFile"
    }

    'Pem' {
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            throw '-PemFolder mode needs pwsh 7 (.NET PEM loader). Use -PfxFile in Windows PowerShell 5.1.'
        }
        $cer = Join-Path $PemFolder 'fullchain.cer'
        if (-not (Test-Path $cer)) { $cer = Join-Path $PemFolder 'cert.cer' }
        $key = Join-Path $PemFolder 'cert.key'
        if (-not (Test-Path $cer)) { throw "No cert.cer / fullchain.cer in $PemFolder" }
        if (-not (Test-Path $key)) { throw "No cert.key in $PemFolder" }

        Write-Step "Building an in-memory PFX from $cer + cert.key"
        # CreateFromPemFile reads the FIRST cert in the file and pairs the key to it.
        $leafFromPem = [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile($cer, $key)
        # Round-trip through PFX bytes so the key lands in a Windows key container.
        $PfxPass  = [guid]::NewGuid().ToString('N')
        $pfxBytes = $leafFromPem.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $PfxPass)
        $PfxFile  = Join-Path ([IO.Path]::GetTempPath()) ("acme-import-{0}.pfx" -f [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllBytes($PfxFile, $pfxBytes)
        Write-Ok "Temp PFX: $PfxFile (deleted at the end)"
    }
}

# ---------------------------------------------------------------------
# 2. Load the PFX
# ---------------------------------------------------------------------
$flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet
$flags = $flags -bor $(if ($StoreLocation -eq 'LocalMachine') {
    [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet
} else {
    [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet
})
if ($Exportable) {
    $flags = $flags -bor [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
}

# .NET resolves relative paths against the process CWD, not the PS location
$PfxFile = (Resolve-Path -LiteralPath $PfxFile).ProviderPath

$collection = [Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
$collection.Import($PfxFile, $PfxPass, $flags)

$leaf = $collection | Where-Object HasPrivateKey | Select-Object -First 1
if (-not $leaf) { throw "No private key in $PfxFile - wrong password, or this is a public-cert-only file." }

$roots         = @($collection | Where-Object { -not $_.HasPrivateKey -and $_.Subject -eq $_.Issuer })
$intermediates = @($collection | Where-Object { -not $_.HasPrivateKey -and $_.Subject -ne $_.Issuer })

Write-Host ''
Write-Host "  Subject    : $($leaf.Subject)"
Write-Host "  Issuer     : $($leaf.Issuer)"
Write-Host "  Thumbprint : $($leaf.Thumbprint)"
Write-Host "  Valid      : $($leaf.NotBefore) -> $($leaf.NotAfter)"
Write-Host "  Chain      : $($intermediates.Count) intermediate(s), $($roots.Count) root(s)"
Write-Host ''

# Guard: Get-PACertificate serves whatever Set-PAServer context is active,
# so a staging cert can arrive here by accident. Staging certs are untrusted
# by design and must never be deployed.
if ($leaf.Issuer -match 'STAGING') {
    Write-Warn "This cert was issued by Let's Encrypt STAGING - clients will NOT trust it."
    Write-Warn "If you expected a production cert: Set-PAServer LE_PROD, re-issue, re-run."
    if (-not $WhatIfPreference) {
        $go = Read-Host 'Import the STAGING cert anyway? (y/n)'
        if ($go -ne 'y') { throw 'Aborted: staging-issued certificate.' }
    }
}

# ---------------------------------------------------------------------
# 3. Import
# ---------------------------------------------------------------------
function Add-ToStore {
    param(
        [Security.Cryptography.X509Certificates.X509Certificate2[]]$Certs,
        [string]$Name
    )
    if (-not $Certs -or $Certs.Count -eq 0) { return }
    $store = [Security.Cryptography.X509Certificates.X509Store]::new($Name, $StoreLocation)
    $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try {
        foreach ($c in $Certs) {
            $label = ($c.Subject -split ',')[0]
            if ($store.Certificates | Where-Object Thumbprint -eq $c.Thumbprint) {
                Write-Warn "Already in $StoreLocation\$Name : $label"
                continue
            }
            if ($PSCmdlet.ShouldProcess("$StoreLocation\$Name", "Add $label ($($c.Thumbprint))")) {
                $store.Add($c)
                Write-Ok "Added to $StoreLocation\$Name : $label"
            }
        }
    } finally { $store.Close() }
}

Add-ToStore -Certs @($leaf) -Name $StoreName

if ($InstallChain) {
    Add-ToStore -Certs $intermediates -Name 'CA'
    Add-ToStore -Certs $roots         -Name 'Root'
} elseif ($intermediates.Count -gt 0) {
    Write-Warn "$($intermediates.Count) intermediate(s) in the PFX were NOT installed. Re-run with -InstallChain if clients report an incomplete chain."
}

# ---------------------------------------------------------------------
# 4. Private key ACL (LocalMachine only)
# ---------------------------------------------------------------------
if ($GrantAccessTo) {
    if ($StoreLocation -ne 'LocalMachine') {
        Write-Warn '-GrantAccessTo only applies to LocalMachine. Skipped.'
    }
    elseif ($PSCmdlet.ShouldProcess($GrantAccessTo, 'Grant read on the private key')) {
        # Re-read from the store: that object owns the persisted key.
        $stored = Get-Item "Cert:\$StoreLocation\$StoreName\$($leaf.Thumbprint)"
        $rsa    = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($stored)
        $ecdsa  = if (-not $rsa) { [Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPrivateKey($stored) }

        $unique = $null
        foreach ($k in @($rsa, $ecdsa)) {
            if ($k -and $k.Key -and $k.Key.UniqueName) { $unique = $k.Key.UniqueName; break }   # CNG
            if ($k -and $k.CspKeyContainerInfo)        { $unique = $k.CspKeyContainerInfo.UniqueKeyContainerName; break }  # legacy CSP
        }
        if (-not $unique) { throw "Could not locate the private key file for $($leaf.Thumbprint)." }

        $keyPath = @(
            "$env:ProgramData\Microsoft\Crypto\RSA\MachineKeys\$unique",
            "$env:ProgramData\Microsoft\Crypto\Keys\$unique",
            $unique
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $keyPath) { throw "Private key file '$unique' not found on disk." }

        $acl  = Get-Acl $keyPath
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($GrantAccessTo, 'Read', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -Path $keyPath -AclObject $acl
        Write-Ok "Granted Read on the private key to $GrantAccessTo"
    }
}

# ---------------------------------------------------------------------
# 5. Remove superseded certs for the same subject
# ---------------------------------------------------------------------
if ($RemoveSuperseded) {
    Write-Step 'Looking for older certs with the same subject'
    $old = Get-ChildItem "Cert:\$StoreLocation\$StoreName" |
        Where-Object { $_.Subject -eq $leaf.Subject -and
                       $_.Thumbprint -ne $leaf.Thumbprint -and
                       $_.NotAfter -lt $leaf.NotAfter }
    if (-not $old) { Write-Ok 'None found.' }
    foreach ($c in $old) {
        # NEVER -DeleteKey here: Posh-ACME reuses the SAME private key across
        # renewals, so the superseded cert and the new cert share one key
        # container - deleting the old cert's key kills the live cert too
        # ("Keyset does not exist"; this happened in production). Removing
        # only the cert entry leaves the shared key container intact.
        if ($PSCmdlet.ShouldProcess("$($c.Thumbprint) (expires $($c.NotAfter))", 'REMOVE from store (cert only, key kept)')) {
            Remove-Item $c.PSPath -Force
            Write-Ok "Removed cert $($c.Thumbprint) (key container left intact)"
        }
    }
}

# ---------------------------------------------------------------------
# 6. Verify + report
# ---------------------------------------------------------------------
if ($PemFolder -and (Test-Path $PfxFile) -and $PfxFile -like "*acme-import-*") {
    Remove-Item $PfxFile -Force
}
if ($leafFromPem) { $leafFromPem.Dispose() }

$final = Get-Item "Cert:\$StoreLocation\$StoreName\$($leaf.Thumbprint)" -ErrorAction SilentlyContinue
if (-not $final) {
    if ($WhatIfPreference) { Write-Warn '-WhatIf: nothing was written.'; return }
    throw "Import reported success but $($leaf.Thumbprint) is not in $StoreLocation\$StoreName."
}

$chainOk = ([Security.Cryptography.X509Certificates.X509Chain]::new()).Build($final)
if ($chainOk) { Write-Ok 'Chain validates against this machine''s trust store.' }
else          { Write-Warn 'Chain does NOT validate here. Re-run with -InstallChain, or the issuing root is missing.' }

Write-Host ''
Write-Ok "Done. Thumbprint: $($final.Thumbprint)"
Write-Host "  Private key present : $($final.HasPrivateKey)"
Write-Host "  Store path          : Cert:\$StoreLocation\$StoreName\$($final.Thumbprint)"
Write-Host ''
Write-Host 'Bind it, e.g.:' -ForegroundColor DarkGray
Write-Host "  netsh http add sslcert ipport=0.0.0.0:443 certhash=$($final.Thumbprint) appid='{00000000-0000-0000-0000-000000000000}'" -ForegroundColor DarkGray
Write-Host "  New-IISSiteBinding -Name 'Default Web Site' -BindingInformation '*:443:' -Protocol https -CertificateThumbPrint $($final.Thumbprint) -CertStoreLocation 'Cert:\LocalMachine\My'" -ForegroundColor DarkGray

$final
