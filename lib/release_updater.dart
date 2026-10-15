import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class GithubRelease {
  const GithubRelease({
    required this.tag,
    required this.name,
    required this.notes,
    required this.version,
    required this.build,
    required this.assets,
  });

  final String tag;
  final String name;
  final String notes;
  final List<int> version;
  final int build;
  final Map<String, Uri> assets;

  String get versionLabel => '${version.join('.')}+$build';

  Uri asset(String name) =>
      assets[name] ??
      (throw FormatException('Release $tag does not contain $name'));
}

class ReleaseUpdater {
  static const _releaseUri =
      'https://api.github.com/repos/sheepkill15/MemLib/releases/latest';
  static const _userAgent = 'Memlib-Updater';
  static const _maxAssetBytes = 500 * 1024 * 1024;

  static Future<GithubRelease?> checkForUpdate() async {
    final client = http.Client();
    try {
      final response = await client
          .get(
            Uri.parse(_releaseUri),
            headers: {
              'Accept': 'application/vnd.github+json',
              'User-Agent': _userAgent,
            },
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('GitHub returned ${response.statusCode}');
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final release = _parseRelease(json);
      final requiredAsset = Platform.isWindows
          ? 'MemLib-Windows.zip'
          : 'MemLib-Android.apk';
      if (!release.assets.containsKey(requiredAsset)) {
        throw FormatException(
          'Release ${release.tag} is missing $requiredAsset',
        );
      }
      final package = await PackageInfo.fromPlatform();
      return _isNewer(release, package) ? release : null;
    } finally {
      client.close();
    }
  }

  static GithubRelease _parseRelease(Map<String, dynamic> json) {
    final tag = json['tag_name'] as String? ?? '';
    final match = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)\+(\d+)(?:\.(\d+))?$')
        .firstMatch(tag);
    if (match == null) throw FormatException('Unrecognized release tag: $tag');
    final assets = <String, Uri>{};
    for (final asset in json['assets'] as List<dynamic>? ?? const []) {
      final item = asset as Map<String, dynamic>;
      final name = item['name'] as String?;
      final url = Uri.tryParse(item['browser_download_url'] as String? ?? '');
      if (name != null &&
          url != null &&
          url.scheme == 'https' &&
          url.host == 'github.com') {
        assets[name] = url;
      }
    }
    return GithubRelease(
      tag: tag,
      name: json['name'] as String? ?? tag,
      notes: json['body'] as String? ?? '',
      version: [
        for (var index = 1; index <= 3; index++) int.parse(match[index]!),
      ],
      build: int.parse(match[4]!),
      assets: assets,
    );
  }

  static bool _isNewer(GithubRelease release, PackageInfo installed) {
    final installedVersion = installed.version
        .split('.')
        .map((part) => int.tryParse(part) ?? 0)
        .toList();
    while (installedVersion.length < 3) {
      installedVersion.add(0);
    }
    final installedBuild = int.tryParse(installed.buildNumber) ?? 0;
    final candidate = [...release.version, release.build];
    final current = [...installedVersion.take(3), installedBuild];
    for (var index = 0; index < candidate.length; index++) {
      if (candidate[index] != current[index]) {
        return candidate[index] > current[index];
      }
    }
    return false;
  }

  static Future<File> download(GithubRelease release, String assetName) async {
    final uri = release.asset(assetName);
    final client = http.Client();
    File? file;
    IOSink? output;
    var outputClosed = false;
    try {
      final request = http.Request('GET', uri)
        ..headers['User-Agent'] = _userAgent;
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('Asset download returned ${response.statusCode}');
      }
      if (response.contentLength != null &&
          response.contentLength! > _maxAssetBytes) {
        throw const HttpException('Release asset is larger than 500 MB');
      }

      final directory = await getTemporaryDirectory();
      file = File('${directory.path}${Platform.pathSeparator}$assetName');
      output = file.openWrite();
      var received = 0;
      await for (final chunk in response.stream) {
        received += chunk.length;
        if (received > _maxAssetBytes) {
          throw const HttpException('Release asset is larger than 500 MB');
        }
        output.add(chunk);
      }
      await output.flush();
      return file;
    } catch (_) {
      if (output != null) {
        await output.close();
        outputClosed = true;
      }
      if (file != null) await file.delete().catchError((_) => file!);
      rethrow;
    } finally {
      if (output != null && !outputClosed) await output.close();
      client.close();
    }
  }

  /// Starts a detached script that replaces the installation with [archive]
  /// once this process exits, then relaunches Memlib. The caller must close
  /// the app afterwards; the script stops it if it has not exited in time.
  static Future<void> installWindows(File archive) async {
    final executable = File(Platform.resolvedExecutable);
    final directory = executable.parent;
    final writeProbe = File(
      '${directory.path}${Platform.pathSeparator}.memlib-update-${pid.toString()}',
    );
    try {
      writeProbe.createSync();
      writeProbe.deleteSync();
    } on FileSystemException {
      throw FileSystemException(
        'The Memlib installation folder must be writable to update it',
        directory.path,
      );
    }
    final script = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}memlib-update-$pid.ps1',
    );
    await script.writeAsString(windowsUpdateScript);
    await Process.start('powershell.exe', [
      '-NoProfile',
      '-WindowStyle',
      'Hidden',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.path,
      archive.path,
      directory.path,
      pid.toString(),
      executable.uri.pathSegments.last,
    ], mode: ProcessStartMode.detached);
  }

  /// Waits for the app to exit (stopping it if it hangs or crashed while
  /// shutting down), copies the update over the installation, and always
  /// relaunches Memlib. Progress goes to %TEMP%\memlib-update.log and a
  /// failure is shown to the user instead of disappearing silently.
  @visibleForTesting
  static const windowsUpdateScript = r'''
param([string]$Archive, [string]$InstallDir, [int]$ParentPid, [string]$ExecutableName)
$ErrorActionPreference = 'Stop'
$log = Join-Path $env:TEMP 'memlib-update.log'
function Write-Log([string]$Message) {
  Add-Content -LiteralPath $log -Value ('{0:u} {1}' -f (Get-Date), $Message) -ErrorAction SilentlyContinue
}
$stage = Join-Path $env:TEMP ('memlib-update-' + [guid]::NewGuid().ToString('N'))
$failure = $null
try {
  Write-Log "Updating $InstallDir from $Archive"
  $deadline = (Get-Date).AddSeconds(20)
  while (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue) {
    if ((Get-Date) -gt $deadline) {
      Write-Log "Process $ParentPid did not exit; stopping it"
      Stop-Process -Id $ParentPid -Force -ErrorAction SilentlyContinue
      Start-Sleep -Seconds 1
      break
    }
    Start-Sleep -Milliseconds 300
  }
  Expand-Archive -LiteralPath $Archive -DestinationPath $stage -Force
  if (-not (Test-Path -LiteralPath (Join-Path $stage $ExecutableName))) { throw 'Update archive is missing the application executable.' }
  for ($attempt = 1; ; $attempt++) {
    try {
      Copy-Item -Path (Join-Path $stage '*') -Destination $InstallDir -Recurse -Force
      break
    } catch {
      if ($attempt -ge 10) { throw }
      Write-Log "Copy attempt $attempt failed: $($_.Exception.Message)"
      Start-Sleep -Seconds 1
    }
  }
  Write-Log 'Update installed'
} catch {
  $failure = $_.Exception.Message
  Write-Log "Update failed: $failure"
} finally {
  Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $Archive -Force -ErrorAction SilentlyContinue
}
if ($failure) {
  Add-Type -AssemblyName System.Windows.Forms
  [void][System.Windows.Forms.MessageBox]::Show("Memlib could not install the update:`n$failure`n`nDetails are in $log", 'Memlib update')
}
Start-Process -FilePath (Join-Path $InstallDir $ExecutableName)
Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
''';
}
