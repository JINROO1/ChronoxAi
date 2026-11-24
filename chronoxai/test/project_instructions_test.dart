import 'dart:io';

import 'package:chronoxai/domain/agent/project_instructions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('chronox-instr-');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Future<void> write(final String name, final String content) async {
    final file = File('${tempDir.path}/$name');
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  group('ProjectInstructions', () {
    test('sin ficheros devuelve cadena vacía', () async {
      expect(await ProjectInstructions.load(tempDir), isEmpty);
    });

    test('lee AGENTS.md y lo etiqueta con su nombre', () async {
      await write('AGENTS.md', '# Proyecto\nUsa `make test`.');

      final loaded = await ProjectInstructions.load(tempDir);

      expect(loaded, contains('--- AGENTS.md ---'));
      expect(loaded, contains('make test'));
    });

    test('lee CLAUDE.md y .chronox/instructions.md en orden', () async {
      await write('CLAUDE.md', 'contenido claude');
      await write('.chronox/instructions.md', 'contenido chronox');

      final loaded = await ProjectInstructions.load(tempDir);

      expect(loaded, contains('--- CLAUDE.md ---'));
      expect(loaded, contains('--- .chronox/instructions.md ---'));
      expect(
        loaded.indexOf('CLAUDE.md'),
        lessThan(loaded.indexOf('.chronox/instructions.md')),
      );
    });

    test('recorta ficheros enormes al límite', () async {
      await write('AGENTS.md', 'x' * (ProjectInstructions.maxChars + 500));

      final loaded = await ProjectInstructions.load(tempDir);

      expect(loaded, contains('truncadas'));
      expect(loaded.length, lessThan(ProjectInstructions.maxChars + 100));
    });

    test('un fichero ilegible no rompe la carga', () async {
      await write('AGENTS.md', 'válido');
      // Un directorio con el nombre del fichero: readAsString lanza.
      await Directory('${tempDir.path}/CLAUDE.md').create();

      final loaded = await ProjectInstructions.load(tempDir);

      expect(loaded, contains('válido'));
    });
  });
}
