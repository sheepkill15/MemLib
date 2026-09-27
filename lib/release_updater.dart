import 'dart:convert';
import 'dart:io';

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
      '${Directory.systemTemp.path}${Platform.pathSeparator}memlib-update.ps1',
    );
    await script.writeAsString(r'''
param([string]$Archive, [string]$InstallDir, [int]$ParentPid, [string]$ExecutableName)
$ErrorActionPreference = 'Stop'
while (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue) { Start-Sleep -Milliseconds 400 }
$stage = Join-Path $env:TEMP ('memlib-update-' + [guid]::NewGuid().ToString('N'))
try {
  Expand-Archive -LiteralPath $Archive -DestinationPath $stage -Force
  if (-not (Test-Path -LiteralPath (Join-Path $stage $ExecutableName))) { throw 'Update archive is missing the application executable.' }
  Copy-Item -Path (Join-Path $stage '*') -Destination $InstallDir -Recurse -Force
  Start-Process -FilePath (Join-Path $InstallDir $ExecutableName)
} finally {
  Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $Archive -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
}
''');
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
    exit(0);
  }
}
