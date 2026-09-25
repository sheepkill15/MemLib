enum PickerDirection { left, right, up, down }

int movePickerSelection(int current, int count, int columns, PickerDirection direction) {
  if (count == 0) return -1;
  final index = current.clamp(0, count - 1);
  return switch (direction) {
    PickerDirection.left => (index - 1).clamp(0, count - 1),
    PickerDirection.right => (index + 1).clamp(0, count - 1),
    PickerDirection.up => (index - columns).clamp(0, count - 1),
    PickerDirection.down => (index + columns).clamp(0, count - 1),
  };
}
