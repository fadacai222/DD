final class ClientLog {
  const ClientLog._();

  static String? get path => null;

  static Future<void> info(String message) async {}

  static Future<void> error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) async {}
}
