import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      case TargetPlatform.windows:
        return windows;
      case TargetPlatform.linux:
        return linux;
      case TargetPlatform.fuchsia:
        return android;
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyAYvzvwABfA7FyblLa4eFJm9yeQL3-FryA',
    appId: '1:32460862306:web:8b32c068ae0d1105b7723b',
    messagingSenderId: '32460862306',
    projectId: 'connector-3ea8a',
    authDomain: 'connector-3ea8a.firebaseapp.com',
    databaseURL: 'https://connector-3ea8a-default-rtdb.firebaseio.com',
    storageBucket: 'connector-3ea8a.firebasestorage.app',
    measurementId: 'G-QP5CGSMC8Y',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyDOBJDzqE0Yp-f33CWZBPwA2Auc07hCT4c',
    appId: '1:32460862306:android:8bc81a185af964f0b7723b',
    messagingSenderId: '32460862306',
    projectId: 'connector-3ea8a',
    databaseURL: 'https://connector-3ea8a-default-rtdb.firebaseio.com',
    storageBucket: 'connector-3ea8a.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyAYvzvwABfA7FyblLa4eFJm9yeQL3-FryA',
    appId: '1:32460862306:web:8b32c068ae0d1105b7723b',
    messagingSenderId: '32460862306',
    projectId: 'connector-3ea8a',
    authDomain: 'connector-3ea8a.firebaseapp.com',
    databaseURL: 'https://connector-3ea8a-default-rtdb.firebaseio.com',
    storageBucket: 'connector-3ea8a.firebasestorage.app',
    iosBundleId: 'com.example.connector',
  );

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'AIzaSyAYvzvwABfA7FyblLa4eFJm9yeQL3-FryA',
    appId: '1:32460862306:web:8b32c068ae0d1105b7723b',
    messagingSenderId: '32460862306',
    projectId: 'connector-3ea8a',
    authDomain: 'connector-3ea8a.firebaseapp.com',
    databaseURL: 'https://connector-3ea8a-default-rtdb.firebaseio.com',
    storageBucket: 'connector-3ea8a.firebasestorage.app',
    iosBundleId: 'com.example.connector',
  );

  static const FirebaseOptions windows = FirebaseOptions(
    apiKey: 'AIzaSyAYvzvwABfA7FyblLa4eFJm9yeQL3-FryA',
    appId: '1:32460862306:web:8b32c068ae0d1105b7723b',
    messagingSenderId: '32460862306',
    projectId: 'connector-3ea8a',
    authDomain: 'connector-3ea8a.firebaseapp.com',
    databaseURL: 'https://connector-3ea8a-default-rtdb.firebaseio.com',
    storageBucket: 'connector-3ea8a.firebasestorage.app',
    measurementId: 'G-QP5CGSMC8Y',
  );

  static const FirebaseOptions linux = FirebaseOptions(
    apiKey: 'AIzaSyAYvzvwABfA7FyblLa4eFJm9yeQL3-FryA',
    appId: '1:32460862306:web:8b32c068ae0d1105b7723b',
    messagingSenderId: '32460862306',
    projectId: 'connector-3ea8a',
    authDomain: 'connector-3ea8a.firebaseapp.com',
    databaseURL: 'https://connector-3ea8a-default-rtdb.firebaseio.com',
    storageBucket: 'connector-3ea8a.firebasestorage.app',
    measurementId: 'G-QP5CGSMC8Y',
  );
}
