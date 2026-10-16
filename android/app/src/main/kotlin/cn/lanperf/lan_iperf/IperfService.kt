package cn.lanperf.lan_iperf

import android.app.Service
import android.content.Intent
import android.os.*

/** A separate process makes cancel/timeout close every native socket safely. */
class IperfService : Service() {
    private var reply: Messenger? = null
    @Volatile private var running = false
    private val inbox = Messenger(Handler(Looper.getMainLooper()) { message ->
        if (message.what == 1 && !running) {
            running = true
            reply = message.replyTo
            val data = message.data
            Thread {
                try {
                    val json = nativeRun(data.getString("host")!!, data.getInt("port"),
                        data.getInt("seconds"), data.getInt("streams"), data.getInt("udpMbps"),
                        data.getBoolean("udp"), data.getBoolean("reverse"), data.getBoolean("bidirectional"),
                        data.getBoolean("constantLoad"), cacheDir.absolutePath)
                    running = false
                    send(2, json)
                } catch (e: Throwable) {
                    running = false
                    send(3, e.message ?: "原生引擎失败")
                }
            }.start()
        }
        true
    })
    override fun onBind(intent: Intent): IBinder = inbox.binder
    private fun send(kind: Int, text: String) {
        try {
            reply?.send(Message.obtain(null, kind).apply {
                data = Bundle().apply { putString("json", text) }
            })
        } catch (_: RemoteException) { /* Client closed. onDestroy will terminate us. */ }
    }
    // Called synchronously from the JNI worker; Binder dispatches onto Flutter's UI thread.
    fun onSample(json: String) = send(1, json)
    private external fun nativeRun(host: String, port: Int, seconds: Int, streams: Int,
        mbps: Int, udp: Boolean, reverse: Boolean, bidirectional: Boolean, constantLoad: Boolean, cache: String): String
    override fun onDestroy() {
        super.onDestroy()
        Process.killProcess(Process.myPid())
    }
    companion object { init { System.loadLibrary("laniperf") } }
}
