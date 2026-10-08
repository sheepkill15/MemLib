# Memlib interface

Memlib is a dark, media-first workspace. The same system covers the Windows and Android library, the Windows quick picker, the Android keyboard and the website. Media carries the colour; the chrome stays quiet, borders are hairlines, and purple marks only what is active or primary.

Tokens live in [`lib/theme.dart`](../lib/theme.dart) (`MemlibColors`, `MemlibRadius`, `buildMemlibTheme()`). The Kotlin keyboard (`MemlibKeyboardService.kt`) and `website/style.css` copy the same values, so change all three together.

## Color

| Token | Value | Use |
| --- | --- | --- |
| `canvas` | `#0E0C13` | Window, app bar, picker background |
| `surface` | `#15121C` | Sidebar, footers, bottom navigation |
| `raised` | `#1C1825` | Media tiles, dialogs |
| `high` | `#252031` | Inputs, segmented controls, menus, keyboard keys |
| `highest` | `#2F2940` | Active segment, snackbars, modifier keys |
| `hairline` | `#231E2C` | Dividers and resting tile borders |
| `border` | `#342D42` | Hovered tiles, outlined buttons, pills |
| `accent` | `#BDA7FF` | Primary buttons, selection rings, active text |
| `accentDeep` | `#8B68FF` | Brand mark gradient end |
| `accentSoft` | `#BDA7FF` at 18% | Selected nav rows and pills |
| `text` / `textMuted` / `textFaint` | `#F3F1F7` / `#A8A2B6` / `#6F6980` | Three levels of text |
| `danger` | `#FF8F87` | Delete, sync errors |
| `star` | `#FFC857` | Favourites |

## Shape and spacing

- Radii: 8 for small controls, 10 for buttons and inputs, 14 for media tiles, 18 for dialogs.
- The library grid uses 16 px outer padding, 12 px gaps, tiles up to 168 px wide, and a 0.86 aspect ratio. The name and tags sit under the tile, not inside it.
- The quick picker uses 12 px padding, 8 px gaps and four square columns, with the name inside the tile.
- If you change grid constants (`_gridPad`, `_gridGap`, `_gridExtent`, `_gridAspect`, `_pickerPad`, `_pickerGap`), check `_selectItemAt` and `_scrollPickerSelectionIntoView`. Both compute from these values.

## Vertical space: compact, not cramped

Vertical screen space is the scarce resource, especially with the Android keyboard or a small desktop window. Prioritize **fewer stacked toolbars** over shrinking every hit target.

- At desktop widths of 1040 px and above, title, result count and search/tag controls share one row. Below that, they stack to keep both the title and search usable.
- Keep an 8–12 px rhythm between controls, and 12 px between grid tiles. Remove redundant *rows* and oversized top/bottom gutters before reducing media whitespace.
- The app bar is 52 px; Android bottom navigation is 60 px. Search and primary actions remain approximately 40 px tall.
- Never compact the selection bar, folder actions or tooltips so far that their hit targets overlap. Hidden actions must not intercept taps.
- Prefer short context-driven empty-state text and a single obvious recovery action. Keep supplementary help within the empty state rather than consuming another persistent strip.
- When modifying these values, test 320 px mobile, a sub-1040 px desktop window, the default 1050 × 720 desktop window, and the 620 × 540 quick picker.

## Components

- **Brand mark:** a rounded purple gradient square with the mosaic glyph, next to the "Memlib" wordmark.
- **Segmented tabs:** used for Library / GIPHY and GIFs / Stickers. They sit inline in the app bar on wide windows. Phones use a bottom `NavigationBar` instead.
- **Sidebar (wide windows):** 232 px wide, with All items and Favourites (with counts), a Folders section, and collapsible folder rows. Folder menus appear on hover.
- **Filter pills:** used for folders on narrow layouts, in the picker and in the keyboard. Selected pills get the accent tint.
- **Media tiles:** quiet at rest. Checkbox, favourite and preview controls fade in on hover. On touch they stay visible. Favourited items always show an amber star. Selected tiles get a 2 px accent ring.
- **Folder tiles:** a 2×2 mosaic of the folder's first items, or a folder glyph when the folder is empty.
- **Selection toolbar:** floats above the grid, so selecting never shifts the layout.
- **Quick picker footer:** keycap hints (↑ ↓ ← → Move, Enter Paste, Esc Close).
- **Dialogs and menus:** raised surface with a 1 px border. Menu rows have leading icons. Destructive actions use `danger`.
