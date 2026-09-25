import 'package:flutter_test/flutter_test.dart';
import 'package:memlib/picker_navigation.dart';

void main() {
  test('arrow navigation follows four-column grid and stops at edges', () {
    expect(movePickerSelection(1, 10, 4, PickerDirection.down), 5);
    expect(movePickerSelection(5, 10, 4, PickerDirection.up), 1);
    expect(movePickerSelection(9, 10, 4, PickerDirection.right), 9);
    expect(movePickerSelection(0, 10, 4, PickerDirection.left), 0);
    expect(movePickerSelection(7, 10, 4, PickerDirection.down), 9);
    expect(movePickerSelection(0, 0, 4, PickerDirection.down), -1);
  });
}
