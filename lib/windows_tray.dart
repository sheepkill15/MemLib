import 'package:tray_manager/tray_manager.dart' as tray;

class WindowsTray {
  tray.TrayIcon? _icon;
  tray.Image? _image;
  tray.Menu? _menu;
  final _items = <tray.MenuItem>[];

  bool initialize({required void Function() openLibrary, required void Function() openPicker, required void Function() exitApp, required String shortcutLabel}) {
    final icon = tray.TrayIcon.create();
    if (icon == null) return false;
    final image = tray.ImageAsset.fromAsset('assets/tray_icon.ico');
    if (image == null) { icon.dispose(); return false; }
    final menu = tray.Menu.create();
    if (menu == null) { image.dispose(); icon.dispose(); return false; }

    _icon = icon;
    _image = image;
    _menu = menu;
    icon.icon = image;
    updateShortcutLabel(shortcutLabel);
    icon.addListener((event) {
      if (event is tray.TrayIconClickedEvent || event is tray.TrayIconDoubleClickedEvent) openLibrary();
    });

    void addAction(String label, void Function() callback) {
      final item = tray.MenuItem.createWithLabelAndType(label, tray.MenuItemType.normal);
      if (item == null) return;
      item.addListener((event) { if (event is tray.MenuItemClickedEvent) callback(); });
      _items.add(item);
      menu.addItem(item);
    }

    addAction('Open library', openLibrary);
    addAction('Quick picker', openPicker);
    menu.addSeparator();
    addAction('Exit Memlib', exitApp);
    icon.setContextMenu(menu);
    if (icon.setVisible(true)) return true;
    dispose();
    return false;
  }

  void updateShortcutLabel(String label) => _icon?.setTooltip('Memlib · $label for quick picker');

  void dispose() {
    _icon?.dispose();
    for (final item in _items) { item.dispose(); }
    _menu?.dispose();
    _image?.dispose();
  }
}
