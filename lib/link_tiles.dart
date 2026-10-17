import 'package:flutter/material.dart';

import 'library_store.dart';

/// What a provider tile (a KLIPY result or a Pinterest pin) gets from the
/// library window, so it behaves like a library item: bulk selection,
/// dragging onto folders, and the item menu.
abstract class LinkTileHost {
  bool isSelected(MediaLink link);

  /// Whether any provider tile is selected.
  bool get selecting;

  /// Toggles [link], or extends the selection over [order] with Shift.
  void select(MediaLink link, List<MediaLink> order, {bool checkbox = false});

  /// Runs [open] unless a selection is active or a modifier key is held, in
  /// which case the tap selects instead.
  void tap(MediaLink link, List<MediaLink> order, VoidCallback open);

  Widget menu(MediaLink link);

  /// Makes the tile draggable onto folders (desktop) or long-press
  /// selectable (Android).
  Widget wrap(MediaLink link, List<MediaLink> order, Widget tile);
}

/// The selection checkbox in a tile's top-left corner, as on library cards.
class LinkCheckbox extends StatelessWidget {
  const LinkCheckbox({
    super.key,
    required this.host,
    required this.link,
    required this.order,
    required this.visible,
  });

  final LinkTileHost host;
  final MediaLink link;
  final List<MediaLink> order;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    final checked = host.isSelected(link);
    // Like library cards, the checkbox is always there, dimmed at rest.
    final emphasized = visible || checked || host.selecting;
    return AnimatedOpacity(
      opacity: emphasized ? 1 : .55,
      duration: const Duration(milliseconds: 120),
      child: SizedBox(
        width: 30,
        height: 30,
        child: Checkbox(
          key: ValueKey('select-link-${link.sourceType}-${link.sourceId}'),
          value: checked,
          onChanged: (_) => host.select(link, order, checkbox: true),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }
}
