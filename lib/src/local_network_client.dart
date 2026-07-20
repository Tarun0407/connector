import 'dart:io';
import 'dart:async';

class LocalNetworkClient {
  static const int kLocalPort = 5005;
  static const int kPhonePort = 5006;

  Future<String> _readResponse(Socket socket) async {
    final buffer = StringBuffer();
    await for (final data in socket) {
      buffer.write(String.fromCharCodes(data));
      final str = buffer.toString();
      final idx = str.indexOf('\n');
      if (idx >= 0) {
        return str.substring(0, idx);
      }
    }
    return buffer.toString();
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

  /// Probes whether a peer is reachable on the local network at [ip]:[port].
  Future<bool> probeConnectivity(
    String ip,
    int port, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      final socket = await Socket.connect(ip, port, timeout: timeout);
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Sends a file directly to the phone over the local network.
  Future<bool> sendFileToPhone(
    String ip,
    File file, {
    void Function(int sentBytes, int totalBytes)? onProgress,
  }) async {
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
      var sent = 0;
      await for (final chunk in fileStream) {
        socket.add(chunk);
        sent += chunk.length;
        onProgress?.call(sent, size);
      }

      await socket.flush();
      final response = await _readResponse(
        socket,
      ).timeout(const Duration(seconds: 20));
      await socket.close();
      return response.trim() == 'ok';
    } catch (e) {
      return false;
    }
  }
}
