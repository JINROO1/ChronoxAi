import 'dart:io';

import 'package:chronoxai/data/runtime/local_runtime.dart';
import 'package:chronoxai/domain/plugins/seams.dart';
import 'package:chronoxai/domain/terminal/linux_paths.dart';
import 'package:chronoxai/platform/android_runtime_channel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _StaticRuntimeChannel extends AndroidRuntimeChannel {
  _StaticRuntimeChannel(this.platformFacts);

  final PlatformFacts platformFacts;

  @override
  Future<PlatformFacts> read() async => platformFacts;
}

class _RecordingRuntime extends LocalRuntime {
  _RecordingRuntime({required super.paths});

  String? receivedCommand;
  String? receivedWorkingDirectory;
  String? receivedWorkspaceDirectory;
  Duration? receivedTimeout;

  @override
  Future<ShellResult> run(
    String command, {
    String? workingDirectory,
    String? workspaceDirectory,
    Duration? timeout,
  }) async {
    receivedCommand = command;
    receivedWorkingDirectory = workingDirectory;
    receivedWorkspaceDirectory = workspaceDirectory;
    receivedTimeout = timeout;
    return const ShellResult(exitCode: 0, stdout: 'ok', stderr: '');
  }
}

void main() {
  late Directory tempDirectory;
  late Directory nativeLibraryDirectory;
  late LinuxPaths paths;
  late LocalRuntime runtime;

  setUp(() async {
    tempDirectory =
        await Directory.systemTemp.createTemp('chronox-runtime-workspace-');
    paths = LinuxPaths(filesDir: tempDirectory.path, distroId: 'test');
    await paths.ensure();

    nativeLibraryDirectory =
        Directory(p.join(tempDirectory.path, 'native-libraries'));
    await nativeLibraryDirectory.create(recursive: true);
    await File(p.join(nativeLibraryDirectory.path, 'libproot.so'))
        .writeAsBytes(const <int>[]);
    await File(p.join(nativeLibraryDirectory.path, 'libproot_loader.so'))
        .writeAsBytes(const <int>[]);

    runtime = LocalRuntime(
      paths: paths,
      channel: _StaticRuntimeChannel(
        PlatformFacts(
          isAndroid: false,
          sdkInt: 0,
          abi: 'x86_64',
          pageSize: 4096,
          nativeLibraryDir: nativeLibraryDirectory.path,
          filesDir: tempDirectory.path,
          cacheDir: tempDirectory.path,
          selinuxEnforcing: false,
          targetSdk: 0,
        ),
      ),
    );
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('monta la raíz del proyecto como /workspace en una terminal', () async {
    final projectDirectory = Directory(
      p.join(paths.workspaceDir, 'projects', 'demo'),
    );
    await projectDirectory.create(recursive: true);

    final command = await runtime.interactiveCommand(
      workingDirectory: LocalRuntime.guestWorkspace,
      workspaceDirectory: projectDirectory.path,
    );

    expect(
      command.args,
      contains('--bind=${projectDirectory.path}:/workspace'),
    );
    expect(command.args, contains('--cwd=/workspace'));
    expect(
      command.args,
      isNot(contains('--bind=${paths.workspaceDir}:/workspace')),
    );
  });

  test('sin proyecto conserva el montaje del workspace global', () async {
    final command = await runtime.interactiveCommand(
      workingDirectory: LocalRuntime.guestWorkspace,
    );

    expect(
      command.args,
      contains(
        '--bind=${p.normalize(p.absolute(paths.workspaceDir))}:/workspace',
      ),
    );
  });

  test('no permite montar fuera del workspace de la app', () async {
    await expectLater(
      runtime.interactiveCommand(
        workingDirectory: LocalRuntime.guestWorkspace,
        workspaceDirectory: Directory.systemTemp.path,
      ),
      throwsA(isA<RuntimeException>()),
    );
  });

  test('ProotShellSeam reenvía el workspace de proyecto al runtime', () async {
    final projectDirectory = Directory(
      p.join(paths.workspaceDir, 'projects', 'demo'),
    );
    await projectDirectory.create(recursive: true);
    final recordingRuntime = _RecordingRuntime(paths: paths);
    final shell = ProotShellSeam(
      recordingRuntime,
      defaultWorkingDirectory: LocalRuntime.guestWorkspace,
      workspaceDirectory: projectDirectory.path,
    );

    await shell.run('pwd');

    expect(recordingRuntime.receivedCommand, 'pwd');
    expect(recordingRuntime.receivedWorkingDirectory, '/workspace');
    expect(
      recordingRuntime.receivedWorkspaceDirectory,
      projectDirectory.path,
    );
    expect(recordingRuntime.receivedTimeout, isNull);
  });
}
