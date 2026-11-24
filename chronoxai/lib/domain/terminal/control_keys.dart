/// Byte sequences sent to the shell for terminal control keys.
abstract final class ControlKeys {
  static const int ctrlC = 0x03;
  static const int ctrlD = 0x04;
  static const int ctrlA = 0x01;
  static const int ctrlE = 0x05;
  static const int ctrlK = 0x0B;
  static const int ctrlU = 0x15;
  static const int ctrlW = 0x17;
  static const int ctrlL = 0x0C;
  static const int tab = 0x09;
  static const int escape = 0x1B;
  static const List<int> arrowUp = <int>[0x1B, 0x5B, 0x41];
  static const List<int> arrowDown = <int>[0x1B, 0x5B, 0x42];
  static const List<int> arrowRight = <int>[0x1B, 0x5B, 0x43];
  static const List<int> arrowLeft = <int>[0x1B, 0x5B, 0x44];
  static const List<int> home = <int>[0x1B, 0x5B, 0x48];
  static const List<int> end = <int>[0x1B, 0x5B, 0x46];
  static const List<int> pageUp = <int>[0x1B, 0x5B, 0x35, 0x7E];
  static const List<int> pageDown = <int>[0x1B, 0x5B, 0x36, 0x7E];
}
