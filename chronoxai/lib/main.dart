import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme.dart';
import 'ui/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Barra de estado transparente y gestos a pantalla completa: la interfaz se
  // dibuja hasta los bordes, que es lo que hace que una app se vea nativa.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(const ProviderScope(child: ChronoxApp()));
}

class ChronoxApp extends StatelessWidget {
  const ChronoxApp({super.key});

  @override
  Widget build(final BuildContext context) {
    return MaterialApp(
      title: 'Chronox AI',
      debugShowCheckedModeBanner: false,
      theme: ChronoxTheme.dark(),
      darkTheme: ChronoxTheme.dark(),
      themeMode: ThemeMode.dark,
      home: const AppShell(),
    );
  }
}
