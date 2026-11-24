import 'package:flutter/material.dart';

/// Paleta y tokens visuales de Chronox AI.
///
/// Estética: "deep space terminal" — fondo casi negro con un leve tinte
/// azul-violeta, acentos cian y violeta, superficies translúcidas.
abstract final class ChronoxColors {
  static const void_ = Color(0xFF000000);

  // Fondo
  static const background = Color(0xFF07080D);
  static const backgroundElevated = Color(0xFF0C0E16);
  static const surface = Color(0xFF11141F);
  static const surfaceHigh = Color(0xFF171B29);

  // Bordes
  static const border = Color(0xFF212636);
  static const borderGlow = Color(0xFF2B3348);

  // Acentos
  static const primary = Color(0xFF4DE1C1); // cian-verde
  static const primaryDim = Color(0xFF1F8C79);
  static const accent = Color(0xFF8B7BFF); // violeta
  static const accentDim = Color(0xFF55499E);
  static const warning = Color(0xFFFFB454);
  static const danger = Color(0xFFFF5C7A);
  static const success = Color(0xFF5AE08B);

  // Texto
  static const textPrimary = Color(0xFFEDF1F7);
  static const textSecondary = Color(0xFF9AA3B8);
  static const textMuted = Color(0xFF5C6478);

  // Código
  static const codeBackground = Color(0xFF0A0C13);
  static const codeAddition = Color(0xFF10301F);
  static const codeDeletion = Color(0xFF331318);
}

abstract final class ChronoxRadius {
  static const double sm = 10;
  static const double md = 16;
  static const double lg = 22;
  static const double xl = 28;

  static const card = BorderRadius.all(Radius.circular(md));
  static const cardLarge = BorderRadius.all(Radius.circular(lg));
  static const pill = BorderRadius.all(Radius.circular(999));
}

abstract final class ChronoxSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
}

/// Gradientes reutilizables.
abstract final class ChronoxGradients {
  static const brand = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [ChronoxColors.primary, ChronoxColors.accent],
  );

  static const brandSoft = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0x334DE1C1), Color(0x228B7BFF)],
  );

  static const screen = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF0A0C14), ChronoxColors.background],
  );

  static const glow = RadialGradient(
    colors: [Color(0x334DE1C1), Color(0x00000000)],
  );
}

/// Tema Material 3 de la app.
abstract final class ChronoxTheme {
  static const String monoFamily = 'monospace';
  static const String sansFamily = 'Roboto';

  static ThemeData dark() {
    const scheme = ColorScheme.dark(
      primary: ChronoxColors.primary,
      onPrimary: Color(0xFF00120D),
      primaryContainer: ChronoxColors.primaryDim,
      onPrimaryContainer: ChronoxColors.textPrimary,
      secondary: ChronoxColors.accent,
      onSecondary: Color(0xFF0B0620),
      secondaryContainer: ChronoxColors.accentDim,
      onSecondaryContainer: ChronoxColors.textPrimary,
      tertiary: ChronoxColors.warning,
      error: ChronoxColors.danger,
      onError: Color(0xFF2A0009),
      surface: ChronoxColors.surface,
      onSurface: ChronoxColors.textPrimary,
      surfaceContainerHighest: ChronoxColors.surfaceHigh,
      onSurfaceVariant: ChronoxColors.textSecondary,
      outline: ChronoxColors.border,
      outlineVariant: ChronoxColors.borderGlow,
      shadow: Color(0xFF000000),
      scrim: Color(0xFF000000),
      inverseSurface: ChronoxColors.textPrimary,
      onInverseSurface: ChronoxColors.background,
      inversePrimary: ChronoxColors.primaryDim,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: ChronoxColors.background,
      canvasColor: ChronoxColors.background,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
    );

    return base.copyWith(
      textTheme: _textTheme(base.textTheme),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: sansFamily,
          fontSize: 19,
          fontWeight: FontWeight.w600,
          color: ChronoxColors.textPrimary,
          letterSpacing: -0.2,
        ),
        iconTheme: IconThemeData(color: ChronoxColors.textSecondary),
      ),
      cardTheme: const CardTheme(
        color: ChronoxColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: ChronoxRadius.cardLarge,
          side: BorderSide(color: ChronoxColors.border),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: ChronoxColors.border,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: ChronoxColors.surfaceHigh,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        hintStyle:
            const TextStyle(color: ChronoxColors.textMuted, fontSize: 14),
        labelStyle: const TextStyle(color: ChronoxColors.textSecondary),
        border: _inputBorder(ChronoxColors.border),
        enabledBorder: _inputBorder(ChronoxColors.border),
        focusedBorder: _inputBorder(ChronoxColors.primary, width: 1.6),
        errorBorder: _inputBorder(ChronoxColors.danger),
        focusedErrorBorder: _inputBorder(ChronoxColors.danger, width: 1.6),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: ChronoxColors.primary,
          foregroundColor: const Color(0xFF00120D),
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 22),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 15,
            letterSpacing: 0.1,
          ),
          shape: const RoundedRectangleBorder(borderRadius: ChronoxRadius.card),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ChronoxColors.textPrimary,
          minimumSize: const Size(0, 46),
          side: const BorderSide(color: ChronoxColors.borderGlow),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          shape: const RoundedRectangleBorder(borderRadius: ChronoxRadius.card),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: ChronoxColors.primary),
      ),
      chipTheme: const ChipThemeData(
        backgroundColor: ChronoxColors.surfaceHigh,
        selectedColor: ChronoxColors.primaryDim,
        side: BorderSide(color: ChronoxColors.border),
        labelStyle: TextStyle(color: ChronoxColors.textSecondary, fontSize: 12),
        shape: RoundedRectangleBorder(borderRadius: ChronoxRadius.pill),
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? ChronoxColors.primary
              : ChronoxColors.textMuted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? ChronoxColors.primaryDim.withOpacity(0.5)
              : ChronoxColors.surfaceHigh,
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: ChronoxColors.surfaceHigh,
        contentTextStyle: TextStyle(color: ChronoxColors.textPrimary),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: ChronoxRadius.card),
      ),
      dialogTheme: const DialogTheme(
        backgroundColor: ChronoxColors.backgroundElevated,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: ChronoxRadius.cardLarge),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: ChronoxColors.primary,
        linearTrackColor: ChronoxColors.surfaceHigh,
        circularTrackColor: ChronoxColors.surfaceHigh,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: ChronoxColors.surfaceHigh,
          borderRadius: ChronoxRadius.card,
          border: Border.all(color: ChronoxColors.borderGlow),
        ),
        textStyle:
            const TextStyle(color: ChronoxColors.textPrimary, fontSize: 12),
      ),
    );
  }

  static OutlineInputBorder _inputBorder(Color color, {double width = 1}) {
    return OutlineInputBorder(
      borderRadius: ChronoxRadius.card,
      borderSide: BorderSide(color: color, width: width),
    );
  }

  static TextTheme _textTheme(TextTheme base) {
    return base
        .apply(
          bodyColor: ChronoxColors.textPrimary,
          displayColor: ChronoxColors.textPrimary,
        )
        .copyWith(
          displaySmall: base.displaySmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.8,
          ),
          headlineMedium: base.headlineMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
          ),
          titleLarge: base.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: -0.3,
          ),
          titleMedium: base.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          bodyLarge: base.bodyLarge?.copyWith(height: 1.5),
          bodyMedium: base.bodyMedium?.copyWith(height: 1.5),
          labelLarge: base.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        );
  }

  /// Estilo para bloques de código y terminal.
  static const TextStyle mono = TextStyle(
    fontFamily: monoFamily,
    fontSize: 13,
    height: 1.45,
    color: ChronoxColors.textPrimary,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const TextStyle monoSmall = TextStyle(
    fontFamily: monoFamily,
    fontSize: 11.5,
    height: 1.4,
    color: ChronoxColors.textSecondary,
  );
}
