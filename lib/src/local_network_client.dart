import 'dart:io';
import 'dart:async';

class LocalNetworkClient {
  static const int kLocalPort = 5005;
  static const int kPhonePort = 5006;

  Future<String> _readResponse(Socket socket) async {
    final data = await socket.first;
    return String.fromCharCodes(data);
  }

  /// Sends a command directly to the laptop over the local network.
  Future<bool> sendCommand(String ip, String command) async {
    try {
      final socket = await Socket.connect(
        ip,
        kLocalPort,
        timeout: const Duration(seconds: 2),
      );
      socket.writeln(command);
      await socket.flush();
      final response = await _readResponse(socket);
      await socket.close();
      return response.trim() == 'ok';
    } catch (e) {
      return false;
    }
  }

  /// Sends a file directly to the laptop over the local network.
  Future<bool> sendFile(String ip, File file) async {
    try {
      final socket = await Socket.connect(
        ip,
        kLocalPort,
        timeout: const Duration(seconds: 5),
      );

      final fileName = file.path.split(Platform.pathSeparator).last;
      final size = await file.length();
      socket.writeln('sendFile');
      socket.writeln('$fileName|$size');
      await socket.flush();

      final fileStream = file.openRead();
      await for (final chunk in fileStream) {
        socket.add(chunk);
      }

      await socket.flush();
      final response = await _readResponse(socket);
      await socket.close();
      return response.trim() == 'ok';
    } catch (e) {
      return false;
    }
  }

  /// Sends a file directly to the phone over the local network.
  Future<bool> sendFileToPhone(String ip, File file) async {
    try {
      final socket = await Socket.connect(
        ip,
        kPhonePort,
        timeout: const Duration(seconds: 5),
      );

      final fileName = file.path.split(Platform.pathSeparator).last;
      final size = await file.length();
      socket.writeln('sendFile');
      socket.writeln('$fileName|$size');
      await socket.flush();

      final fileStream = file.openRead();
      await for (final chunk in fileStream) {
        socket.add(chunk);
      }

      await socket.flush();
      final response = await _readResponse(socket);
      await socket.close();
      return response.trim() == 'ok';
    } catch (e) {
      return false;
    }
  }
}
