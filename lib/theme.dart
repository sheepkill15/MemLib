import 'package:flutter/material.dart';

/// Design tokens shared by the library window, quick picker and dialogs.
///
/// The Android keyboard (Kotlin) and the website mirror these values; keep
/// `docs/design-system.md` in sync when changing them.
abstract final class MemlibColors {
  static const canvas = Color(0xFF0E0C13);
  static const surface = Color(0xFF15121C);
  static const raised = Color(0xFF1C1825);
  static const high = Color(0xFF252031);
  static const highest = Color(0xFF2F2940);
  static const hairline = Color(0xFF231E2C);
  static const border = Color(0xFF342D42);
  static const accent = Color(0xFFBDA7FF);
  static const accentDeep = Color(0xFF8B68FF);
  static const accentSoft = Color(0x2EBDA7FF);
  static const accentLine = Color(0x73BDA7FF);
  static const onAccent = Color(0xFF17122A);
  static const text = Color(0xFFF3F1F7);
  static const textMuted = Color(0xFFA8A2B6);
  static const textFaint = Color(0xFF6F6980);
  static const danger = Color(0xFFFF8F87);
  static const dangerSoft = Color(0x26FF8F87);
  static const star = Color(0xFFFFC857);
  static const scrim = Color(0xB30E0C13);
}

abstract final class MemlibRadius {
  static const small = 8.0;
  static const control = 10.0;
  static const tile = 14.0;
  static const panel = 18.0;
}

typedef _C = MemlibColors;

ThemeData buildMemlibTheme() {
  OutlineInputBorder outline(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(MemlibRadius.control),
        borderSide: BorderSide(color: color, width: width),
      );
  final controlShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(MemlibRadius.control),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: const ColorScheme.dark(
      primary: _C.accent,
      onPrimary: _C.onAccent,
      primaryContainer: _C.accentSoft,
      onPrimaryContainer: _C.accent,
      secondary: _C.accent,
      onSecondary: _C.onAccent,
      secondaryContainer: _C.highest,
      onSecondaryContainer: _C.text,
      surface: _C.surface,
      onSurface: _C.text,
      onSurfaceVariant: _C.textMuted,
      surfaceContainerLowest: _C.canvas,
      surfaceContainerLow: _C.surface,
      surfaceContainer: _C.raised,
      surfaceContainerHigh: _C.high,
      surfaceContainerHighest: _C.highest,
      outline: _C.border,
      outlineVariant: _C.hairline,
      error: _C.danger,
      onError: _C.onAccent,
    ),
    scaffoldBackgroundColor: _C.canvas,
    canvasColor: _C.canvas,
    dividerColor: _C.hairline,
    visualDensity: VisualDensity.compact,
    hoverColor: const Color(0x0FFFFFFF),
    highlightColor: const Color(0x0AFFFFFF),
    splashColor: const Color(0x14BDA7FF),
    focusColor: const Color(0x1FBDA7FF),
    dividerTheme: const DividerThemeData(
      color: _C.hairline,
      thickness: 1,
      space: 1,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: _C.canvas,
      foregroundColor: _C.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 56,
      titleSpacing: 16,
      shape: Border(bottom: BorderSide(color: _C.hairline)),
    ),
    cardTheme: CardThemeData(
      color: _C.raised,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(MemlibRadius.tile),
      ),
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: _C.accent,
      selectionColor: Color(0x55BDA7FF),
      selectionHandleColor: _C.accent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: _C.high,
      isDense: true,
      hintStyle: const TextStyle(color: _C.textFaint, fontSize: 14),
      labelStyle: const TextStyle(color: _C.textMuted),
      floatingLabelStyle: const TextStyle(color: _C.accent),
      prefixIconColor: _C.textMuted,
      suffixIconColor: _C.textMuted,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: outline(Colors.transparent),
      enabledBorder: outline(Colors.transparent),
      focusedBorder: outline(_C.accentLine, 1.5),
      errorBorder: outline(_C.danger),
      focusedErrorBorder: outline(_C.danger, 1.5),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: _C.accent,
        foregroundColor: _C.onAccent,
        disabledBackgroundColor: _C.high,
        disabledForegroundColor: _C.textFaint,
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        shape: controlShape,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: _C.text,
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        side: const BorderSide(color: _C.border),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        shape: controlShape,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: _C.textMuted,
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        shape: controlShape,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: _C.textMuted,
        highlightColor: const Color(0x14FFFFFF),
        shape: controlShape,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      side: const BorderSide(color: Color(0xCCFFFFFF), width: 1.5),
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? _C.accent
            : const Color(0x990E0C13),
      ),
      checkColor: const WidgetStatePropertyAll(_C.onAccent),
    ),
    listTileTheme: ListTileThemeData(
      dense: true,
      visualDensity: VisualDensity.compact,
      textColor: _C.text,
      iconColor: _C.textMuted,
      selectedColor: _C.accent,
      selectedTileColor: _C.accentSoft,
      horizontalTitleGap: 10,
      minLeadingWidth: 20,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(MemlibRadius.small),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 10),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: _C.high,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: Colors.black,
      textStyle: const TextStyle(color: _C.text, fontSize: 14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: _C.border),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: _C.raised,
      surfaceTintColor: Colors.transparent,
      elevation: 24,
      shadowColor: Colors.black,
      titleTextStyle: const TextStyle(
        color: _C.text,
        fontSize: 18,
        fontWeight: FontWeight.w700,
        letterSpacing: -.2,
      ),
      contentTextStyle: const TextStyle(
        color: _C.textMuted,
        fontSize: 14,
        height: 1.45,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(MemlibRadius.panel),
        side: const BorderSide(color: _C.border),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: _C.highest,
      contentTextStyle: const TextStyle(color: _C.text, fontSize: 14),
      actionTextColor: _C.accent,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: _C.border),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 450),
      textStyle: const TextStyle(color: _C.text, fontSize: 12),
      decoration: BoxDecoration(
        color: _C.highest,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: _C.border),
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: const WidgetStatePropertyAll(Color(0x33FFFFFF)),
      thickness: const WidgetStatePropertyAll(6.0),
      radius: const Radius.circular(6),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: _C.accent,
      linearTrackColor: Colors.transparent,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: _C.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: _C.accentSoft,
      elevation: 0,
      height: 64,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: states.contains(WidgetState.selected)
              ? _C.accent
              : _C.textMuted,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 22,
          color: states.contains(WidgetState.selected)
              ? _C.accent
              : _C.textMuted,
        ),
      ),
    ),
  );
}

/// Builds its child with the current mouse-hover state.
class Hoverable extends StatefulWidget {
  const Hoverable({super.key, required this.builder, this.cursor});
  final Widget Function(BuildContext context, bool hovered) builder;
  final MouseCursor? cursor;

  @override
  State<Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<Hoverable> {
  bool hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.cursor ?? MouseCursor.defer,
    onEnter: (_) => setState(() => hovered = true),
    onExit: (_) => setState(() => hovered = false),
    child: widget.builder(context, hovered),
  );
}

/// The Memlib app mark: a rounded purple tile with the mosaic glyph.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 28});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(size * .3),
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [MemlibColors.accent, MemlibColors.accentDeep],
      ),
      boxShadow: const [
        BoxShadow(color: Color(0x408B68FF), blurRadius: 12, offset: Offset(0, 3)),
      ],
    ),
    child: Icon(
      Icons.auto_awesome_mosaic_rounded,
      size: size * .58,
      color: MemlibColors.onAccent,
    ),
  );
}

class SegmentTab {
  const SegmentTab(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// A compact segmented control used for Library / GIPHY and GIFs / Stickers.
class SegmentedTabs extends StatelessWidget {
  const SegmentedTabs({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onChanged,
    this.height = 34,
    this.showIcons = true,
  });
  final List<SegmentTab> tabs;
  final int selected;
  final ValueChanged<int>? onChanged;
  final double height;
  final bool showIcons;

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: MemlibColors.high,
      borderRadius: BorderRadius.circular(MemlibRadius.control),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < tabs.length; i++)
          _SegmentButton(
            tab: tabs[i],
            active: i == selected,
            showIcon: showIcons,
            onTap: onChanged == null ? null : () => onChanged!(i),
          ),
      ],
    ),
  );
}

class _SegmentButton extends StatelessWidget {
  const _SegmentButton({
    required this.tab,
    required this.active,
    required this.showIcon,
    required this.onTap,
  });
  final SegmentTab tab;
  final bool active;
  final bool showIcon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? MemlibColors.text : MemlibColors.textMuted;
    return Material(
      color: active ? MemlibColors.highest : Colors.transparent,
      borderRadius: BorderRadius.circular(MemlibRadius.control - 3),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(MemlibRadius.control - 3),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showIcon) ...[
                Icon(
                  tab.icon,
                  size: 16,
                  color: active ? MemlibColors.accent : color,
                ),
                const SizedBox(width: 6),
              ],
              Text(
                tab.label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A rounded filter pill used for folders, favourites and GIPHY modes.
class FilterPill extends StatelessWidget {
  const FilterPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? MemlibColors.accent : MemlibColors.textMuted;
    return Material(
      color: selected ? MemlibColors.accentSoft : Colors.transparent,
      shape: StadiumBorder(
        side: BorderSide(
          color: selected ? MemlibColors.accentLine : MemlibColors.border,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: foreground),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected ? MemlibColors.accent : MemlibColors.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Uppercase section heading with an optional trailing action.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 10, 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              letterSpacing: 1.1,
              color: MemlibColors.textFaint,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    ),
  );
}

/// A keycap-style hint such as [Enter] Paste.
class KeyHint extends StatelessWidget {
  const KeyHint({super.key, required this.keys, required this.label});
  final List<String> keys;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final key in keys)
        Container(
          margin: const EdgeInsets.only(right: 3),
          constraints: const BoxConstraints(minWidth: 20),
          height: 20,
          padding: const EdgeInsets.symmetric(horizontal: 5),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: MemlibColors.high,
            borderRadius: BorderRadius.circular(5),
            border: const Border(
              bottom: BorderSide(color: MemlibColors.border, width: 2),
            ),
          ),
          child: Text(
            key,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: MemlibColors.textMuted,
            ),
          ),
        ),
      const SizedBox(width: 4),
      Text(
        label,
        style: const TextStyle(fontSize: 12, color: MemlibColors.textFaint),
      ),
    ],
  );
}

/// Small round icon button drawn over media tiles.
class TileAction extends StatelessWidget {
  const TileAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color = MemlibColors.text,
    this.size = 28,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: const Color(0xCC15121C),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(
            icon,
            size: size * .55,
            color: color,
          ),
        ),
      ),
    ),
  );
}
