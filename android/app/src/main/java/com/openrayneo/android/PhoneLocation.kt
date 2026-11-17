// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.os.CancellationSignal
import android.os.SystemClock
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** One location fix per explicit tool call; no continuous tracking or Google Play dependency. */
internal class PhoneLocation(private val context: Context) {
    companion object {
        fun allowed(context: Context) = context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
    }
    @SuppressLint("MissingPermission")
    fun current(): JSONObject {
        check(allowed(context)) { "请在OpenRayneo语音设置中允许位置访问，然后再查询当地天气；也可以直接告诉我城市" }
        val manager = context.getSystemService(LocationManager::class.java)
        check(manager.isLocationEnabled) { "手机定位已关闭，请打开系统定位，或告诉我城市" }
        val providers = listOf(LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER)
            .filter { manager.isProviderEnabled(it) }
        val cached = providers.mapNotNull { manager.getLastKnownLocation(it) }
            .filter { SystemClock.elapsedRealtimeNanos() - it.elapsedRealtimeNanos in 0..TimeUnit.MINUTES.toNanos(5) }
            .maxByOrNull { it.elapsedRealtimeNanos }
        var result: Location? = cached
        if (result == null) {
            check(providers.isNotEmpty()) { "手机没有可用的定位来源，请打开定位或告诉我城市" }
            val done = CountDownLatch(1)
            val signals = providers.map { CancellationSignal() }
            try {
                providers.forEachIndexed { index, provider ->
                    manager.getCurrentLocation(provider, signals[index], context.mainExecutor) { location ->
                        if (location != null && done.count > 0) { result = location; done.countDown() }
                    }
                }
                done.await(10, TimeUnit.SECONDS)
            } finally { signals.forEach { it.cancel() } }
        }
        val location = checkNotNull(result) { "这次没有取得手机位置，请到室外重试或告诉我城市" }
        return JSONObject().put("latitude", location.latitude).put("longitude", location.longitude)
            .put("accuracyMeters", location.accuracy).put("locatedAt", location.time)
            .put("source", "phone_location").put("name", "当前位置")
    }
}
