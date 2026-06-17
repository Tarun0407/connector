import 'dart:io';
import 'dart:async';

class LocalNetworkClient {
  static const int kLocalPort = 5005;

  /// Sends a command directly to the laptop over the local network.
  /// Returns true if the command was delivered successfully.
  Future<bool> sendCommand(String ip, String command) async {
    try {
      // We use a short timeout so the app doesn't freeze if the laptop is offline
      final socket = await Socket.connect(
        ip,
        kLocalPort,
        timeout: const Duration(seconds: 2),
      );
      socket.write(command);
      await socket.flush();
      await socket.close();
      return true;
    } catch (e) {
      // Local connection failed, we'll fallback to cloud
      return false;
    }
  }
}
