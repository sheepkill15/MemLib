# Memlib interface

Memlib uses a compact media workspace across the Windows and Android library, Windows quick picker, Android keyboard, and website. It keeps the original purple brand and launcher icon. Navigation and search stay close to the content; media occupies the remaining space.

## Color

| Role | Value |
| --- | --- |
| Canvas | `#121019` |
| Surface | `#1B1724` |
| Raised controls | `#24202E` |
| Borders | `#514462` |
| Primary action and selection | `#BDA7FF` |
| Secondary highlight | `#C9B8FF` |
| Text | `#FFFFFF` |
| Muted text | `#B8B2C4` |

The website uses the original light background with the same purple accent and compact component shapes.

## Layout

- Use 8 px spacing between media cards and 9–10 px corner radii on controls and cards.
- Keep the primary navigation inline with the title when space permits, and put it in one compact row below on narrow screens.
- Use a 208 px folder rail on wide library windows. Narrow layouts use horizontal folder chips.
- Media grids use square or near-square cards. Actions sit on the card, with one compact label row below the preview.
- Selection actions float above the grid so selecting items does not move the grid.
- The native keyboard follows the same colors, card shapes, and compact navigation while keeping its existing send and search behavior.
