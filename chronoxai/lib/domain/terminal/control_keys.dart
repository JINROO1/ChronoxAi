/// Byte sequences sent to the shell for terminal control keys.
abstract final class ControlKeys {
  static const int ctrlC = 0x03;
  static const int ctrlD = 0x04;
  static const int ctrlL = 0x0C;
  static const int tab = 0x09;
  static const List<int> arrowUp = <int>[0x1B, 0x5B, 0x41];
  static const List<int> arrowDown = <int>[0x1B, 0x5B, 0x42];
}
