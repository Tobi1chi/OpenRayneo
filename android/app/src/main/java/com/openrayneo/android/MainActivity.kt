// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.provider.ContactsContract
import android.speech.RecognizerIntent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import org.json.JSONObject

internal class MainActivity : ComponentActivity() {
    private val model: AppModel by viewModels()
    private var exportRecord: String? = null
    private val exportAudio = registerForActivityResult(ActivityResultContracts.CreateDocument("audio/wav")) { uri ->
        val id = exportRecord; exportRecord = null
        if (uri != null && id != null) model.exportRecording(id, uri)
    }
    private var voiceSource = AnswerSource.MOBILE_AGENT
    private val contact = registerForActivityResult(ActivityResultContracts.PickContact()) { uri ->
        if (uri != null) model.attempt {
            contentResolver.query(uri, arrayOf(ContactsContract.Contacts.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) model.selectedContact = SelectedContact(cursor.getString(0), uri.toString())
            }
        }
    }
    private val permissions =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            model.refreshPermissions()
            if (model.wantsScan) {
                model.wantsScan = false
                if (model.bluetoothAllowed) model.scan()
                else model.error = L(
                    "连接眼镜需要附近设备权限。可以稍后在设置中授权，其他配置仍可使用。",
                    "Nearby Devices permission is required to connect glasses. You can grant it later in Settings.",
                )
            }
        }
    private val locationPermission = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        if (PhoneLocation.allowed(this)) model.attempt { model.service().enableLocationWhileVisible() }
    }
    private val importFile =
        registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            if (uri != null)
                model.attempt {
                    val bytes = contentResolver.openInputStream(uri)!!.use { it.readNBytes(16385) }
                    require(bytes.size <= 16384) { "配置文件过大" }
                    model.importConfig(JSONObject(String(bytes, Charsets.UTF_8)))
                }
        }
    private val speech =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            if (result.resultCode == RESULT_OK) {
                val text =
                    result.data
                        ?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
                        ?.firstOrNull()
                        .orEmpty()
                if (voiceSource == AnswerSource.MOBILE_AGENT) model.phoneDraft = text
                else model.computerDraft = text
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        voiceSource =
            savedInstanceState?.getString("voiceSource")?.let(AnswerSource::valueOf)
                ?: AnswerSource.MOBILE_AGENT
        enableEdgeToEdge()
        setContent {
            CompanionTheme(model.appearance) {
                CompanionApp(
                    model,
                    UiActions(
                        bluetoothPermission = {
                            permissions.launch(arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT))
                        },
                        exportRecording = { id -> exportRecord = id; exportAudio.launch("OpenRayneo-meeting-$id.wav") },
                        contact = { contact.launch(null) },
                        locationPermission = { locationPermission.launch(arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION)) },
                        scan = {
                            if (model.bluetoothAllowed) model.scan()
                            else {
                                model.wantsScan = true
                                permissions.launch(
                                    arrayOf(
                                        Manifest.permission.BLUETOOTH_SCAN,
                                        Manifest.permission.BLUETOOTH_CONNECT,
                                    )
                                )
                            }
                        },
                        notificationAccess = {
                            model.attempt {
                                startActivity(
                                    Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                                )
                            }
                        },
                        notificationPermission = {
                            permissions.launch(arrayOf(Manifest.permission.POST_NOTIFICATIONS))
                        },
                        appSettings = {
                            startActivity(
                                Intent(
                                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    Uri.parse("package:$packageName"),
                                )
                            )
                        },
                        openGaode = {
                            model.attempt {
                                startActivity(
                                    checkNotNull(
                                        packageManager.getLaunchIntentForPackage(
                                            NavigationFeed.PACKAGE
                                        )
                                    ) {
                                        L("请先在手机安装高德地图", "Install Amap (Gaode Maps) on your phone first")
                                    }
                                )
                            }
                        },
                        importConfig = {
                            importFile.launch(arrayOf("application/json", "text/plain"))
                        },
                        voice = { source ->
                            model.attempt {
                                voiceSource = source
                                speech.launch(
                                    Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                                        .putExtra(
                                            RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                                            RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
                                        )
                                        .putExtra(RecognizerIntent.EXTRA_LANGUAGE, AppLanguage.speechLocale)
                                )
                            }
                        },
                        switchOfficialApp = { official -> switchGlassesApp(official) },
                    ),
                )
            }
        }
    }

    @android.annotation.SuppressLint("MissingPermission")
    private fun switchGlassesApp(official: Boolean) {
        if (model.switchingApps) return
        if (!official && !model.bluetoothAllowed) {
            model.error = L("连接眼镜需要附近设备权限，请先在设置中授权。", "Grant Nearby Devices permission in Settings before connecting glasses.")
            return
        }
        val launch = if (official) AppSwitcher.findOfficialLaunchIntent(packageManager) else null
        if (official && launch == null) {
            model.error = L(
                "未检测到已安装的雷鸟官方 App（com.rayneo.venus / com.rayneo.venus.pub）。",
                "Official RayNeo app is not installed (com.rayneo.venus / com.rayneo.venus.pub).",
            )
            return
        }
        model.switchingApps = true
        lifecycleScope.launch {
            try {
                if (official) {
                    runCatching { model.service().disconnect() }
                    runCatching {
                        withTimeout(8000) {
                            while (model.state.glasses.link.phase != LinkPhase.DISCONNECTED || model.state.glasses.disconnecting) {
                                delay(100)
                            }
                        }
                    }
                    val helperResult = AppSwitcher.notifyPcHelperIfConfigured(model.config, official = true)
                    if (helperResult is AppSwitcher.HelperOutcome.Failed) {
                        model.error = L(
                            "本机切换助手调用失败（${helperResult.message}），请检查助手服务。",
                            "Local switch helper failed (${helperResult.message}). Check helper service.",
                        )
                        return@launch
                    }
                    startActivity(launch!!)
                    model.notice = L(
                        "已释放眼镜连接并切换到官方 App，无需解绑。",
                        "Released glasses connection and switched to the official RayNeo app without unlinking.",
                    )
                } else {
                    val helperResult = AppSwitcher.notifyPcHelperIfConfigured(model.config, official = false)
                    if (helperResult is AppSwitcher.HelperOutcome.Failed) {
                        model.error = L(
                            "本机切换助手调用失败（${helperResult.message}），请先在官方 App 中断开眼镜后重试。",
                            "Local switch helper failed (${helperResult.message}). Disconnect the official app first and retry.",
                        )
                        return@launch
                    }
                    delay(600)
                    if (model.state.glasses.link.phase != LinkPhase.FULL) {
                        runCatching { model.service().connection.showBonded() }
                        val choices = model.state.devices
                        val savedAddress = model.lastGlassesAddress
                        val selected = if (savedAddress.isNotBlank()) {
                            choices.firstOrNull { it.bluetooth.address == savedAddress }
                        } else {
                            choices.singleOrNull()
                        }
                        if (selected != null) model.connect(selected, false)
                        else model.notice = L(
                            "未找到上次连接的眼镜；请确认官方 App 已释放连接，再点“连接眼镜”手动选择。",
                            "Saved glasses not found. Ensure the official app released the link, then tap Connect to choose.",
                        )
                    } else {
                        model.notice = L("OpenRayneo 已连接眼镜。", "OpenRayneo is already connected to your glasses.")
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                model.error = error.message ?: L("切换 App 失败", "Failed to switch apps")
            } finally {
                model.switchingApps = false
            }
        }
    }

    override fun onResume() {
        super.onResume()
        model.refreshPermissions()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString("voiceSource", voiceSource.name)
        super.onSaveInstanceState(outState)
    }
}

internal data class UiActions(
    val bluetoothPermission: () -> Unit,
    val exportRecording: (String) -> Unit,
    val contact: () -> Unit,
    val locationPermission: () -> Unit,
    val scan: () -> Unit,
    val notificationAccess: () -> Unit,
    val notificationPermission: () -> Unit,
    val appSettings: () -> Unit,
    val openGaode: () -> Unit,
    val importConfig: () -> Unit,
    val voice: (AnswerSource) -> Unit,
    val switchOfficialApp: (Boolean) -> Unit,
)
