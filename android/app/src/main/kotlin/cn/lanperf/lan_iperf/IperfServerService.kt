package cn.lanperf.lan_iperf

import android.app.Service
import android.content.Intent
import android.os.*

/** An isolated native server. A new port always requires a fresh process. */
class IperfServerService : Service() {
    private var started = false
    private var receiver: Messenger? = null
    private fun send(reply: Messenger?, kind: Int, key: String? = null, text: String? = null) {
        try { reply?.send(Message.obtain(null, kind).apply {
            if (key != null) data = Bundle().apply { putString(key, text) }
        }) } catch (_: RemoteException) {}
    }
    private val inbox = Messenger(Handler(Looper.getMainLooper()) { message ->
        when (message.what) {
            2 -> { Process.killProcess(Process.myPid()) }
            1 -> {
                val reply = message.replyTo
                val port = message.arg1
                if (started) send(reply, 3, "error", "旧服务端仍在运行，请先停止后重新启动")
                else if (port !in 1..65535) send(reply, 3, "error", "服务端端口无效")
                else {
                    started = true
                    receiver = reply
                    send(reply, 5) // Acknowledge this particular fresh worker, not just its Binder.
                    Thread {
                        val error = try { nativeServe(port, cacheDir.absolutePath) }
                            catch (e: Throwable) { e.message ?: "原生服务端失败" }
                        send(reply, 3, "error", error)
                    }.start()
                }
            }
        }
        true
    })
    fun onSample(json: String) = onEvent("{\"event\":\"interval\",\"data\":$json}")
    fun onEvent(json: String) = send(receiver, 4, "event", json)
    override fun onBind(intent: Intent): IBinder = inbox.binder
    private external fun nativeServe(port: Int, cache: String): String
    override fun onDestroy() {
        super.onDestroy()
        Process.killProcess(Process.myPid())
    }
    companion object { init { System.loadLibrary("laniperf") } }
}
