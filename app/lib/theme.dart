// The look of the app, in one place.
//
// WHY A DESIGN FILE EXISTS AT ALL
//
// Before this, the whole theme was a single line - ColorScheme.fromSeed
// with a teal seed - and every screen picked its own colours and text
// sizes inline. That is why the app looked unfinished: nothing was
// deliberate, and nothing matched anything else.
//
// THE IDEA: A DELHI BUS, NOT A GENERIC TRANSIT APP
//
// The palette is DTC's own - the red of a Delhi Transport Corporation bus,
// the green of its cluster buses, on the warm off-white of a printed
// timetable rather than the cold grey of a default Material app.
//
// The strongest borrowed detail is the DESTINATION BOARD: the black board
// above a bus windscreen with the route number and where it is going, in
// condensed capitals. Route numbers throughout the app are drawn that way
// (see RouteBoard below), so a route reads as a real bus rather than as a
// string of text in a list.
//
// A NOTE ON THE FONTS
//
// No font files are bundled. Android already ships a condensed sans and a
// monospace face, and those are exactly the two shapes this design needs -
// condensed for destination boards, monospace for numbers that should line
// up. Bundling fonts would add megabytes, and fetching them at runtime
// would break the offline capability CLAUDE.md asks for (feature #7).
//
// Naming the family explicitly matters for a second reason: with no font
// set at all, a phone with a custom system font substitutes its own. On
// the OnePlus this was tested on, that meant the entire app rendered in a
// serif, which looked nothing like the intended design.

import 'package:flutter/material.dart';

/// Every colour the app uses. Nothing outside this class should invent one.
class WimbColors {
  WimbColors._(); // never instantiated - this is a namespace, not an object

  /// DTC bus red. The single strongest brand signal in the app.
  static const dtcRed = Color(0xFFC1272D);
  static const dtcRedDark = Color(0xFF9A1F24);

  /// Cluster-bus green. Doubles as the "you can trust this" colour.
  static const delhiGreen = Color(0xFF046A38);
  static const delhiGreenLight = Color(0xFFE3F0E8);

  /// Warm off-white background, like printed paper rather than a screen.
  static const cream = Color(0xFFFFF8EE);
  static const cardCream = Color(0xFFFFFDF8);

  /// Text. Warm near-black rather than pure black, which looks harsh on
  /// a cream background.
  static const ink = Color(0xFF1A1512);
  static const inkMuted = Color(0xFF6B5F57);

  /// The destination board above a bus windscreen: near-black, with warm
  /// off-white lettering the colour of an old bulb-lit sign.
  static const board = Color(0xFF14110F);
  static const boardText = Color(0xFFF5E6C8);

  /// Confidence levels. Green / amber / clay rather than green / orange /
  /// red, because a pure red would read as "error" when it actually means
  /// "this number is rough".
  static const trustHigh = delhiGreen;
  static const trustMedium = Color(0xFFE8A33D);
  static const trustLow = Color(0xFFB5502A);

  /// Faint warm border, used instead of a shadow in most places.
  static const hairline = Color(0xFFE5D9C9);
}

/// Font family names, with fallbacks.
///
/// These are Android's built-in families. On a platform that does not have
/// them (the web build, for instance) Flutter quietly falls back to the
/// next name in the list, so nothing breaks - it just looks less condensed.
class WimbFonts {
  WimbFonts._();

  /// Condensed sans, for destination boards and headings.
  static const condensed = 'sans-serif-condensed';

  /// Ordinary body text.
  static const body = 'Roboto';

  /// Monospace, so digits line up in a column of times.
  static const mono = 'monospace';

  static const fallback = <String>['Roboto', 'sans-serif'];
}

/// Turns the API's confidence word into the colour that represents it.
/// One function so the mapping cannot drift between screens.
Color trustColor(String level) {
  switch (level) {
    case 'high':
      return WimbColors.trustHigh;
    case 'medium':
      return WimbColors.trustMedium;
    case 'low':
      return WimbColors.trustLow;
    default:
      return WimbColors.inkMuted;
  }
}

/// The plain-English name for a confidence level, for showing next to the
/// trust dots. Kept beside trustColor so the two stay in step.
String trustLabel(String level) {
  switch (level) {
    case 'high':
      return 'high trust';
    case 'medium':
      return 'medium trust';
    case 'low':
      return 'rough estimate';
    default:
      return 'unknown';
  }
}

/// The app's one ThemeData. Everything component-level is set here rather
/// than on individual widgets, so a screen that just drops in a Card or a
/// FilledButton already looks right without styling it by hand.
ThemeData buildWimbTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: WimbColors.dtcRed,
    primary: WimbColors.dtcRed,
    secondary: WimbColors.delhiGreen,
    surface: WimbColors.cardCream,
    brightness: Brightness.light,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: WimbColors.cream,
    fontFamily: WimbFonts.body,
    fontFamilyFallback: WimbFonts.fallback,

    // Headings are condensed and tight; body text is not. The contrast
    // between the two is most of what makes the app look designed rather
    // than default.
    textTheme: const TextTheme(
      displaySmall: TextStyle(
        fontFamily: WimbFonts.condensed,
        fontFamilyFallback: WimbFonts.fallback,
        fontSize: 34,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        color: WimbColors.ink,
      ),
      headlineMedium: TextStyle(
        fontFamily: WimbFonts.condensed,
        fontFamilyFallback: WimbFonts.fallback,
        fontSize: 26,
        fontWeight: FontWeight.w700,
        color: WimbColors.ink,
      ),
      titleLarge: TextStyle(
        fontFamily: WimbFonts.condensed,
        fontFamilyFallback: WimbFonts.fallback,
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: WimbColors.ink,
      ),
      titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: WimbColors.ink),
      // A small all-caps label used above each section. The wide letter
      // spacing is what makes it read as a label rather than as a heading.
      labelSmall: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
        color: WimbColors.inkMuted,
      ),
      bodyLarge: TextStyle(fontSize: 15, color: WimbColors.ink, height: 1.4),
      bodyMedium: TextStyle(fontSize: 14, color: WimbColors.ink, height: 1.4),
      bodySmall: TextStyle(fontSize: 12.5, color: WimbColors.inkMuted, height: 1.35),
    ),

    appBarTheme: const AppBarTheme(
      backgroundColor: WimbColors.dtcRed,
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: WimbFonts.condensed,
        fontFamilyFallback: WimbFonts.fallback,
        fontSize: 22,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.3,
        color: Colors.white,
      ),
    ),

    // Cards get a hairline border instead of a drop shadow. On a cream
    // background a shadow turns muddy, while a thin warm line stays crisp.
    cardTheme: CardThemeData(
      color: WimbColors.cardCream,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: WimbColors.hairline),
      ),
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: WimbColors.cardCream,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: WimbColors.hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: WimbColors.hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: WimbColors.dtcRed, width: 2),
      ),
      labelStyle: const TextStyle(color: WimbColors.inkMuted),
      floatingLabelStyle: const TextStyle(color: WimbColors.dtcRed, fontWeight: FontWeight.w600),
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: WimbColors.dtcRed,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(
          fontFamily: WimbFonts.condensed,
          fontFamilyFallback: WimbFonts.fallback,
          fontSize: 17,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    ),

    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: WimbColors.cardCream,
      indicatorColor: WimbColors.dtcRed.withValues(alpha: 0.12),
      elevation: 0,
      height: 66,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 11.5,
          fontWeight: states.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
          color: states.contains(WidgetState.selected) ? WimbColors.dtcRed : WimbColors.inkMuted,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 23,
          color: states.contains(WidgetState.selected) ? WimbColors.dtcRed : WimbColors.inkMuted,
        ),
      ),
    ),

    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        textStyle: WidgetStatePropertyAll(
          const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
    ),

    dividerTheme: const DividerThemeData(color: WimbColors.hairline, thickness: 1, space: 1),

    snackBarTheme: const SnackBarThemeData(
      backgroundColor: WimbColors.board,
      contentTextStyle: TextStyle(color: WimbColors.boardText, fontSize: 14),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

// ---------------------------------------------------------------------------
// Shared pieces of the look, used on more than one screen.
// ---------------------------------------------------------------------------

/// A route number drawn as the destination board above a bus windscreen.
///
/// This is the app's signature detail. A real Delhi bus carries a black
/// board with the route number and its destination in condensed capitals,
/// and copying that makes a route in a list read as an actual bus rather
/// than as a row of text.
///
/// [destination] is optional because the board is used in two ways: on its
/// own as a small badge in a tight row, and full-width with the destination
/// underneath when there is room to show where the bus is heading.
class RouteBoard extends StatelessWidget {
  final String routeName;
  final String? destination;

  /// Shrinks the whole board for use inside a dense list row.
  final bool compact;

  const RouteBoard({
    super.key,
    required this.routeName,
    this.destination,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 9 : 13,
        vertical: compact ? 5 : 9,
      ),
      decoration: BoxDecoration(
        color: WimbColors.board,
        borderRadius: BorderRadius.circular(compact ? 6 : 8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            routeName.toUpperCase(),
            style: TextStyle(
              fontFamily: WimbFonts.condensed,
              fontFamilyFallback: WimbFonts.fallback,
              color: WimbColors.boardText,
              fontSize: compact ? 14 : 19,
              fontWeight: FontWeight.w700,
              // Wide spacing is what sells the destination-board look -
              // real boards space their letters out to fill the width.
              letterSpacing: 1.3,
              height: 1.1,
            ),
          ),
          if (destination != null && destination!.isNotEmpty && !compact) ...[
            const SizedBox(height: 3),
            Text(
              destination!.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: WimbFonts.condensed,
                fontFamilyFallback: WimbFonts.fallback,
                // Dimmer than the route number, so the eye reads the
                // number first - same as looking at a real bus.
                color: WimbColors.boardText.withValues(alpha: 0.72),
                fontSize: 12,
                letterSpacing: 0.9,
                height: 1.1,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The trust indicator, as a row of five dots.
///
/// CLAUDE.md's fourth core feature: the user is told how much to trust a
/// number, not just given the number. Dots rather than a single coloured
/// blob because a count is glanceable - five filled versus two filled
/// reads instantly, where two similar shades of colour do not, and it
/// still works for someone who cannot easily tell green from amber.
class TrustDots extends StatelessWidget {
  final String level; // 'high' | 'medium' | 'low'
  final bool showLabel;

  const TrustDots({super.key, required this.level, this.showLabel = true});

  /// How many of the five dots are filled in.
  int get _filled {
    switch (level) {
      case 'high':
        return 5;
      case 'medium':
        return 3;
      case 'low':
        return 1;
      default:
        return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = trustColor(level);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < 5; i++)
          Padding(
            padding: const EdgeInsets.only(right: 3),
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < _filled ? color : color.withValues(alpha: 0.18),
              ),
            ),
          ),
        if (showLabel) ...[
          const SizedBox(width: 7),
          Text(
            trustLabel(level),
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ],
    );
  }
}

/// A small all-caps label that sits above a group of things, e.g. "BY THE
/// HOUR". Used instead of a heading where the group needs naming but does
/// not deserve the visual weight of a real title.
class SectionLabel extends StatelessWidget {
  final String text;
  const SectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text.toUpperCase(), style: Theme.of(context).textTheme.labelSmall),
    );
  }
}

/// The app's wordmark: "WHERE IS MY BUS" over "दिल्ली · DELHI".
///
/// The Hindi is not decoration - this is an app for Delhi, and a Delhi bus
/// carries its route board in both scripts. Showing only English would
/// look like software written about Delhi from somewhere else.
class WimbWordmark extends StatelessWidget {
  final Color color;
  const WimbWordmark({super.key, this.color = Colors.white});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'WHERE IS MY BUS',
          style: TextStyle(
            fontFamily: WimbFonts.condensed,
            fontFamilyFallback: WimbFonts.fallback,
            color: color,
            fontSize: 21,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.4,
            height: 1.05,
          ),
        ),
        Text(
          'दिल्ली · DELHI',
          style: TextStyle(
            color: color.withValues(alpha: 0.82),
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
            letterSpacing: 1.1,
          ),
        ),
      ],
    );
  }
}

/// A caveat line - one of the honest "here is what this number does not
/// know" notes the API returns with every answer.
///
/// Given its own widget because these appear on every result screen and
/// must look consistent: quiet enough not to shout, clear enough to read.
class CaveatLine extends StatelessWidget {
  final String text;
  const CaveatLine(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 7),
            child: Icon(Icons.info_outline, size: 13, color: WimbColors.inkMuted.withValues(alpha: 0.7)),
          ),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
        ],
      ),
    );
  }
}
