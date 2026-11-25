import '../plugins/seams.dart';

/// Bounded, session-local source index. The scanner refreshes file contents on
/// every query so edits and deletions are reflected without a stale disk cache.
class WorkspaceIndex {
  WorkspaceIndex(this.fileSystem);

  static const int maxFiles = 200;
  static const int maxFileCharacters = 64000;
  static const int maxTotalCharacters = 2000000;
  static const int maxResults = 100;

  static const Set<String> _excludedDirectories = <String>{
    '.git',
    '.dart_tool',
    '.gradle',
    '.idea',
    '.vscode',
    '.venv',
    '.next',
    '.nuxt',
    '.chronox',
    '.pytest_cache',
    '__pycache__',
    'node_modules',
    'build',
    'dist',
    'coverage',
    'target',
    'vendor',
  };

  static const Set<String> _sourceExtensions = <String>{
    '.dart',
    '.js',
    '.jsx',
    '.mjs',
    '.cjs',
    '.ts',
    '.tsx',
    '.py',
    '.go',
    '.rs',
  };

  final FileSystemSeam fileSystem;
  Map<String, IndexedSourceFile> _files = <String, IndexedSourceFile>{};
  int updatedFiles = 0;
  int skippedFiles = 0;
  int scanDurationMs = 0;
  bool truncated = false;

  int get fileCount => _files.length;
  int get cachedCharacters => _files.values
      .fold<int>(0, (final sum, final file) => sum + file.content.length);

  Future<void> refresh() async {
    final stopwatch = Stopwatch()..start();
    final discovered = (await fileSystem.glob('/workspace/**'))
        .where(_isIndexablePath)
        .toSet()
        .toList()
      ..sort();
    truncated = discovered.length >= 500 || discovered.length > maxFiles;
    final paths = discovered.take(maxFiles).toList();
    final next = <String, IndexedSourceFile>{};
    var totalCharacters = 0;
    updatedFiles = 0;
    skippedFiles = discovered.length - paths.length;

    for (final path in paths) {
      if (totalCharacters >= maxTotalCharacters) {
        truncated = true;
        skippedFiles++;
        continue;
      }
      try {
        final raw = await fileSystem.readFile(path);
        if (raw.contains('\u0000')) {
          skippedFiles++;
          continue;
        }
        if (raw.length > maxFileCharacters) truncated = true;
        final content = raw.length > maxFileCharacters
            ? raw.substring(0, maxFileCharacters)
            : raw;
        if (content.length + totalCharacters > maxTotalCharacters) {
          skippedFiles++;
          continue;
        }
        totalCharacters += content.length;
        final old = _files[path];
        if (old != null && old.content == content) {
          next[path] = old;
        } else {
          next[path] = IndexedSourceFile.parse(path, content);
          updatedFiles++;
        }
      } catch (_) {
        skippedFiles++;
      }
    }
    _files = next;
    stopwatch.stop();
    scanDurationMs = stopwatch.elapsedMilliseconds;
  }

  List<WorkspaceSymbol> symbols({String query = '', int limit = 50}) {
    final needle = query.trim().toLowerCase();
    final found = <WorkspaceSymbol>[];
    final paths = _files.keys.toList()..sort();
    for (final path in paths) {
      for (final symbol in _files[path]!.symbols) {
        if (needle.isNotEmpty && !symbol.name.toLowerCase().contains(needle)) {
          continue;
        }
        found.add(symbol);
        if (found.length >= limit.clamp(1, maxResults)) return found;
      }
    }
    return found;
  }

  List<WorkspaceImport> imports({String query = '', int limit = 50}) {
    final needle = query.trim().toLowerCase();
    final found = <WorkspaceImport>[];
    final paths = _files.keys.toList()..sort();
    for (final path in paths) {
      for (final item in _files[path]!.imports) {
        if (needle.isNotEmpty && !item.source.toLowerCase().contains(needle)) {
          continue;
        }
        found.add(item);
        if (found.length >= limit.clamp(1, maxResults)) return found;
      }
    }
    return found;
  }

  List<WorkspaceReference> references(String identifier, {int limit = 50}) {
    if (!RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(identifier)) {
      throw ArgumentError.value(identifier, 'identifier', 'Invalid identifier');
    }
    final expression = RegExp('\\b${RegExp.escape(identifier)}\\b');
    final found = <WorkspaceReference>[];
    final paths = _files.keys.toList()..sort();
    for (final path in paths) {
      final lines = _files[path]!.content.split('\n');
      for (var index = 0; index < lines.length; index++) {
        for (final match in expression.allMatches(lines[index])) {
          found.add(
            WorkspaceReference(
              path: path,
              line: index + 1,
              column: match.start + 1,
              endColumn: match.end + 1,
              excerpt: lines[index].trim().substring(
                    0,
                    lines[index].trim().length.clamp(0, 240).toInt(),
                  ),
            ),
          );
          if (found.length >= limit.clamp(1, maxResults)) return found;
        }
      }
    }
    return found;
  }

  static bool _isIndexablePath(final String path) {
    if (!path.startsWith('/workspace/') || path.contains('\\')) return false;
    final segments = path.substring('/workspace/'.length).split('/');
    if (segments.any(_excludedDirectories.contains)) return false;
    final dot = path.lastIndexOf('.');
    if (dot < 0) return false;
    return _sourceExtensions.contains(path.substring(dot).toLowerCase());
  }
}

class IndexedSourceFile {
  IndexedSourceFile({
    required this.path,
    required this.content,
    required this.language,
    required this.symbols,
    required this.imports,
  });

  final String path;
  final String content;
  final String language;
  final List<WorkspaceSymbol> symbols;
  final List<WorkspaceImport> imports;

  static IndexedSourceFile parse(final String path, final String content) {
    final extension = path.substring(path.lastIndexOf('.')).toLowerCase();
    final language = switch (extension) {
      '.dart' => 'dart',
      '.js' || '.jsx' || '.mjs' || '.cjs' => 'javascript',
      '.ts' || '.tsx' => 'typescript',
      '.py' => 'python',
      '.go' => 'go',
      '.rs' => 'rust',
      _ => 'text',
    };
    final symbols = <WorkspaceSymbol>[];
    final imports = <WorkspaceImport>[];
    final lines = content.split('\n');
    final symbolPatterns = _symbolPatterns(language);
    final importPattern = _importPattern(language);
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      for (final pattern in symbolPatterns) {
        final match = pattern.firstMatch(line);
        if (match == null) continue;
        final name = match.namedGroup('name');
        if (name == null) continue;
        symbols.add(
          WorkspaceSymbol(
            name: name,
            kind: match.namedGroup('kind') ?? 'symbol',
            path: path,
            line: index + 1,
            language: language,
            approximate: true,
          ),
        );
        break;
      }
      final importMatch = importPattern.firstMatch(line);
      if (importMatch != null) {
        imports.add(
          WorkspaceImport(
            source: language == 'python'
                ? importMatch.group(1) ?? importMatch.group(2) ?? ''
                : importMatch.namedGroup('source') ?? '',
            path: path,
            line: index + 1,
            language: language,
            approximate: true,
          ),
        );
      }
    }
    return IndexedSourceFile(
      path: path,
      content: content,
      language: language,
      symbols: symbols,
      imports: imports,
    );
  }

  static List<RegExp> _symbolPatterns(final String language) {
    final prefix = switch (language) {
      'python' => r'^\s*(?<kind>async\s+def|def|class)\s+(?<name>[A-Za-z_]\w*)',
      'go' =>
        r'^\s*(?<kind>func|type)\s+(?:\([^)]*\)\s*)?(?<name>[A-Za-z_]\w*)',
      'rust' =>
        r'^\s*(?:pub(?:\([^)]*\))?\s+)?(?<kind>fn|struct|enum|trait|type|mod)\s+(?<name>[A-Za-z_]\w*)',
      _ =>
        r'^\s*(?:(?:export|default|abstract|async|public|private|static|final)\s+)*(?<kind>class|interface|enum|type|function)\s+(?<name>[A-Za-z_$][\w$]*)',
    };
    final patterns = <RegExp>[RegExp(prefix)];
    if (language == 'dart' ||
        language == 'javascript' ||
        language == 'typescript') {
      patterns.add(RegExp(
        r'^\s*(?:(?:export|default|async|static|final|const|let|var)\s+)*(?<kind>function|const|let|var)\s+(?<name>[A-Za-z_$][\w$]*)\s*(?:=|\()',
      ));
    }
    if (language == 'dart') {
      patterns.add(RegExp(
        r'^\s*(?:Future(?:<[^>]+>)?|void|int|String|bool|dynamic|[A-Z]\w*(?:<[^>]+>)?)\s+(?<name>[A-Za-z_$]\w*)\s*\(',
      ));
    }
    return patterns;
  }

  static RegExp _importPattern(final String language) => switch (language) {
        'python' =>
          RegExp(r'^\s*(?:from\s+([\w.]+)\s+import|import\s+([\w.]+))'),
        'go' => RegExp(r'^\s*import\s+(?:\w+\s+)?"(?<source>[^"]+)"'),
        'rust' => RegExp(r'^\s*use\s+(?<source>[\w:]+)'),
        _ => RegExp(
            r"""^\s*import\s+(?:.*?\s+from\s+)?["'](?<source>[^"']+)["']"""),
      };
}

class WorkspaceSymbol {
  const WorkspaceSymbol({
    required this.name,
    required this.kind,
    required this.path,
    required this.line,
    required this.language,
    required this.approximate,
  });

  final String name;
  final String kind;
  final String path;
  final int line;
  final String language;
  final bool approximate;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'kind': kind,
        'path': path,
        'line': line,
        'language': language,
        'approximate': approximate,
      };
}

class WorkspaceImport {
  const WorkspaceImport({
    required this.source,
    required this.path,
    required this.line,
    required this.language,
    required this.approximate,
  });

  final String source;
  final String path;
  final int line;
  final String language;
  final bool approximate;

  Map<String, Object?> toJson() => <String, Object?>{
        'source': source,
        'path': path,
        'line': line,
        'language': language,
        'approximate': approximate,
      };
}

class WorkspaceReference {
  const WorkspaceReference({
    required this.path,
    required this.line,
    required this.column,
    required this.endColumn,
    required this.excerpt,
  });

  final String path;
  final int line;
  final int column;
  final int endColumn;
  final String excerpt;

  Map<String, Object?> toJson() => <String, Object?>{
        'path': path,
        'line': line,
        'column': column,
        'endColumn': endColumn,
        'excerpt': excerpt,
      };
}
