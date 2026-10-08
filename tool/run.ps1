param(
  [ValidateSet('android', 'windows')][string]$Device = 'android'
)

$defines = @()
$envPath = Join-Path $PSScriptRoot '..\.env'
if (Test-Path -LiteralPath $envPath) {
  foreach ($line in Get-Content -LiteralPath $envPath) {
    if ($line -match '^\s*(NEXT_PUBLIC_SUPABASE_URL|NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY|KLIPY_ANDROID_KEY|KLIPY_WINDOWS_KEY|GIPHY_LIBRARY_SAVES_ENABLED)\s*=\s*(.*?)\s*$') {
      $value = $Matches[2].Trim('"', "'")
      $defines += "--dart-define=$($Matches[1])=$value"
    }
  }
}

& flutter run -d $Device @defines
exit $LASTEXITCODE
