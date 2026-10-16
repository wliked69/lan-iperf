package cn.lanperf.lan_iperf

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.Build
import java.io.File
import java.net.Inet4Address

object ConnectionInfo {
    @Suppress("DEPRECATION")
    fun read(context: Context): List<Map<String, Any>> {
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val networks = manager.allNetworks.toList()
        val wifiCount = networks.count { manager.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true }
        return networks.mapNotNull { network ->
            val caps = manager.getNetworkCapabilities(network) ?: return@mapNotNull null
            val link = manager.getLinkProperties(network) ?: return@mapNotNull null
            val wifi = caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
            val ethernet = caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
            val row = mutableMapOf<String, Any>(
                "name" to (link.interfaceName ?: "网络"),
                "address" to ((link.linkAddresses.firstOrNull { it.address is Inet4Address }
                    ?: link.linkAddresses.firstOrNull())?.address?.hostAddress ?: ""),
                "preferred" to (manager.activeNetwork == network),
                "type" to when {
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
                    wifi -> "wifi"
                    ethernet -> "ethernet"
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH) -> "bluetooth"
                    else -> "other"
                },
            )
            if (wifi && row["type"] == "wifi") {
                try {
                    var info = if (Build.VERSION.SDK_INT >= 29) caps.transportInfo as? WifiInfo else null
                    if (info == null && wifiCount == 1) {
                        info = (context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager).connectionInfo
                    }
                    if (info != null) {
                        if (info.rssi in -126..-1) row["rssi"] = info.rssi
                        if (info.frequency > 0) row["frequencyMHz"] = info.frequency
                        if (info.linkSpeed > 0) row["linkMbps"] = info.linkSpeed
                        if (Build.VERSION.SDK_INT >= 29) {
                            if (info.txLinkSpeedMbps > 0) row["txMbps"] = info.txLinkSpeedMbps
                            if (info.rxLinkSpeedMbps > 0) row["rxMbps"] = info.rxLinkSpeedMbps
                        }
                        if (Build.VERSION.SDK_INT >= 30) {
                            val standard = when (info.wifiStandard) {
                                1 -> "802.11a/b/g"
                                4 -> "Wi-Fi 4 (802.11n)"
                                5 -> "Wi-Fi 5 (802.11ac)"
                                6 -> "Wi-Fi 6 (802.11ax)"
                                7 -> "802.11ad"
                                8 -> "Wi-Fi 7 (802.11be)"
                                else -> null
                            }
                            if (standard != null) row["standard"] = standard
                        }
                    }
                } catch (_: SecurityException) {
                    row["note"] = "系统限制读取 Wi-Fi 详情，请允许相关权限后刷新。"
                }
                val missing = !row.containsKey("rssi") || !row.containsKey("frequencyMHz") ||
                    (!row.containsKey("linkMbps") && !row.containsKey("rxMbps"))
                if (missing) {
                    row.putIfAbsent("note", "部分 Wi-Fi 信息未提供；可允许权限并检查系统位置服务后刷新。")
                    row["requestPermission"] = context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED ||
                        (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.NEARBY_WIFI_DEVICES) != PackageManager.PERMISSION_GRANTED)
                }
            } else if (ethernet && row["type"] == "ethernet") {
                // NetworkCapabilities bandwidth is an estimate, not negotiated Ethernet speed.
                val iface = link.interfaceName
                if (iface != null && iface.matches(Regex("[a-zA-Z0-9_.-]+"))) {
                    val speed = try { File("/sys/class/net/$iface/speed").readText().trim().toIntOrNull() } catch (_: Exception) { null }
                    if (speed != null && speed > 0) {
                        row["txMbps"] = speed
                        row["rxMbps"] = speed
                    }
                }
                if (!row.containsKey("rxMbps")) row["note"] = "系统未提供网卡协商速率。"
            }
            row
        }
    }
}
