param(
  [string]$OutputDirectory = '',
  [string]$PackagePath = '',
  [string]$EvidencePath = ''
)

$ErrorActionPreference = 'Stop'
$nativeRoot = Split-Path -Parent $PSScriptRoot
$ownsOutput = [string]::IsNullOrWhiteSpace($OutputDirectory)
if ($ownsOutput) {
  $OutputDirectory = Join-Path ([IO.Path]::GetTempPath()) "lumen-native-windows-smoke-$([Guid]::NewGuid().ToString('N'))"
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
$certificatePath = Join-Path $output 'smoke-signing.pfx'
$publicCertificatePath = Join-Path $output 'smoke-signing.cer'
$passwordText = [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')
$password = ConvertTo-SecureString -String $passwordText -AsPlainText -Force
$packageName = 'com.lumen.editor.native-preview.windows'
$certificate = $null
$installedPackage = $null
$process = $null
$windowHandle = [IntPtr]::Zero
$windowTitle = ''
$evidence = [ordered]@{
  schemaVersion = 1
  probe = 'native-windows-installed-window'
  status = 'started'
  platform = 'Windows'
  osVersion = [Environment]::OSVersion.VersionString
  recordedAt = [DateTimeOffset]::UtcNow.ToString('o')
}

if (-not ('LumenWindowProbe' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class LumenWindowProbe
{
    private delegate bool EnumWindowsProc(IntPtr window, IntPtr state);

    [StructLayout(LayoutKind.Sequential)]
    public struct Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr state);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll")]
    public static extern bool IsWindowEnabled(IntPtr window);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr window, out Rect rect);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr window, StringBuilder text, int maximum);

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessageTimeout(
        IntPtr window, uint message, IntPtr wParam, IntPtr lParam,
        uint flags, uint timeoutMilliseconds, out IntPtr result);

    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    public static IntPtr FindVisibleWindow(int processId)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows((window, state) =>
        {
            GetWindowThreadProcessId(window, out uint ownerProcessId);
            if (ownerProcessId == (uint)processId && IsWindowVisible(window))
            {
                found = window;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static string GetTitle(IntPtr window)
    {
        var title = new StringBuilder(1024);
        GetWindowText(window, title, title.Capacity);
        return title.ToString();
    }

    public static bool IsResponsive(IntPtr window, uint timeoutMilliseconds)
    {
        const uint WM_NULL = 0x0000;
        const uint SMTO_ABORTIFHUNG = 0x0002;
        return SendMessageTimeout(
            window, WM_NULL, IntPtr.Zero, IntPtr.Zero, SMTO_ABORTIFHUNG,
            timeoutMilliseconds, out _) != IntPtr.Zero;
    }

    public static bool RequestClose(IntPtr window)
    {
        const uint WM_CLOSE = 0x0010;
        return PostMessage(window, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
    }
}
'@
}
Add-Type -AssemblyName UIAutomationClient

function Write-SmokeEvidence {
  param([System.Collections.IDictionary]$Payload)
  $json = $Payload | ConvertTo-Json -Depth 8
  Write-Output ($Payload | ConvertTo-Json -Depth 8 -Compress)
  if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
    $resolvedEvidence = [IO.Path]::GetFullPath($EvidencePath)
    $parent = [IO.Path]::GetDirectoryName($resolvedEvidence)
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    [IO.File]::WriteAllText($resolvedEvidence, "$json`n", [Text.UTF8Encoding]::new($false))
  }
}

New-Item -ItemType Directory -Force -Path $output | Out-Null
try {
  $preexistingPackage = Get-AppxPackage -Name $packageName | Select-Object -First 1
  if ($preexistingPackage) {
    throw "Refusing to replace an existing native preview package: $($preexistingPackage.PackageFullName)"
  }
  if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    $certificate = New-SelfSignedCertificate `
      -Type Custom `
      -Subject 'CN=LumenEditorNativeWindowsCISmoke' `
      -KeyUsage DigitalSignature `
      -KeyExportPolicy Exportable `
      -FriendlyName 'Lumen Editor Native Windows CI Smoke' `
      -CertStoreLocation 'Cert:\CurrentUser\My' `
      -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3') `
      -NotAfter (Get-Date).AddDays(2)
    Export-PfxCertificate -Cert $certificate -FilePath $certificatePath -Password $password | Out-Null
    Export-Certificate -Cert $certificate -FilePath $publicCertificatePath | Out-Null
    Import-Certificate -FilePath $publicCertificatePath -CertStoreLocation 'Cert:\CurrentUser\TrustedPeople' | Out-Null

    & (Join-Path $PSScriptRoot 'package-msix.ps1') `
      -Architecture x64 `
      -OutputDirectory $output `
      -CertificateSource $certificatePath `
      -CertificatePassword $passwordText

    $PackagePath = Get-ChildItem -LiteralPath $output -File -Filter '*-native-windows-x64.msix' |
      Select-Object -First 1 -ExpandProperty FullName
  } else {
    $PackagePath = [IO.Path]::GetFullPath($PackagePath)
  }
  if (-not $PackagePath -or -not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
    throw 'The signed x64 smoke MSIX was not found.'
  }
  $evidence['packageSha256'] = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash.ToLowerInvariant()

  Add-AppxPackage -Path $PackagePath
  $installedPackage = Get-AppxPackage -Name $packageName | Select-Object -First 1
  if (-not $installedPackage) { throw 'The native Windows smoke MSIX was not installed.' }

  [xml]$manifest = Get-Content -LiteralPath (Join-Path $installedPackage.InstallLocation 'AppxManifest.xml') -Raw
  $applicationId = [string]$manifest.Package.Applications.Application.Id
  $aumid = "$($installedPackage.PackageFamilyName)!$applicationId"
  $evidence['packageFullName'] = $installedPackage.PackageFullName
  $evidence['aumid'] = $aumid
  $existingProcessIds = @(Get-Process -Name 'LumenEditor.Windows.App' -ErrorAction SilentlyContinue | ForEach-Object Id)
  Start-Process explorer.exe -ArgumentList "shell:AppsFolder\$aumid"

  $processDeadline = (Get-Date).AddSeconds(30)
  do {
    Start-Sleep -Milliseconds 250
    $process = Get-Process -Name 'LumenEditor.Windows.App' -ErrorAction SilentlyContinue |
      Where-Object { $existingProcessIds -notcontains $_.Id } | Select-Object -First 1
  } while (-not $process -and (Get-Date) -lt $processDeadline)
  if (-not $process) { throw "The installed native Windows app did not launch for AUMID $aumid." }

  $windowDeadline = (Get-Date).AddSeconds(30)
  do {
    Start-Sleep -Milliseconds 250
    if (-not (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) {
      throw 'The installed native Windows app exited before creating a window.'
    }
    $windowHandle = [LumenWindowProbe]::FindVisibleWindow($process.Id)
  } while ($windowHandle -eq [IntPtr]::Zero -and (Get-Date) -lt $windowDeadline)
  if ($windowHandle -eq [IntPtr]::Zero) {
    throw 'The installed native Windows app did not create a visible top-level window.'
  }

  $rect = [LumenWindowProbe+Rect]::new()
  if (-not [LumenWindowProbe]::GetWindowRect($windowHandle, [ref]$rect)) {
    throw 'Could not read the native Windows app window bounds.'
  }
  $width = $rect.Right - $rect.Left
  $height = $rect.Bottom - $rect.Top
  if ($width -le 0 -or $height -le 0 -or -not [LumenWindowProbe]::IsWindowEnabled($windowHandle)) {
    throw 'The native Windows app window was not usable.'
  }

  $automation = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
  if (-not $automation) { throw 'UI Automation could not resolve the native Windows app window.' }
  $automationState = $automation.Current
  if ($automationState.IsOffscreen -or -not $automationState.IsEnabled `
      -or $automationState.ControlType.ProgrammaticName -ne 'ControlType.Window') {
    throw 'The native Windows app did not expose an enabled on-screen Window to UI Automation.'
  }
  $rootCondition = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'LumenEditorRoot')
  $contentRoot = $automation.FindFirst(
    [System.Windows.Automation.TreeScope]::Descendants, $rootCondition)
  if (-not $contentRoot -or -not $contentRoot.Current.IsEnabled `
      -or $contentRoot.Current.IsOffscreen) {
    throw 'UI Automation could not find the enabled, on-screen Lumen editor workspace.'
  }
  $contentAutomationId = $contentRoot.Current.AutomationId
  $contentIsOffscreen = $contentRoot.Current.IsOffscreen

  $heartbeats = 0
  for ($index = 0; $index -lt 3; $index++) {
    if (-not [LumenWindowProbe]::IsResponsive($windowHandle, 2000)) {
      throw 'The native Windows app window stopped responding to the message loop.'
    }
    $heartbeats++
    Start-Sleep -Milliseconds 250
  }
  $windowTitle = [LumenWindowProbe]::GetTitle($windowHandle)

  if (-not [LumenWindowProbe]::RequestClose($windowHandle)) {
    throw 'Could not request a normal close of the native Windows app window.'
  }
  if (-not $process.WaitForExit(15000)) {
    throw 'The native Windows app did not exit after its top-level window received WM_CLOSE.'
  }

  $evidence['status'] = 'passed'
  $evidence['processId'] = $process.Id
  $evidence['window'] = [ordered]@{
    handle = ('0x{0:X}' -f $windowHandle.ToInt64())
    title = $windowTitle
    visible = $true
    enabled = $true
    width = $width
    height = $height
    automationControlType = $automationState.ControlType.ProgrammaticName
    automationIsOffscreen = $automationState.IsOffscreen
    automationIsEnabled = $automationState.IsEnabled
    contentAutomationId = $contentAutomationId
    contentIsOffscreen = $contentIsOffscreen
    messageLoopHeartbeats = $heartbeats
  }
  $evidence['gracefulExit'] = $true
  $evidence['recordedAt'] = [DateTimeOffset]::UtcNow.ToString('o')
  Write-Host "Installed, opened a responsive UI window, and normally closed $aumid."
} catch {
  $evidence['status'] = 'failed'
  $evidence['failure'] = $_.Exception.Message
  $evidence['recordedAt'] = [DateTimeOffset]::UtcNow.ToString('o')
  throw
} finally {
  Write-SmokeEvidence -Payload $evidence
  if ($process -and -not $process.HasExited) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
  }
  if ($installedPackage) {
    Remove-AppxPackage -Package $installedPackage.PackageFullName -ErrorAction SilentlyContinue
  }
  if ($certificate) {
    Get-ChildItem 'Cert:\CurrentUser\TrustedPeople' | Where-Object Thumbprint -eq $certificate.Thumbprint |
      Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($certificate.Thumbprint)" -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $certificatePath, $publicCertificatePath -Force -ErrorAction SilentlyContinue
  }
  if ($ownsOutput -and (Test-Path -LiteralPath $output)) {
    Remove-Item -LiteralPath $output -Recurse -Force
  }
}
