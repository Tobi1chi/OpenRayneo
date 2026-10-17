// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.speech.RecognizerIntent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import org.json.JSONObject

internal class MainActivity : ComponentActivity() {
    private val model: AppModel by viewModels()
    private var voiceSource = AnswerSource.MOBILE_AGENT
    private val permissions =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            model.refreshPermissions()
            if (model.wantsScan) {
                model.wantsScan = false
                if (model.bluetoothAllowed) model.scan()
                else model.error = "连接眼镜需要附近设备权限。可以稍后在设置中授权，其他配置仍可使用。"
            }
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
                                        "请先在手机安装高德地图"
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
                                        .putExtra(RecognizerIntent.EXTRA_LANGUAGE, "zh-CN")
                                )
                            }
                        },
                    ),
                )
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
    val scan: () -> Unit,
    val notificationAccess: () -> Unit,
    val notificationPermission: () -> Unit,
    val appSettings: () -> Unit,
    val openGaode: () -> Unit,
    val importConfig: () -> Unit,
    val voice: (AnswerSource) -> Unit,
)
