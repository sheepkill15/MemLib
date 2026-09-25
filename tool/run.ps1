param(
  [ValidateSet('android', 'windows')][string]$Device = 'android'
)

$defines = @()
$envPath = Join-Path $PSScriptRoot '..\.env'
if (Test-Path -LiteralPath $envPath) {
  foreach ($line in Get-Content -LiteralPath $envPath) {
    if ($line -match '^\s*(NEXT_PUBLIC_SUPABASE_URL|NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY|GIPHY_ANDROID_KEY|GIPHY_WINDOWS_KEY)\s*=\s*(.*?)\s*$') {
      $value = $Matches[2].Trim('"', "'")
      $defines += "--dart-define=$($Matches[1])=$value"
    }
  }
}

& flutter run -d $Device @defines
exit $LASTEXITCODE
