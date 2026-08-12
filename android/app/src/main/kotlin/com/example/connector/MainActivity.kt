package com.example.connector

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.app.KeyguardManager
import android.app.admin.DevicePolicyManager
import android.hardware.biometrics.BiometricPrompt
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
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
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.ConcurrentHashMap

class MainActivity : FlutterActivity() {
    private var mediaPlayer: MediaPlayer? = null
    private var previousAlarmVolume: Int? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var laptopMediaSession: MediaSession? = null
    private var lastLaptopMediaState: LaptopMediaState? = null
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
                "exitApp" -> {
                    val stopIntent = Intent(this, ConnectorForegroundService::class.java)
                    stopIntent.action = "com.example.connector.STOP_FOREGROUND"
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(stopIntent)
                    } else {
                        startService(stopIntent)
                    }
                    result.success(true)
                }
                "openFile" -> {
                    val path = call.argument<String>("path") ?: ""
                    if (path.isNotEmpty()) {
                        try {
                            val file = java.io.File(path)
                            val uri = androidx.core.content.FileProvider.getUriForFile(
                                this,
                                "$packageName.fileprovider",
                                file
                            )
                            val mime = java.net.URLConnection.guessContentTypeFromName(path) ?: "*/*"
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, mime)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            if (intent.resolveActivity(packageManager) != null) {
                                startActivity(intent)
                            }
                        } catch (_: Exception) {}
                    }
                    result.success(true)
                }
                "showTransferNotification" -> {
                    val title = call.argument<String>("title") ?: ""
                    val fileName = call.argument<String>("fileName") ?: ""
                    val progress = call.argument<Double>("progress") ?: 0.0
                    result.success(showTransferNotification(title, fileName, progress))
                }
                "showSystemNotification" -> {
                    val title = call.argument<String>("title") ?: "Connector"
                    val body = call.argument<String>("body") ?: ""
                    result.success(showSystemNotification(title, body))
                }
                "sendNotificationReply" -> {
                    val replyCommandId = call.argument<String>("replyCommandId") ?: ""
                    val text = call.argument<String>("text") ?: ""
                    result.success(sendNotificationReply(replyCommandId, text))
                }
                "cancelTransferNotification" -> {
                    result.success(cancelTransferNotification())
                }
                "startForegroundService" -> {
                    val intent = Intent(this, ConnectorForegroundService::class.java)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(true)
                }
                "updateForegroundStatus" -> {
                    val title = call.argument<String>("title") ?: "Connector"
                    val text = call.argument<String>("text") ?: ""
                    ConnectorForegroundService.updateStatus(this, title, text)
                    result.success(true)
                }
                "showDisconnectedNotification" -> {
                    showDisconnectedNotification()
                    result.success(true)
                }
                "clearDisconnectedNotification" -> {
                    clearDisconnectedNotification()
                    result.success(true)
                }
                "listInstalledApps" -> result.success(listInstalledApps())
                "exportAppIcon" -> {
                    val packageName = call.argument<String>("package") ?: ""
                    result.success(exportAppIcon(packageName))
                }
                "getAppIconPath" -> {
                    val packageName = call.argument<String>("package") ?: ""
                    result.success(getAppIconPath(packageName))
                }
                else -> result.notImplemented()
            }
        }
        flushPendingPhoneNotifications()
        handleShareIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShareIntent(intent)
    }

    private fun handleShareIntent(intent: Intent) {
        val paths = mutableListOf<String>()
        when (intent.action) {
            Intent.ACTION_SEND -> {
                val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                if (uri != null) {
                    val path = copyShareToCache(uri)
                    if (path != null) paths.add(path)
                }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val uris = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                if (uris != null) {
                    paths.addAll(uris.mapNotNull { copyShareToCache(it) })
                }
            }
        }
        if (paths.isEmpty()) return

        if (paths.size == 1) {
            methodChannel?.invokeMethod("incomingShare", mapOf("path" to paths[0]))
        } else {
            methodChannel?.invokeMethod("incomingShare", mapOf("paths" to paths))
        }
    }

    private fun copyShareToCache(uri: Uri): String? {
        return try {
            val fileName = getFileName(uri) ?: "shared_${System.currentTimeMillis()}"
            val cacheFile = java.io.File(cacheDir, "shares/$fileName")
            cacheFile.parentFile?.mkdirs()
            contentResolver.openInputStream(uri)?.use { input ->
                cacheFile.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
            cacheFile.absolutePath
        } catch (_: Exception) { null }
    }

    private fun getFileName(uri: Uri): String? {
        val cursor = contentResolver.query(uri, null, null, null, null)
        return cursor?.use {
            val nameIndex = it.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
            if (nameIndex >= 0 && it.moveToFirst()) it.getString(nameIndex) else null
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

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == POST_NOTIFICATIONS_REQUEST) {
            methodChannel?.invokeMethod("postNotificationsResult", grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED)
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

        val incomingState = LaptopMediaState.fromMap(media)
        val previousState = lastLaptopMediaState
        val state = incomingState.smoothedAgainst(previousState)

        updateLaptopMediaSession(state)
        lastLaptopMediaState = state
        manager.notify(LAPTOP_MEDIA_NOTIFICATION_ID, buildLaptopMediaNotification(state))
        return true
    }

    private fun cancelLaptopMediaNotification(): Boolean {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(LAPTOP_MEDIA_NOTIFICATION_ID)
        laptopMediaSession?.isActive = false
        lastLaptopMediaState = null
        return true
    }

    private fun showTransferNotification(title: String, fileName: String, progress: Double): Boolean {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                TRANSFER_CHANNEL_ID,
                "File transfers",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                enableVibration(false)
            }
            manager.createNotificationChannel(channel)
        }
        val max = 100
        val current = (progress * max).toInt()
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, TRANSFER_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setContentTitle(title)
            .setContentText(fileName)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setProgress(max, current, false)
            .setOngoing(progress > 0.0 && progress < 1.0)
            .setOnlyAlertOnce(true)
        manager.notify(FILE_TRANSFER_NOTIFICATION_ID, builder.build())
        return true
    }

    private fun cancelTransferNotification(): Boolean {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(FILE_TRANSFER_NOTIFICATION_ID)
        return true
    }

    private fun showSystemNotification(title: String, body: String): Boolean {
        if (!canPostNotifications()) return false
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                SYSTEM_CHANNEL_ID,
                "System messages",
                NotificationManager.IMPORTANCE_DEFAULT
            )
            manager.createNotificationChannel(channel)
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, SYSTEM_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(applicationInfo.icon)
            .setAutoCancel(true)
            .build()
        manager.notify(SYSTEM_NOTIFICATION_ID, notification)
        return true
    }

    private var disconnectedCancelHandler: java.lang.Runnable? = null

    private fun showDisconnectedNotification() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                DISCONNECTED_CHANNEL_ID,
                "Connection status",
                NotificationManager.IMPORTANCE_DEFAULT
            )
            manager.createNotificationChannel(channel)
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, DISCONNECTED_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle("Your device disconnected")
            .setContentText("Connector is continuing to search for your device")
            .setSmallIcon(android.R.drawable.ic_menu_info_details)
            .setAutoCancel(true)
            .build()
        manager.notify(DISCONNECTED_NOTIFICATION_ID, notification)
        // Auto-cancel after 5 seconds
        disconnectedCancelHandler?.let { android.os.Handler(mainLooper).removeCallbacks(it) }
        val handler = java.lang.Runnable {
            manager.cancel(DISCONNECTED_NOTIFICATION_ID)
        }
        disconnectedCancelHandler = handler
        android.os.Handler(mainLooper).postDelayed(handler, 5000)
    }

    private fun clearDisconnectedNotification() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(DISCONNECTED_NOTIFICATION_ID)
        disconnectedCancelHandler?.let { android.os.Handler(mainLooper).removeCallbacks(it) }
        disconnectedCancelHandler = null
    }

    private fun listInstalledApps(): List<Map<String, String>> {
        val pm = packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val resolved = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.queryIntentActivities(intent, PackageManager.ResolveInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            pm.queryIntentActivities(intent, 0)
        }
        val seen = mutableSetOf<String>()
        val apps = mutableListOf<Map<String, String>>()
        for (ri in resolved) {
            val pkg = ri.activityInfo.packageName
            if (!seen.add(pkg)) continue
            val label = ri.loadLabel(pm).toString()
            apps.add(mapOf("package" to pkg, "label" to label))
        }
        return apps
    }

    private fun exportAppIcon(packageName: String): String? {
        return try {
            val pm = packageManager
            val ai = pm.getApplicationInfo(packageName, 0)
            val iconDir = File(cacheDir, "appIcons")
            if (!iconDir.exists()) iconDir.mkdirs()
            val outFile = File(iconDir, "$packageName.png")
            val drawable = ai.loadIcon(pm)
            val bitmap = if (drawable is BitmapDrawable) {
                drawable.bitmap
            } else {
                val width = drawable.intrinsicWidth.coerceAtLeast(1)
                val height = drawable.intrinsicHeight.coerceAtLeast(1)
                val bmp = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(bmp)
                drawable.setBounds(0, 0, width, height)
                drawable.draw(canvas)
                bmp
            }
            FileOutputStream(outFile).use { fos ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, fos)
            }
            outFile.absolutePath
        } catch (e: Exception) {
            null
        }
    }

    private fun getAppIconPath(packageName: String): String {
        val iconFile = File(cacheDir, "appIcons/$packageName.png")
        return if (iconFile.exists()) iconFile.absolutePath else ""
    }

    private fun sendNotificationReply(replyCommandId: String, text: String): Boolean {
        val action = replyActions[replyCommandId] ?: return false
        val remoteInputs = action.remoteInputs ?: return false
        if (text.isBlank()) return false
        return try {
            val intent = Intent()
            val results = android.os.Bundle()
            for (input in remoteInputs) {
                results.putCharSequence(input.resultKey, text)
            }
            RemoteInput.addResultsToIntent(remoteInputs, intent, results)
            action.actionIntent.send(this, 0, intent)
            true
        } catch (_: Exception) {
            false
        }
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
                state.currentPositionMs(),
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
        wakeLock?.let { lock ->
            if (lock.isHeld) lock.release()
        }
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
        private const val TRANSFER_CHANNEL_ID = "connector_file_transfer"
        private const val FILE_TRANSFER_NOTIFICATION_ID = 1212
        private const val DISCONNECTED_CHANNEL_ID = "connector_disconnected"
        private const val DISCONNECTED_NOTIFICATION_ID = 1213
        private const val SYSTEM_CHANNEL_ID = "connector_system"
        private const val SYSTEM_NOTIFICATION_ID = 1214
        private const val BIOMETRIC_STRONG = 0x000F
        private const val DEVICE_CREDENTIAL = 0x8000
        private const val MEDIA_SMOOTHING_WINDOW_MS = 5000L
        private var methodChannel: MethodChannel? = null
        private val replyActions = ConcurrentHashMap<String, Notification.Action>()
        private val pendingPhoneNotifications = mutableListOf<Map<String, Any>>()

        fun sendPhoneNotification(data: Map<String, Any>) {
            val channel = methodChannel
            if (channel == null) {
                synchronized(pendingPhoneNotifications) {
                    pendingPhoneNotifications.add(data)
                    if (pendingPhoneNotifications.size > 50) {
                        pendingPhoneNotifications.removeAt(0)
                    }
                }
            } else {
                channel.invokeMethod("phoneNotification", data)
            }
        }

        fun flushPendingPhoneNotifications() {
            val channel = methodChannel ?: return
            val pending = synchronized(pendingPhoneNotifications) {
                val copy = pendingPhoneNotifications.toList()
                pendingPhoneNotifications.clear()
                copy
            }
            for (notification in pending) {
                channel.invokeMethod("phoneNotification", notification)
            }
        }

        fun sendLaptopMediaAction(action: Map<String, Any>) {
            methodChannel?.invokeMethod("laptopMediaAction", action)
        }

        fun registerReplyAction(action: Notification.Action): String {
            val id = "reply_${System.currentTimeMillis()}_${action.hashCode()}"
            replyActions[id] = action
            if (replyActions.size > 100) {
                val firstKey = replyActions.keys.firstOrNull()
                if (firstKey != null) replyActions.remove(firstKey)
            }
            return id
        }
    }

    data class LaptopMediaState(
        val title: String,
        val artist: String,
        val album: String,
        val sourceApp: String,
        val isPlaying: Boolean,
        val positionMs: Long,
        val durationMs: Long,
        val updatedAtMs: Long
    ) {
        fun currentPositionMs(): Long {
            val ageMs = if (isPlaying && updatedAtMs > 0) {
                (System.currentTimeMillis() - updatedAtMs).coerceAtLeast(0L)
            } else {
                0L
            }
            val max = durationMs.coerceAtLeast(0L)
            return (positionMs.coerceAtLeast(0L) + ageMs).coerceIn(0L, max)
        }

        private fun isSameTrackAs(other: LaptopMediaState): Boolean {
            return title == other.title &&
                artist == other.artist &&
                album == other.album &&
                sourceApp == other.sourceApp &&
                kotlin.math.abs(durationMs - other.durationMs) <= 1000L
        }

        fun smoothedAgainst(previous: LaptopMediaState?): LaptopMediaState {
            if (previous == null || !isSameTrackAs(previous)) {
                return this
            }
            if (!isPlaying || !previous.isPlaying) {
                return this
            }

            val localPosition = previous.currentPositionMs()
            val incomingPosition = currentPositionMs()
            val correctionMs = kotlin.math.abs(incomingPosition - localPosition)

            return if (correctionMs <= MEDIA_SMOOTHING_WINDOW_MS) {
                copy(
                    positionMs = localPosition,
                    updatedAtMs = System.currentTimeMillis()
                )
            } else {
                this
            }
        }

        companion object {
            fun fromMap(data: Map<*, *>): LaptopMediaState {
                return LaptopMediaState(
                    title = data["title"]?.toString().orEmpty(),
                    artist = data["artist"]?.toString().orEmpty(),
                    album = data["album"]?.toString().orEmpty(),
                    sourceApp = data["sourceApp"]?.toString().orEmpty(),
                    isPlaying = data["isPlaying"] == true,
                    positionMs = (data["positionMs"] as? Number)?.toLong() ?: 0L,
                    durationMs = (data["durationMs"] as? Number)?.toLong() ?: 0L,
                    updatedAtMs = (data["updatedAtMs"] as? Number)?.toLong() ?: 0L
                )
            }
        }
    }
}
