package cn.lanperf.lan_iperf

import android.content.*
import android.app.ActivityManager
import android.os.*
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import android.net.ConnectivityManager
import android.net.NetworkCapabilities

class MainActivity : FlutterActivity() {
    private lateinit var channel: MethodChannel
    private val handler = Handler(Looper.getMainLooper())
    private var connection: ServiceConnection? = null
    private var pending: MethodChannel.Result? = null
    private var timeout: Runnable? = null
    private var token = 0
    private var serverConnection: ServiceConnection? = null
    private var serverBinder: IBinder? = null
    private var serverAlive = false
    private var serverToken = 0
    private var serverRequest = 0
    private var serverStopping = false
    private var serverStartResult: MethodChannel.Result? = null
    private var serverStartTimeout: Runnable? = null
    private val serverStopWaiters = mutableListOf<(String?) -> Unit>()
    private lateinit var serverChannel: MethodChannel

    private fun ownServerProcesses(): List<ActivityManager.RunningAppProcessInfo> {
        val manager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return (manager.runningAppProcesses ?: emptyList()).filter {
            it.uid == Process.myUid() && it.pid != Process.myPid() &&
                it.processName == "$packageName:iperf_server"
        }
    }

    private fun finishServerStart(error: String?) {
        val result = serverStartResult
        serverStartResult = null
        serverStartTimeout?.let { handler.removeCallbacks(it) }
        serverStartTimeout = null
        if (error == null) result?.success(null) else result?.error("SERVER", error, null)
    }

    // Wait for our isolated process to die before rebinding. An immediate rebind
    // can otherwise reuse a Service whose native worker still owns the old port.
    private fun stopServer(done: (String?) -> Unit = {}) {
        serverStopWaiters.add(done)
        if (serverStopping) return
        serverStopping = true
        serverToken++
        finishServerStart("服务端启动已取消")
        val old = serverConnection
        val binder = serverBinder
        serverConnection = null
        serverBinder = null
        serverAlive = false
        if (binder?.isBinderAlive == true) {
            try { Messenger(binder).send(Message.obtain(null, 2)) } catch (_: RemoteException) {}
        }
        if (old != null) try { unbindService(old) } catch (_: IllegalArgumentException) {}
        // Only this application's exact :iperf_server process is eligible.
        // This also recovers a worker left behind by an earlier Activity.
        ownServerProcesses().forEach { Process.killProcess(it.pid) }
        val deadline = SystemClock.elapsedRealtime() + 3000
        fun checkStopped() {
            val dead = binder?.pingBinder() != true && ownServerProcesses().isEmpty()
            if (dead || SystemClock.elapsedRealtime() >= deadline) {
                serverStopping = false
                val callbacks = serverStopWaiters.toList()
                serverStopWaiters.clear()
                val error = if (dead) null else "本应用的旧服务端尚未退出，请稍后重试"
                callbacks.forEach { it(error) }
            } else handler.postDelayed({ checkStopped() }, 50)
        }
        checkStopped()
    }

    private fun startServer(port: Int, result: MethodChannel.Result) {
        val request = ++serverRequest
        stopServer { stopError ->
            if (request != serverRequest) {
                result.error("SERVER", "服务端启动已取消", null)
            } else if (stopError != null) {
                result.error("SERVER", stopError, null)
            } else {
                serverStartResult = result
                val generation = serverToken
                val reply = Messenger(Handler(Looper.getMainLooper()) { message ->
                    if (generation == serverToken) {
                        when (message.what) {
                            5 -> { serverAlive = true; finishServerStart(null) }
                            4 -> serverChannel.invokeMethod("event", message.data.getString("event"))
                            3 -> {
                                serverAlive = false
                                val error = message.data.getString("error") ?: "原生服务端启动失败"
                                finishServerStart(error)
                                serverChannel.invokeMethod("error", error)
                            }
                        }
                    }
                    true
                })
                val binding = object : ServiceConnection {
                    override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                        if (serverConnection !== this || generation != serverToken) return
                        serverBinder = binder
                        try {
                            Messenger(binder).send(Message.obtain(null, 1).apply { arg1 = port; replyTo = reply })
                        } catch (e: Exception) { finishServerStart("服务端连接失败：${e.message}"); stopServer() }
                    }
                    private fun disconnected(error: String) {
                        if (serverConnection !== this || generation != serverToken) return
                        serverAlive = false
                        finishServerStart(error)
                        serverChannel.invokeMethod("error", error)
                    }
                    override fun onServiceDisconnected(name: ComponentName) = disconnected("服务端进程已断开，请重启")
                    override fun onBindingDied(name: ComponentName) = disconnected("服务端绑定已失效，请重启")
                    override fun onNullBinding(name: ComponentName) = disconnected("服务端无法绑定，请检查原生引擎")
                }
                serverConnection = binding
                serverStartTimeout = Runnable {
                    if (request == serverRequest && serverStartResult != null) {
                        finishServerStart("安卓服务端启动确认超时，请重试")
                        stopServer()
                    }
                }.also { handler.postDelayed(it, 5000) }
                try {
                    if (!bindService(Intent(this, IperfServerService::class.java), binding, Context.BIND_AUTO_CREATE)) {
                        finishServerStart("服务端绑定失败"); stopServer()
                    }
                } catch (e: Exception) { finishServerStart("服务端启动失败：${e.message}"); stopServer() }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        serverChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cn.lanperf/server")
        serverChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "stop" -> {
                    serverRequest++
                    stopServer { error ->
                        if (error == null) result.success(null) else result.error("SERVER_STOP", error, null)
                    }
                }
                "status" -> result.success(serverAlive && serverBinder?.pingBinder() == true)
                "start" -> {
                    val port = call.argument<Int>("port") ?: 5201
                    if (port !in 1..65535) result.error("CONFIG", "端口无效", null)
                    else startServer(port, result)
                }
                else -> result.notImplemented()
            }
        }
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cn.lanperf/iperf")
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cn.lanperf/network")
            .setMethodCallHandler { call, result ->
                if (call.method == "wifiPermission") {
                    val permissions = mutableListOf(android.Manifest.permission.ACCESS_COARSE_LOCATION, android.Manifest.permission.ACCESS_FINE_LOCATION)
                    if (Build.VERSION.SDK_INT >= 33) permissions.add(android.Manifest.permission.NEARBY_WIFI_DEVICES)
                    requestPermissions(permissions.toTypedArray(), 4107)
                    result.success(null)
                }
                else if (call.method == "connections") {
                    try { result.success(ConnectionInfo.read(this)) }
                    catch (e: Exception) { result.error("NETWORK", "无法读取连接信息：${e.message}", null) }
                }
                else if (call.method != "networks") result.notImplemented()
                else try {
                    val networks = mutableListOf<Map<String, Any>>()
                    val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                    for (network in manager.allNetworks) {
                        val capabilities = manager.getNetworkCapabilities(network) ?: continue
                        if (!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
                            !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) continue
                        val link = manager.getLinkProperties(network) ?: continue
                        for (address in link.linkAddresses) {
                            if (address.address is Inet4Address) networks.add(mapOf(
                                "name" to (link.interfaceName ?: "LAN"),
                                "address" to address.address.hostAddress!!,
                                "prefix" to address.prefixLength,
                                "preferred" to (manager.activeNetwork == network)))
                        }
                    }
                    result.success(networks)
                } catch (e: Exception) { result.error("NETWORK", "无法读取本机网络：${e.message}", null) }
            }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    if (pending != null) result.error("BUSY", "已有测速正在运行", null)
                    else {
                        val host = call.argument<String>("host") ?: ""
                        val port = call.argument<Int>("port") ?: 5201
                        val seconds = call.argument<Int>("seconds") ?: 10
                        val streams = call.argument<Int>("streams") ?: 1
                        val rate = call.argument<Int>("udpMbps") ?: 100
                        if (!host.matches(Regex("[a-zA-Z0-9._:%-]+")) || host.startsWith("-") ||
                            port !in 1..65535 || seconds !in 1..99999 || streams !in 1..16 || rate !in 1..10000) {
                            result.error("CONFIG", "测速参数无效", null)
                        } else start(Bundle().apply {
                            putString("host", host); putInt("port", port); putInt("seconds", seconds)
                            putInt("streams", streams); putInt("udpMbps", rate)
                            putBoolean("udp", call.argument<Boolean>("udp") ?: false)
                            putBoolean("bidirectional", call.argument<Boolean>("bidirectional") ?: true)
                            putBoolean("constantLoad", call.argument<Boolean>("constantLoad") ?: false)
                            putBoolean("reverse", call.argument<Boolean>("reverse") ?: false)
                        }, result)
                    }
                }
                "cancel" -> { finishRun(null, "测速已取消"); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    private fun start(data: Bundle, result: MethodChannel.Result) {
        pending = result
        val runToken = ++token
        var streaming = false
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val reply = Messenger(Handler(Looper.getMainLooper()) { message ->
            if (runToken == token && pending != null) {
                val json = message.data.getString("json") ?: ""
                when (message.what) {
                    1 -> {
                        if (!streaming) {
                            streaming = true
                            timeout?.let { handler.removeCallbacks(it) }
                            timeout = Runnable {
                                if (runToken == token) finishRun(null, "测速超时，请检查目标设备和网络连接")
                            }.also { handler.postDelayed(it, (data.getInt("seconds") + 25L) * 1000) }
                        }
                        channel.invokeMethod("sample", json)
                    }
                    2 -> finishRun(json, null)
                    3 -> finishRun(null, json)
                }
            }
            true
        })
        connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                if (runToken != token || pending == null) return
                try { Messenger(binder).send(Message.obtain(null, 1).apply {
                    this.data = data; replyTo = reply
                }) } catch (e: RemoteException) { finishRun(null, "原生引擎连接失败：${e.message}") }
            }
            override fun onServiceDisconnected(name: ComponentName) {
                if (runToken == token && pending != null) finishRun(null, "测速引擎意外退出")
            }
            override fun onBindingDied(name: ComponentName) {
                if (runToken == token && pending != null) finishRun(null, "测速引擎连接中断")
            }
            override fun onNullBinding(name: ComponentName) {
                if (runToken == token && pending != null) finishRun(null, "测速引擎无法启动")
            }
        }
        try {
            if (!bindService(Intent(this, IperfService::class.java), connection!!, Context.BIND_AUTO_CREATE)) {
                finishRun(null, "无法启动测速引擎"); return
            }
        } catch (e: Exception) { finishRun(null, "测速引擎启动失败：${e.message}"); return }
        timeout = Runnable {
            if (runToken == token) finishRun(null, if (data.getBoolean("udp"))
                "UDP 连接启动超时，请检查端口和防火墙。Windows Cygwin 服务端的 UDP 多连接/双向存在限制，可改用 TCP 或关闭多连接。"
                else "测速连接启动超时，请检查地址、端口和防火墙")
        }.also { handler.postDelayed(it, 8000) }
    }

    private fun finishRun(json: String?, error: String?) {
        val result = pending
        pending = null
        token++
        timeout?.let { handler.removeCallbacks(it) }; timeout = null
        val oldConnection = connection; connection = null
        if (oldConnection != null) try { unbindService(oldConnection) } catch (_: IllegalArgumentException) {}
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (error == null) result?.success(json) else result?.error("IPERF", error, null)
    }

    override fun onDestroy() {
        serverRequest++
        stopServer()
        finishRun(null, "测速已取消：客户端关闭")
        super.onDestroy()
    }
}
