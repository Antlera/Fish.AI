#requires -Version 5.1
<#
  gen-keypair.ps1 - Generate the RSA key pair for Snowflake key-pair authentication.

  Uses Python's cryptography library, so it does not depend on openssl being
  present on Windows. The private key stays on this machine; only the public key
  goes to Snowflake.
#>

param(
    [string]$OutDir = (Join-Path $env:USERPROFILE '.snowflake\keys'),
    [switch]$Encrypted   # Encrypt the private key. Safer, but the MCP server will
                         # then need the passphrase at startup, which is awkward.
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$priv = Join-Path $OutDir 'snowflake_audit.p8'
$pub  = Join-Path $OutDir 'snowflake_audit.pub'

if (Test-Path $priv) {
    Write-Host "$priv already exists" -ForegroundColor Yellow
    $ans = Read-Host "Overwriting invalidates the public key already registered in Snowflake. Continue? (yes/no)"
    if ($ans -ne 'yes') { exit 0 }
}

& python -c "import cryptography" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Installing cryptography..." -ForegroundColor Cyan
    & python -m pip install -U cryptography
}

$py = @'
import sys
from cryptography.hazmat.primitives import serialization as s
from cryptography.hazmat.primitives.asymmetric import rsa

priv_path, pub_path, passphrase = sys.argv[1], sys.argv[2], sys.argv[3]

key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

enc = (s.BestAvailableEncryption(passphrase.encode())
       if passphrase else s.NoEncryption())

with open(priv_path, "wb") as f:
    f.write(key.private_bytes(s.Encoding.PEM,
                              s.PrivateFormat.PKCS8,
                              enc))

pub_pem = key.public_key().public_bytes(s.Encoding.PEM,
                                        s.PublicFormat.SubjectPublicKeyInfo)
with open(pub_path, "wb") as f:
    f.write(pub_pem)

# Snowflake wants the bare base64 body, without header/footer or newlines.
body = "".join(l for l in pub_pem.decode().splitlines()
               if not l.startswith("-----"))
print(body)
'@

$tmp = Join-Path $env:TEMP 'genkey.py'
$py | Set-Content $tmp -Encoding UTF8

$pass = ''
if ($Encrypted) {
    $sec = Read-Host "private key passphrase" -AsSecureString
    $pass = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
              [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}

$pubBody = & python $tmp $priv $pub $pass
Remove-Item $tmp -Force
if ($LASTEXITCODE -ne 0) { throw "key generation failed" }

# Tighten the private key ACL: current user only.
$acl = Get-Acl $priv
$acl.SetAccessRuleProtection($true, $false)
$acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    $env:USERNAME, 'FullControl', 'Allow')))
Set-Acl $priv $acl

Write-Host "`nprivate key: $priv  (ACL tightened - do not copy this off the machine)" -ForegroundColor Green
Write-Host "public key : $pub`n" -ForegroundColor Green

Write-Host "Run this in Snowflake:" -ForegroundColor Cyan
Write-Host ""
Write-Host "ALTER USER SVC_AUDIT_AGENT SET RSA_PUBLIC_KEY = '$pubBody';" -ForegroundColor White
Write-Host ""

Write-Host "Then confirm ~\.snowflake\connections.toml contains:" -ForegroundColor Cyan
Write-Host "  private_key_file = `"$($priv.Replace('\','/'))`"" -ForegroundColor DarkGray

Set-Clipboard -Value "ALTER USER SVC_AUDIT_AGENT SET RSA_PUBLIC_KEY = '$pubBody';"
Write-Host "`n(copied to clipboard)" -ForegroundColor DarkGray
