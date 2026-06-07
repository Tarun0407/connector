import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/connector_app.dart';
import 'src/connector_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  _ignoreStaleHardwareKeyboardStateError();
  runApp(ConnectorApp(controller: ConnectorController()));
}

void _ignoreStaleHardwareKeyboardStateError() {
  final previousOnError = FlutterError.onError;

  FlutterError.onError = (details) {
    if (_isStaleHardwareKeyboardStateError(details)) {
      unawaited(HardwareKeyboard.instance.syncKeyboardState());
      return;
    }

    if (previousOnError != null) {
      previousOnError(details);
    } else {
      FlutterError.presentError(details);
    }
  };
}

bool _isStaleHardwareKeyboardStateError(FlutterErrorDetails details) {
  if (!kDebugMode || details.library != 'services library') {
    return false;
  }

  final error = details.exceptionAsString();
  return error.contains('A KeyDownEvent is dispatched') &&
      error.contains('physical key is already pressed') &&
      error.contains('hardware_keyboard.dart');
}
