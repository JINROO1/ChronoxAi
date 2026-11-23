import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Error al hablar con un registro de imágenes.
class RegistryException implements Exception {
  const RegistryException(this.message, {this.statusCode, this.isRetryable = false});

  final String message;
  final int? statusCode;

  /// `true` para 5xx y límites de peticiones: tiene sentido reintentar.
  final bool isRetryable;

  @override
  String toString() => 'RegistryException: $message';
}

/// Una capa (`blob`) de una imagen.
class OciLayer {
  const OciLayer({
    required this.digest,
    required this.size,
    required this.mediaType,
  });

  /// `sha256:...`, tal cual viene del manifiesto.
  final String digest;
  final int size;
  final String mediaType;

  /// `true` si la capa es un `tar.gz` (o un `tar` sin comprimir).
  bool get needsGunzip =>
      mediaType.contains('gzip') || mediaType.contains('tar+gzip');

  bool get isTar => mediaType.contains('tar');

  /// Hash en hexadecimal, sin el prefijo del algoritmo.
  String get hexDigest => digest.contains(':') ? digest.split(':')[1] : digest;
}

/// Manifiesto resuelto de una imagen.
class OciManifest {
  const OciManifest({
    required this.layers,
    required this.configDigest,
    this.architecture,
  });

  final List<OciLayer> layers;
  final String configDigest;
  final String? architecture;

  int get totalBytes => layers.fold(0, (final sum, final l) => sum + l.size);
}

/// Cliente mínimo de registro OCI / Docker Registry v2.
///
/// Se usa **sin dependencias nuevas**: son cuatro peticiones HTTP y una
/// autenticación por token anónimo. Un paquete de OCI arrastraría su propio
/// cliente HTTP y su propio manejo de errores, y aquí el control del flujo (y de
/// la cancelación) importa.
///
/// Funciona con Docker Hub y con cualquier mirror que implemente la API v2, así
/// que si un día hace falta un mirror propio (China, red corporativa) solo cambia
/// `baseUrl`.
class OciRegistryClient {
  OciRegistryClient({
    required this.baseUrl,
    this.repository = 'library/debian',
    http.Client Function()? clientFactory,
  }) : _newClient = clientFactory ?? http.Client.new;

  /// Registro. Docker Hub expone la API en `registry-1.docker.io`.
  final String baseUrl;

  /// Repositorio (`library/debian` en Docker Hub).
  final String repository;

  final http.Client Function() _newClient;

  String? _token;

  /// Resuelve la etiqueta ([tag]) y devuelve el manifiesto con sus capas.
  ///
  /// Se piden los manifiestos de índice primero: Docker Hub puede devolver una
  /// *manifest list* (multi-arquitectura) y hay que quedarse con la del
  /// dispositivo, no con la primera (que suele ser amd64).
  Future<OciManifest> resolve({
    String tag = 'bookworm',
    required String architecture,
  }) async {
    final index = await _getJson(
      'https://$baseUrl/v2/$repository/manifests/$tag',
      accept: <String>[
        'application/vnd.oci.image.index.v1+json',
        'application/vnd.docker.distribution.manifest.list.v2+json',
        'application/vnd.oci.image.manifest.v1+json',
        'application/vnd.docker.distribution.manifest.v2+json',
      ],
    );

    if (index['manifests'] is List<Object?>) {
      final manifestDigest = _pickForArchitecture(index, architecture);
      final manifest = await _getJson(
        'https://$baseUrl/v2/$repository/manifests/$manifestDigest',
        accept: const <String>[
          'application/vnd.oci.image.manifest.v1+json',
          'application/vnd.docker.distribution.manifest.v2+json',
        ],
      );
      return _parseManifest(manifest, architecture);
    }

    // Ya era un manifiesto de imagen (algunos mirrors no devuelven índice).
    return _parseManifest(index, architecture);
  }

  String _pickForArchitecture(
    final Map<String, Object?> index,
    final String architecture,
  ) {
    final candidates = (index['manifests']! as List<Object?>)
        .whereType<Map<String, Object?>>()
        .where((final m) {
          final platform = m['platform'];
          return platform is Map<String, Object?> &&
              platform['architecture'] == architecture &&
              (platform['os'] == 'linux');
        })
        .toList();

    if (candidates.isEmpty) {
      throw RegistryException(
        'La imagen no tiene variante para "$architecture". '
        'Variantes disponibles: ${_availableArchitectures(index).join(', ')}.',
      );
    }
    // Si hay varias (variant v7/v8), se prefiere la primera: son compatibles.
    return candidates.first['digest']! as String;
  }

  List<String> _availableArchitectures(final Map<String, Object?> index) {
    final result = <String>{};
    for (final entry in (index['manifests']! as List<Object?>)
        .whereType<Map<String, Object?>>()) {
      final platform = entry['platform'];
      if (platform is Map<String, Object?> && platform['architecture'] != null) {
        result.add('${platform['architecture']}');
      }
    }
    return result.toList();
  }

  OciManifest _parseManifest(
    final Map<String, Object?> manifest,
    final String architecture,
  ) {
    final layers = <OciLayer>[];
    for (final entry in (manifest['layers'] as List<Object?>? ?? const <Object?>[])
        .whereType<Map<String, Object?>>()) {
      final digest = entry['digest'] as String?;
      if (digest == null) continue;
      layers.add(
        OciLayer(
          digest: digest,
          size: (entry['size'] as num?)?.toInt() ?? 0,
          mediaType: (entry['mediaType'] as String?) ?? 'application/vnd.oci.image.layer.v1.tar+gzip',
        ),
      );
    }
    if (layers.isEmpty) {
      throw const RegistryException('El manifiesto no declara capas.');
    }

    return OciManifest(
      layers: layers,
      configDigest: (manifest['config'] is Map<String, Object?>
              ? (manifest['config']! as Map<String, Object?>)['digest']
              : null)
              as String? ??
          '',
      architecture: architecture,
    );
  }

  /// Abre el flujo de una capa, con autenticación.
  ///
  /// El consumidor debe cancelar la suscripción si aborta: eso cierra el cliente
  /// HTTP y con él la descarga.
  Future<http.StreamedResponse> fetchBlob(
    final OciLayer layer, {
    required http.Client client,
  }) async {
    final token = await _ensureToken();
    final request = http.Request(
      'GET',
      Uri.parse('https://$baseUrl/v2/$repository/blobs/${layer.digest}'),
    )..headers.addAll(<String, String>{
        'Accept': 'application/octet-stream',
        if (token != null) 'Authorization': 'Bearer $token',
      });

    final response = await client.send(request);
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw _classify(response.statusCode, body, 'descargar la capa ${layer.digest}');
    }
    return response;
  }

  /// Descarga el `config` de la imagen (JSON con la arquitectura real).
  Future<Map<String, Object?>> fetchConfig(final String digest) =>
      _getJson(
        'https://$baseUrl/v2/$repository/blobs/$digest',
        accept: const <String>['application/vnd.oci.image.config.v1+json'],
      );

  // ---------------------------------------------------------------------------
  // Autenticación y transporte
  // ---------------------------------------------------------------------------

  Future<String?> _ensureToken() async {
    if (_token != null) return _token;

    final client = _newClient();
    try {
      final response = await client.get(
        Uri.parse('https://auth.docker.io/token?service=registry.docker.io'
            '&scope=repository:$repository:pull'),
      );
      if (response.statusCode != 200) {
        // Un registro sin autenticación (mirror local) devolverá 404 aquí: se
        // continúa sin token en lugar de fallar.
        return null;
      }
      final json = jsonDecode(response.body) as Map<String, Object?>;
      final token = json['token'] ?? json['access_token'];
      _token = token is String ? token : null;
      return _token;
    } finally {
      client.close();
    }
  }

  Future<Map<String, Object?>> _getJson(
    final String url, {
    required List<String> accept,
  }) async {
    final token = await _ensureToken();
    final client = _newClient();
    try {
      final response = await client.get(
        Uri.parse(url),
        headers: <String, String>{
          'Accept': accept.join(', '),
          if (token != null) 'Authorization': 'Bearer $token',
        },
      );

      if (response.statusCode != 200) {
        throw _classify(response.statusCode, response.body, 'leer $url');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, Object?>) {
        throw const RegistryException('El registro devolvió un JSON inesperado.');
      }
      return decoded;
    } finally {
      client.close();
    }
  }

  static RegistryException _classify(
    final int status,
    final String body,
    final String action,
  ) {
    final detail = body.length > 200 ? '${body.substring(0, 200)}…' : body;
    return switch (status) {
      401 || 403 => RegistryException(
        'El registro rechazó el acceso al intentar $action (HTTP $status). '
        'Puede ser un problema temporal del servicio de tokens.',
        statusCode: status,
        isRetryable: true,
      ),
      404 => RegistryException(
        'No se encontró el recurso al intentar $action (HTTP 404). '
        '¿Existe la etiqueta de la imagen?',
        statusCode: status,
      ),
      429 => RegistryException(
        'El registro limita las descargas (HTTP 429). Espera unos minutos.',
        statusCode: status,
        isRetryable: true,
      ),
      >= 500 => RegistryException(
        'El registro falló (HTTP $status) al intentar $action. Reintenta.',
        statusCode: status,
        isRetryable: true,
      ),
      _ => RegistryException(
        'Error del registro (HTTP $status) al intentar $action: $detail',
        statusCode: status,
      ),
    };
  }
}
