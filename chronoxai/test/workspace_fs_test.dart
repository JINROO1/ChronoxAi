import 'dart:io';

import 'package:chronoxai/data/runtime/local_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory workspace;
  late WorkspaceFileSystemSeam fs;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('chronox-ws-');
    fs = WorkspaceFileSystemSeam(hostWorkspace: workspace.path);
  });

  tearDown(() {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  group('WorkspaceFileSystemSeam — confinamiento', () {
    test('traduce /workspace a la ruta del dispositivo', () {
      final resolved = fs.resolve('/workspace/lib/main.dart');
      expect(resolved,
          p.join(Directory(workspace.path).absolute.path, 'lib', 'main.dart'));
    });

    test('acepta rutas relativas dentro del workspace', () {
      expect(
        fs.resolve('lib/a.dart'),
        p.join(Directory(workspace.path).absolute.path, 'lib', 'a.dart'),
      );
    });

    test('rechaza salir del workspace con ..', () {
      expect(
        () => fs.resolve('/workspace/../../etc/passwd'),
        throwsA(isA<RuntimeException>()),
      );
    });

    test('rechaza rutas absolutas fuera de /workspace', () {
      // Traducirlas en silencio a workspace/etc/shadow haría creer al agente que
      // lee el sistema cuando escribe en otro sitio.
      expect(() => fs.resolve('/etc/shadow'), throwsA(isA<RuntimeException>()));
      expect(() => fs.resolve('/tmp/x'), throwsA(isA<RuntimeException>()));
    });

    test('rechaza una ruta que empieza igual pero es hermana', () {
      // /workspace-otro no está dentro de /workspace.
      expect(
        () => fs.resolve('/workspace-otro/x'),
        throwsA(isA<RuntimeException>()),
      );
    });
  });

  group('WorkspaceFileSystemSeam — operaciones', () {
    test('escribe, lee y comprueba existencia', () async {
      await fs.writeFile('/workspace/src/a.dart', 'void main() {}');

      expect(await fs.exists('/workspace/src/a.dart'), isTrue);
      expect(await fs.readFile('/workspace/src/a.dart'), 'void main() {}');
      expect(await fs.exists('/workspace/src/b.dart'), isFalse);
    });

    test('crea los directorios intermedios al escribir', () async {
      await fs.writeFile('/workspace/a/b/c/d.txt', 'x');
      expect(
        File(
          p.join(
              Directory(workspace.path).absolute.path, 'a', 'b', 'c', 'd.txt'),
        ).existsSync(),
        isTrue,
      );
    });

    test('lista el contenido con rutas del contenedor', () async {
      await fs.writeFile('/workspace/uno.txt', '1');
      await fs.writeFile('/workspace/dos.txt', '2');

      expect(await fs.list('/workspace'), <String>[
        '/workspace/dos.txt',
        '/workspace/uno.txt',
      ]);
    });

    test('glob encuentra ficheros por extensión y por nombre', () async {
      await fs.writeFile('/workspace/lib/a.dart', '');
      await fs.writeFile('/workspace/lib/sub/b.dart', '');
      await fs.writeFile('/workspace/README.md', '');

      final dartFiles = await fs.glob('**/*.dart');
      expect(dartFiles, contains('/workspace/lib/a.dart'));
      expect(dartFiles, contains('/workspace/lib/sub/b.dart'));
      expect(dartFiles, isNot(contains('/workspace/README.md')));

      expect(await fs.glob('README.md'), <String>['/workspace/README.md']);
    });

    test('grep devuelve ruta, línea y texto', () async {
      await fs.writeFile('/workspace/lib/a.dart', 'uno\ndos\nnecesito esto\n');

      final matches = await fs.grep('necesito');

      expect(matches.single, startsWith('/workspace/lib/a.dart:3:'));
      expect(matches.single, contains('necesito esto'));
    });

    test('grep no intenta leer binarios', () async {
      await fs.writeFile('/workspace/codigo.dart', 'necesito esto');
      await fs.writeFile('/workspace/img.png', 'necesito pero es binario');

      final matches = await fs.grep('necesito');

      expect(matches, hasLength(1));
      expect(matches.single, startsWith('/workspace/codigo.dart'));
    });
  });
}
