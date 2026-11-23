import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Descomprime `gzip` en streaming, con contrapresión.
///
/// `gzip.decode(List<int>)` de `dart:io` exige el fichero completo: una capa de
/// 100 MB ocuparía otros tantos en RAM antes de escribir nada, y en un móvil eso
/// termina en cierre por falta de memoria. `dart:io` sí permite convertir **por
/// trozos** (`startChunkedConversion`), que es lo que se usa aquí.
///
/// La contrapresión es explícita: si el consumidor (el extractor de tar) tarda
/// porque está escribiendo a disco, se pausa la lectura de red en lugar de
/// acumular megas en memoria.
Stream<List<int>> gunzip(final Stream<List<int>> input) {
  late StreamController<List<int>> controller;
  StreamSubscription<List<int>>? subscription;
  late final ChunkedConversionSink<List<int>> decoder;

  final pending = <List<int>>[];

  void flush() {
    while (pending.isNotEmpty && !controller.isPaused && !controller.isClosed) {
      controller.add(pending.removeAt(0));
    }
  }

  controller = StreamController<List<int>>(
    onListen: () {
      decoder = gzip.decoder.startChunkedConversion(
        _Collector((final chunk) {
          if (controller.isClosed) return;
          if (controller.isPaused) {
            pending.add(chunk);
            subscription?.pause();
            return;
          }
          controller.add(chunk);
        }, onError: (final error, final stack) {
          if (!controller.isClosed) controller.addError(error, stack);
        }),
      );

      subscription = input.listen(
        (final chunk) {
          try {
            decoder.add(chunk);
            flush();
          } catch (error, stack) {
            if (!controller.isClosed) controller.addError(error, stack);
          }
        },
        onError: (final Object error, final StackTrace stack) {
          if (!controller.isClosed) controller.addError(error, stack);
        },
        onDone: () {
          try {
            decoder.close();
            flush();
          } catch (error, stack) {
            if (!controller.isClosed) controller.addError(error, stack);
          }
          pending.clear();
          if (!controller.isClosed) unawaited(controller.close());
        },
        cancelOnError: false,
      );
    },
    onPause: () => subscription?.pause(),
    onResume: () {
      flush();
      subscription?.resume();
    },
    onCancel: () async {
      await subscription?.cancel();
      pending.clear();
    },
  );

  return controller.stream;
}

/// Recoge la salida del decodificador y la entrega trozo a trozo.
class _Collector implements Sink<List<int>> {
  _Collector(this._onData, {required this.onError});

  final void Function(List<int>) _onData;
  final void Function(Object, StackTrace) onError;

  @override
  void add(final List<int> data) {
    if (data.isNotEmpty) _onData(data);
  }

  @override
  void close() {}
}
