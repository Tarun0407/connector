# Connector

Connector is a Flutter app for controlling a paired laptop and phone through
Firebase. It uses one codebase:

- Desktop builds show phone controls: locate/ring, stop ringing, lock, and
  request Android Device Admin.
- Mobile builds show laptop controls: play/pause media, volume, mute, lock,
  visible windows, device status, and activity logs.

The current native implementation targets Windows laptops and Android phones.
Other platforms keep the Flutter UI and Firebase sync layer, but unsupported
native commands are no-ops until platform channels are added.

## Firebase Needed

Create or provide a Firebase project with:

- Authentication: enable Anonymous sign-in.
- Cloud Firestore: create a database.
- FlutterFire config: run `flutterfire configure` for Android and Windows, then
  replace `lib/firebase_options.dart`.
- Android app id: `com.example.connector`, unless you rename the app package.

Starter Firestore rules for a personal build:

```js
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    function signedIn() {
      return request.auth != null;
    }

    function validRoom(roomId) {
      return roomId.matches('^[A-Z0-9]{8,24}$');
    }

    match /pairingRooms/{roomId} {
      allow get, create, update: if signedIn() && validRoom(roomId);
      allow list, delete: if false;

      match /{document=**} {
        allow get, list, create, update: if signedIn() && validRoom(roomId);
        allow delete: if false;
      }
    }
  }
}
```

This uses an unguessable pairing code as the shared room key and blocks listing
rooms. For a public release, replace this with email sign-in or a Cloud
Functions pairing flow that stores explicit members.

## Data Shape

The app writes to:

- `pairingRooms/{roomCode}/devices/{deviceId}` for presence, volume, window
  snapshots, and phone admin status.
- `pairingRooms/{roomCode}/commands/{commandId}` for queued remote commands.
- `pairingRooms/{roomCode}/events/{eventId}` for command and window logs.

## Important Platform Notes

- Android lock requires the user to enable Device Admin inside the phone app.
- Android locate uses the alarm audio stream and temporarily raises alarm
  volume, so it can ring even when the phone is silent or vibrating.
- Firestore listeners work when the app process is alive. For fully reliable
  background wake-up, add Firebase Cloud Messaging and a small Cloud Function
  that sends a data push whenever a command is created.
- iOS does not allow normal third-party apps to force device lock or override
  silent mode for this use case.
