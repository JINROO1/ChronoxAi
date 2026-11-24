import 'package:chronoxai/domain/terminal/proot_command.dart';
import 'package:flutter_test/flutter_test.dart';

ProotConfig baseConfig({List<BindMount>? binds, Map<int, int>? ports}) {
  return ProotConfig(
    prootBinary: '/data/app/app.chronoxai/lib/arm64/libproot.so',
    prootLoader: '/data/data/app.chronoxai/files/linux/runtime/proot-loader',
    rootfs: '/data/data/app.chronoxai/files/linux/rootfs/debian-bookworm',
    workingDirectory: '/workspace',
    bindMounts: binds ?? const <BindMount>[],
    portRedirects: ports ?? const <int, int>{},
  );
}

void main() {
  group('ProotCommandBuilder.build', () {
    test('emite los flags de Termux en el orden canónico', () {
      final argv = ProotCommandBuilder.build(baseConfig());

      // El orden importa: proot procesa las opciones de izquierda a derecha.
      expect(
        argv.indexOf('--kill-on-exit'),
        lessThan(argv.indexOf('--link2symlink')),
      );
      expect(
        argv.indexOf('--link2symlink'),
        lessThan(argv.indexOf('--sysvipc')),
      );
      expect(argv, contains('--change-id=0:0'));
    });

    test('rootfs y cwd llevan el formato --opcion=valor', () {
      final argv = ProotCommandBuilder.build(baseConfig());

      expect(
        argv,
        contains(
          '--rootfs=/data/data/app.chronoxai/files/linux/rootfs/debian-bookworm',
        ),
      );
      expect(argv, contains('--cwd=/workspace'));
    });

    test('usa QEMU user-mode para que Android no ejecute el ELF invitado', () {
      const config = ProotConfig(
        prootBinary: '/native/libproot.so',
        prootLoader: '/files/loader',
        rootfs: '/files/rootfs',
        workingDirectory: '/workspace',
        qemuCommand: '/native/libqemu_guest.so',
      );

      final argv = ProotCommandBuilder.build(config);
      expect(
        argv,
        contains('--qemu=/native/libqemu_guest.so -L /files/rootfs'),
      );
    });

    test('siempre monta /dev, /proc y /sys', () {
      final argv = ProotCommandBuilder.build(baseConfig());

      expect(argv,
          containsAll(<String>['--bind=/dev', '--bind=/proc', '--bind=/sys']));
    });

    test('añade los montajes del usuario después de los base', () {
      final argv = ProotCommandBuilder.build(
        baseConfig(
          binds: const <BindMount>[
            BindMount(
                '/data/data/app.chronoxai/files/linux/workspace', '/workspace'),
          ],
        ),
      );

      final workspaceBind =
          argv.firstWhere((final a) => a.contains('/workspace:/workspace'));
      expect(workspaceBind, startsWith('--bind='));
      expect(
        argv.indexOf('--bind=/sys'),
        lessThan(argv.indexOf(workspaceBind)),
      );
    });

    test('soporta montajes de solo lectura', () {
      const mount =
          BindMount('/sdcard/Download', '/mnt/incoming', readOnly: true);
      expect(mount.specification, '/sdcard/Download:/mnt/incoming:ro');
    });

    test('el comando interior va al final y por defecto es un shell de login',
        () {
      final argv = ProotCommandBuilder.build(baseConfig());

      expect(argv.sublist(argv.length - 2), <String>['/bin/bash', '-l']);
    });

    test('acepta un comando interior explícito', () {
      final argv = ProotCommandBuilder.build(
        baseConfig(),
        inner: <String>['/usr/bin/apt', 'update'],
      );

      expect(argv.sublist(argv.length - 2), <String>['/usr/bin/apt', 'update']);
    });

    test('emite --kernel-release y -L cuando se configuran', () {
      final argv = ProotCommandBuilder.build(
        const ProotConfig(
          prootBinary: '/x/libproot.so',
          prootLoader: '/x/loader',
          rootfs: '/x/rootfs',
          workingDirectory: '/',
          fakeKernelRelease:
              r'\Linux\chronoxai\6.1.0-chronox\aarch64\localdomain\-1\',
        ),
      );

      expect(argv, contains('-L'));
      expect(
        argv.any((final a) => a.startsWith('--kernel-release=')),
        isTrue,
      );
    });

    test('no duplica el montaje de HOME si el llamador ya lo hace', () {
      final argv = ProotCommandBuilder.build(
        baseConfig(
          binds: const <BindMount>[
            BindMount('/data/data/app.chronoxai/files/linux/home', '/root'),
          ],
        ),
      );

      final rootBinds = argv.where((final a) => a.endsWith(':/root')).toList();
      expect(rootBinds, hasLength(1));
      expect(rootBinds.single,
          '--bind=/data/data/app.chronoxai/files/linux/home:/root');
    });

    test('puede desactivar las extensiones problemáticas', () {
      final argv = ProotCommandBuilder.build(
        const ProotConfig(
          prootBinary: '/x/libproot.so',
          prootLoader: '/x/loader',
          rootfs: '/x/rootfs',
          workingDirectory: '/',
          link2symlink: false,
          sysvipc: false,
          killOnExit: false,
        ),
      );

      expect(argv, isNot(contains('--link2symlink')));
      expect(argv, isNot(contains('--sysvipc')));
      expect(argv, isNot(contains('--kill-on-exit')));
    });

    test('traduce la redirección de puertos', () {
      final argv = ProotCommandBuilder.build(
        baseConfig(ports: const <int, int>{22: 2022, 80: 8080}),
      );

      final index = argv.indexOf('-p');
      expect(index, greaterThan(-1));
      expect(argv[index + 1], '22:2022,80:8080');
    });

    test('no emite -p cuando no hay redirecciones', () {
      expect(ProotCommandBuilder.build(baseConfig()), isNot(contains('-p')));
    });
  });

  group('ProotCommandBuilder.hostEnvironment', () {
    test('apunta LD_LIBRARY_PATH al directorio de librerías nativas', () {
      final env = ProotCommandBuilder.hostEnvironment(
        nativeLibraryDir: '/data/app/app.chronoxai/lib/arm64',
        tempDir: '/data/data/app.chronoxai/files/tmp',
        prootLoader:
            '/data/data/app.chronoxai/files/linux/runtime/proot-loader',
        qemuLibraryDir: '/data/data/app.chronoxai/files/linux/runtime/qemu-libs',
      );

      expect(
        env['LD_LIBRARY_PATH'],
        '/data/app/app.chronoxai/lib/arm64:/data/data/app.chronoxai/files/tmp:/data/data/app.chronoxai/files/linux/runtime/qemu-libs',
      );
      expect(env['PROOT_TMP_DIR'], '/data/data/app.chronoxai/files/tmp');
      expect(env['PROOT_NO_SECCOMP'], '1');
      expect(env['TERM'], 'xterm-256color');
    });
  });

  group('ProotCommandBuilder.guestEnvironment', () {
    test('define HOME y PATH dentro del contenedor', () {
      final env = ProotCommandBuilder.guestEnvironment(baseConfig());

      expect(env['HOME'], '/root');
      expect(env['PATH'], contains('/usr/bin'));
      expect(env['HOSTNAME'], 'chronoxai');
    });

    test('respeta las variables del usuario', () {
      const config = ProotConfig(
        prootBinary: '/x/libproot.so',
        prootLoader: '/x/loader',
        rootfs: '/x/rootfs',
        workingDirectory: '/',
        environment: <String, String>{'FOO': 'bar'},
      );

      expect(ProotCommandBuilder.guestEnvironment(config)['FOO'], 'bar');
    });
  });

  group('ProotCommandBuilder.kernelRelease', () {
    test('produce los seis campos separados por barra invertida', () {
      final value = ProotCommandBuilder.kernelRelease(
        hostname: 'chronoxai',
        release: '6.1.0-chronox',
        machine: 'aarch64',
      );

      // proot espera: \sysname\nodename\release\version\machine\domainname\
      expect(value, r'\Linux\chronoxai\6.1.0-chronox\aarch64\localdomain\-1\');
      expect(value.split(r'\').where((final s) => s.isNotEmpty).length, 6);
    });
  });

  group('ProotCommandBuilder.validate', () {
    test('acepta una configuración correcta', () {
      expect(ProotCommandBuilder.validate(baseConfig()), isEmpty);
    });

    test('detecta rutas no absolutas', () {
      final problems = ProotCommandBuilder.validate(
        const ProotConfig(
          prootBinary: '/x/libproot.so',
          prootLoader: '/x/loader',
          rootfs: 'rootfs-relativo',
          workingDirectory: 'workspace',
        ),
      );

      expect(problems, hasLength(2));
      expect(problems.first, contains('absoluta'));
    });

    test('detecta binario y loader vacíos', () {
      final problems = ProotCommandBuilder.validate(
        const ProotConfig(
          prootBinary: '',
          prootLoader: '  ',
          rootfs: '/rootfs',
          workingDirectory: '/',
        ),
      );

      expect(problems, hasLength(2));
    });
  });
}
