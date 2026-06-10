package com.example.connector

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.KeyguardManager
import android.app.admin.DevicePolicyManager
import android.hardware.biometrics.BiometricPrompt
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.media.MediaMetadata
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.CancellationSignal
import android.os.SystemClock
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var mediaPlayer: MediaPlayer? = null
    private var previousAlarmVolume: Int? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var laptopMediaSession: MediaSession? = null
    private var pendingRemoteUnlockAuthResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "ringPhone" -> result.success(ringPhone())
                "stopRingPhone" -> result.success(stopRingPhone())
                "lockPhone" -> result.success(lockPhone())
                "requestDeviceAdmin" -> result.success(requestDeviceAdmin())
                "isDeviceAdmin" -> result.success(isDeviceAdminActive())
                "requestPostNotifications" -> result.success(requestPostNotifications())
                "canPostNotifications" -> result.success(canPostNotifications())
                "openNotificationAccessSettings" -> result.success(openNotificationAccessSettings())
                "isNotificationAccessEnabled" -> result.success(isNotificationAccessEnabled())
                "showLaptopMediaNotification" -> {
                    val media = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
                    result.success(showLaptopMediaNotification(media))
                }
                "cancelLaptopMediaNotification" -> result.success(cancelLaptopMediaNotification())
                "setAutoStart" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    result.success(setAutoStart(enabled))
                }
                "isAutoStartEnabled" -> result.success(isAutoStartEnabled())
                "openAutoStartSettings" -> result.success(openAutoStartSettings())
                "authenticateForRemoteUnlock" -> authenticateForRemoteUnlock(result)
                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("Deprecated in Android API 35, still used for older credential confirmation flow.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REMOTE_UNLOCK_AUTH_REQUEST) {
            pendingRemoteUnlockAuthResult?.success(resultCode == RESULT_OK)
            pendingRemoteUnlockAuthResult = null
        }
    }

    private fun ringPhone(): Boolean {
        stopRingPhone()

        val alarmUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            ?: return false
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        previousAlarmVolume = audioManager.getStreamVolume(AudioManager.STREAM_ALARM)
        audioManager.setStreamVolume(
            AudioManager.STREAM_ALARM,
            audioManager.getStreamMaxVolume(AudioManager.STREAM_ALARM),
            0
        )

        acquireWakeLock()

        mediaPlayer = MediaPlayer().apply {
            setDataSource(applicationContext, alarmUri)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
            } else {
                @Suppress("DEPRECATION")
                setAudioStreamType(AudioManager.STREAM_ALARM)
            }
            isLooping = true
            prepare()
            start()
        }
        return true
    }

    private fun openNotificationAccessSettings(): Boolean {
        startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
        return true
    }

    private fun requestPostNotifications(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return true
        }
        if (canPostNotifications()) {
            return true
        }
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), POST_NOTIFICATIONS_REQUEST)
        return false
    }

    private fun canPostNotifications(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
    }

    private fun isNotificationAccessEnabled(): Boolean {
        val flat = Settings.Secure.getString(contentResolver, "enabled_notification_listeners")
        return flat?.contains(packageName) == true
    }

    private fun authenticateForRemoteUnlock(result: MethodChannel.Result) {
        val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        if (!keyguardManager.isDeviceSecure) {
            android.util.Log.d("Connector", "Unlock failed: Device is not secure (no PIN/Fingerprint)")
            result.success(false)
            return
        }
        if (pendingRemoteUnlockAuthResult != null) {
            result.success(false)
            return
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            val intent = keyguardManager.createConfirmDeviceCredentialIntent(
                "Unlock laptop",
                "Confirm your phone PIN, pattern, or password."
            )
            if (intent == null) {
                result.success(false)
                return
            }
            pendingRemoteUnlockAuthResult = result
            startActivityForResult(intent, REMOTE_UNLOCK_AUTH_REQUEST)
            return
        }

        pendingRemoteUnlockAuthResult = result
        val cancellationSignal = CancellationSignal()
        val builder = BiometricPrompt.Builder(this)
            .setTitle("Unlock laptop")
            .setSubtitle("Confirm this is you before Connector sends the unlock command")
            

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setAllowedAuthenticators(BIOMETRIC_STRONG or DEVICE_CREDENTIAL)
        } else {
            @Suppress("DEPRECATION")
            builder.setDeviceCredentialAllowed(true)
        }

        try {
        builder.build().authenticate(
            cancellationSignal,
            ContextCompat.getMainExecutor(this),
            object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(authResult: BiometricPrompt.AuthenticationResult) {
                    pendingRemoteUnlockAuthResult?.success(true)
                        pendingRemoteUnlockAuthResult = null
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                        android.util.Log.e("Connector", "Biometric Error: $errorCode - $errString")
                    pendingRemoteUnlockAuthResult?.success(false)
                    pendingRemoteUnlockAuthResult = null
                }

                override fun onAuthenticationFailed() {
                        // Keep the prompt open
                }
            }
        )
        } catch (e: Exception) {
            android.util.Log.e("Connector", "Biometric Prompt Exception: ${e.message}")
            result.success(false)
            pendingRemoteUnlockAuthResult = null
    }
    }

    private fun showLaptopMediaNotification(media: Map<*, *>): Boolean {
        if (!canPostNotifications()) {
            requestPostNotifications()
            return false
        }

        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                MEDIA_CHANNEL_ID,
                "Laptop media",
                NotificationManager.IMPORTANCE_DEFAULT
            )
            manager.createNotificationChannel(channel)
        }

        val state = LaptopMediaState.fromMap(media)
        updateLaptopMediaSession(state)
        manager.notify(LAPTOP_MEDIA_NOTIFICATION_ID, buildLaptopMediaNotification(state))
        return true
    }

    private fun cancelLaptopMediaNotification(): Boolean {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(LAPTOP_MEDIA_NOTIFICATION_ID)
        laptopMediaSession?.isActive = false
        return true
    }

    private fun buildLaptopMediaNotification(state: LaptopMediaState): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, MEDIA_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val playPauseIcon = if (state.isPlaying) {
            android.R.drawable.ic_media_pause
        } else {
            android.R.drawable.ic_media_play
        }
        val playPauseTitle = if (state.isPlaying) "Pause" else "Play"

        return builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(state.title.ifBlank { "Laptop media" })
            .setContentText(state.artist.ifBlank { state.sourceApp.ifBlank { "Control playback on your laptop" } })
            .setContentIntent(contentIntent)
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setProgress(
                state.durationMs.coerceAtLeast(0).toInt(),
                state.positionMs.coerceAtLeast(0).toInt(),
                state.durationMs <= 0
            )
            .setStyle(
                Notification.MediaStyle()
                    .setMediaSession(laptopMediaSession?.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2)
            )
            .addAction(
                Notification.Action.Builder(
                    android.R.drawable.ic_media_previous,
                    "Previous",
                    mediaActionIntent("previous", 1)
                ).build()
            )
            .addAction(
                Notification.Action.Builder(
                    playPauseIcon,
                    playPauseTitle,
                    mediaActionIntent("toggle", 2)
                ).build()
            )
            .addAction(
                Notification.Action.Builder(
                    android.R.drawable.ic_media_next,
                    "Next",
                    mediaActionIntent("next", 3)
                ).build()
            )
            .build()
    }

    private fun updateLaptopMediaSession(state: LaptopMediaState) {
        val session = laptopMediaSession ?: MediaSession(this, "ConnectorLaptopMedia").also {
            laptopMediaSession = it
        }

        session.setCallback(object : MediaSession.Callback() {
            override fun onSeekTo(pos: Long) {
                sendLaptopMediaAction(mapOf("action" to "seek", "positionMs" to pos))
            }

            override fun onPlay() {
                sendLaptopMediaAction(mapOf("action" to "toggle"))
            }

            override fun onPause() {
                sendLaptopMediaAction(mapOf("action" to "toggle"))
            }

            override fun onSkipToNext() {
                sendLaptopMediaAction(mapOf("action" to "next"))
            }

            override fun onSkipToPrevious() {
                sendLaptopMediaAction(mapOf("action" to "previous"))
            }
        })

        val playbackState = PlaybackState.Builder()
            .setActions(
                PlaybackState.ACTION_PLAY_PAUSE or
                    PlaybackState.ACTION_PLAY or
                    PlaybackState.ACTION_PAUSE or
                    PlaybackState.ACTION_SKIP_TO_NEXT or
                    PlaybackState.ACTION_SKIP_TO_PREVIOUS or
                    PlaybackState.ACTION_SEEK_TO
            )
            .setState(
                if (state.isPlaying) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                state.positionMs,
                if (state.isPlaying) 1.0f else 0.0f,
                SystemClock.elapsedRealtime()
            )
            .build()

        val metadata = MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, state.title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, state.artist)
            .putString(MediaMetadata.METADATA_KEY_ALBUM, state.album)
            .putLong(MediaMetadata.METADATA_KEY_DURATION, state.durationMs)
            .build()

        session.setMetadata(metadata)
        session.setPlaybackState(playbackState)
        session.isActive = true
    }

    private fun mediaActionIntent(action: String, requestCode: Int): PendingIntent {
        val intent = Intent(this, ConnectorMediaActionReceiver::class.java).apply {
            putExtra(ConnectorMediaActionReceiver.EXTRA_ACTION, action)
        }
        return PendingIntent.getBroadcast(
            this,
            requestCode,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
    }

    private fun stopRingPhone(restoreVolume: Boolean = true): Boolean {
        mediaPlayer?.let { player ->
            runCatching {
                if (player.isPlaying) {
                    player.stop()
                }
            }
            player.release()
        }
        mediaPlayer = null

        if (restoreVolume) {
            previousAlarmVolume?.let { previous ->
                val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                audioManager.setStreamVolume(AudioManager.STREAM_ALARM, previous, 0)
            }
        }
        previousAlarmVolume = null

        wakeLock?.let { lock ->
            if (lock.isHeld) {
                lock.release()
            }
        }
        wakeLock = null
        return true
    }

    private fun lockPhone(): Boolean {
        val devicePolicyManager =
            getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        val admin = adminComponent()
        if (!devicePolicyManager.isAdminActive(admin)) {
            return false
        }
        devicePolicyManager.lockNow()
        return true
    }

    private fun requestDeviceAdmin(): Boolean {
        val intent = Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN).apply {
            putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, adminComponent())
            putExtra(
                DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                "Connector uses this permission only for the remote Lock command."
            )
        }
        startActivity(intent)
        return true
    }

    private fun isDeviceAdminActive(): Boolean {
        val devicePolicyManager =
            getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        return devicePolicyManager.isAdminActive(adminComponent())
    }

    private fun setAutoStart(enabled: Boolean): Boolean {
        if (enabled && !canPostNotifications()) {
            requestPostNotifications()
            return false
        }
        getSharedPreferences("connector", Context.MODE_PRIVATE)
            .edit()
            .putBoolean("autoStartEnabled", enabled)
            .apply()
        val serviceIntent = Intent(this, ConnectorForegroundService::class.java)
        if (enabled) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(serviceIntent)
            } else {
                startService(serviceIntent)
            }
        } else {
            stopService(serviceIntent)
        }
        return enabled
    }

    private fun isAutoStartEnabled(): Boolean {
        return getSharedPreferences("connector", Context.MODE_PRIVATE)
            .getBoolean("autoStartEnabled", false)
    }

    private fun openAutoStartSettings(): Boolean {
        val candidates = listOf(
            Intent().setComponent(ComponentName(
                "com.miui.securitycenter",
                "com.miui.permcenter.autostart.AutoStartManagementActivity"
            )),
            Intent().setComponent(ComponentName(
                "com.coloros.safecenter",
                "com.coloros.safecenter.permission.startup.StartupAppListActivity"
            )),
            Intent().setComponent(ComponentName(
                "com.vivo.permissionmanager",
                "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"
            )),
            Intent().setComponent(ComponentName(
                "com.huawei.systemmanager",
                "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"
            )),
            Intent().setComponent(ComponentName(
                "com.asus.mobilemanager",
                "com.asus.mobilemanager.entry.FunctionActivity"
            )),
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:$packageName")
            }
        )

        for (intent in candidates) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (intent.resolveActivity(packageManager) != null) {
                startActivity(intent)
                return true
            }
        }
        return false
    }

    private fun adminComponent(): ComponentName {
        return ComponentName(this, ConnectorDeviceAdminReceiver::class.java)
    }

    private fun acquireWakeLock() {
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "connector:phone-ring"
        ).apply {
            acquire(10 * 60 * 1000L)
        }
    }

    companion object {
        private const val CHANNEL = "connector/platform"
        private const val POST_NOTIFICATIONS_REQUEST = 1209
        private const val REMOTE_UNLOCK_AUTH_REQUEST = 1211
        private const val MEDIA_CHANNEL_ID = "connector_laptop_media_v2"
        private const val LAPTOP_MEDIA_NOTIFICATION_ID = 1210
        private const val BIOMETRIC_STRONG = 0x000F
        private const val DEVICE_CREDENTIAL = 0x8000
        private var methodChannel: MethodChannel? = null

        fun sendPhoneNotification(data: Map<String, Any>) {
            methodChannel?.invokeMethod("phoneNotification", data)
        }

        fun sendLaptopMediaAction(action: Map<String, Any>) {
            methodChannel?.invokeMethod("laptopMediaAction", action)
        }
    }

    data class LaptopMediaState(
        val title: String,
        val artist: String,
        val album: String,
        val sourceApp: String,
        val isPlaying: Boolean,
        val positionMs: Long,
        val durationMs: Long
    ) {
        companion object {
            fun fromMap(data: Map<*, *>): LaptopMediaState {
                return LaptopMediaState(
                    title = data["title"]?.toString().orEmpty(),
                    artist = data["artist"]?.toString().orEmpty(),
                    album = data["album"]?.toString().orEmpty(),
                    sourceApp = data["sourceApp"]?.toString().orEmpty(),
                    isPlaying = data["isPlaying"] == true,
                    positionMs = (data["positionMs"] as? Number)?.toLong() ?: 0L,
                    durationMs = (data["durationMs"] as? Number)?.toLong() ?: 0L
                )
            }
        }
    }
}

