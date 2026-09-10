param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('x64', 'arm64')]
  [string]$Architecture,
  [string]$OutputDirectory = '',
  [string]$CertificateSource = '',
  [string]$CertificatePassword = ''
)

$ErrorActionPreference = 'Stop'
$nativeRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $nativeRoot
$project = Join-Path $nativeRoot 'src/LumenEditor.Windows.App/LumenEditor.Windows.App.csproj'
$workerProject = Join-Path $nativeRoot 'src/LumenEditor.Windows.Worker/LumenEditor.Windows.Worker.csproj'
$manifestSource = Join-Path $nativeRoot 'src/LumenEditor.Windows.App/Packaging/Package.appxmanifest'
$package = Get-Content -LiteralPath (Join-Path $repoRoot 'package.json') -Raw | ConvertFrom-Json
$version = [string]$package.version
if ($version -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') {
  throw "package.json contains an unsupported version: $version"
}
$msixVersion = "$version.0"
[xml]$manifest = Get-Content -LiteralPath $manifestSource -Raw
if ([string]$manifest.Package.Identity.Version -ne $msixVersion) {
  throw "MSIX manifest version $($manifest.Package.Identity.Version) does not match package.json version $msixVersion."
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $OutputDirectory = Join-Path $nativeRoot "artifacts/$Architecture"
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $output | Out-Null
$packageDir = Join-Path ([IO.Path]::GetTempPath()) "lumen-native-msix-$([Guid]::NewGuid().ToString('N'))"
$workerPublish = Join-Path ([IO.Path]::GetTempPath()) "lumen-native-worker-$Architecture-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $packageDir | Out-Null
$temporaryCertificate = $null
$temporaryManifest = $null

try {
  dotnet publish $workerProject --configuration Release --runtime "win-$Architecture" `
    --self-contained true -p:PublishSingleFile=true -p:CopyLocalLockFileAssemblies=true `
    -p:TreatWarningsAsErrors=true -o $workerPublish
  if ($LASTEXITCODE -ne 0) { throw "Worker publish failed for $Architecture." }
  $workerExecutable = Join-Path $workerPublish 'LumenEditor.Windows.Worker.exe'
  if (-not (Test-Path -LiteralPath $workerExecutable -PathType Leaf)) {
    throw "Worker executable is missing for $Architecture."
  }
  $signingArguments = @('-p:AppxPackageSigningEnabled=false')
  if (-not [string]::IsNullOrWhiteSpace($CertificateSource)) {
    if ([string]::IsNullOrWhiteSpace($CertificatePassword)) { throw 'A certificate password is required.' }
    $temporaryCertificate = Join-Path $packageDir 'signing.pfx'
    if ($CertificateSource.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
      Invoke-WebRequest -Uri $CertificateSource -OutFile $temporaryCertificate -UseBasicParsing
    } elseif ($CertificateSource.StartsWith('file://', [StringComparison]::OrdinalIgnoreCase)) {
      Copy-Item -LiteralPath ([Uri]$CertificateSource).LocalPath -Destination $temporaryCertificate
    } elseif (Test-Path -LiteralPath $CertificateSource -PathType Leaf) {
      Copy-Item -LiteralPath $CertificateSource -Destination $temporaryCertificate
    } else {
      [IO.File]::WriteAllBytes($temporaryCertificate, [Convert]::FromBase64String($CertificateSource))
    }
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($temporaryCertificate, $CertificatePassword)
    $temporaryManifest = Join-Path $packageDir 'Package.appxmanifest'
    [xml]$signedManifest = Get-Content -LiteralPath $manifestSource -Raw
    $signedManifest.Package.Identity.Publisher = $certificate.SubjectName.Name
    $signedManifest.Save($temporaryManifest)
    $env:PackageCertificatePassword = $CertificatePassword
    $signingArguments = @(
      '-p:AppxPackageSigningEnabled=true',
      '-p:AppxPackageSigningTimestampDigestAlgorithm=SHA256',
      '-p:AppxPackageSigningTimestampServerUrl=https://timestamp.digicert.com',
      "-p:PackageCertificateKeyFile=$temporaryCertificate",
      "-p:LumenPackageManifest=$temporaryManifest"
    )
  }

  $arguments = @(
    'publish', $project,
    '--configuration', 'Release',
    '--runtime', "win-$Architecture",
    '--self-contained', 'true',
    "-p:Platform=$Architecture",
    "-p:PlatformTarget=$Architecture",
    '-p:GenerateAppxPackageOnBuild=true',
    '-p:AppxBundle=Never',
    "-p:LumenWorkerPublishDir=$workerPublish",
    "-p:AppxPackageDir=$packageDir\"
  ) + $signingArguments
  & dotnet @arguments
  if ($LASTEXITCODE -ne 0) { throw "MSIX build failed for $Architecture." }

  $packages = @(Get-ChildItem -LiteralPath $packageDir -Recurse -File -Filter '*.msix')
  if ($packages.Count -ne 1) {
    throw "Expected exactly one MSIX for $Architecture, found $($packages.Count)."
  }
  $name = "text-editor-xujieyang-$version-native-windows-$Architecture.msix"
  $destination = Join-Path $output $name
  Copy-Item -LiteralPath $packages[0].FullName -Destination $destination -Force

  $verifyArguments = @{ PackagePath = $destination; Architecture = $Architecture }
  if ($temporaryCertificate) { $verifyArguments.RequireSignature = $true }
  & (Join-Path $PSScriptRoot 'verify-msix.ps1') @verifyArguments
  $hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
  "$hash  $name" | Set-Content -LiteralPath "$destination.sha256" -Encoding ascii
  Write-Host "Created $destination"
} finally {
  Remove-Item Env:PackageCertificatePassword -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $packageDir) {
    Remove-Item -LiteralPath $packageDir -Recurse -Force
  }
  if (Test-Path -LiteralPath $workerPublish) {
    Remove-Item -LiteralPath $workerPublish -Recurse -Force
  }
}
