#include "iperf_config.h"
#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/socket.h>
#include "iperf.h"
#include "iperf_api.h"
#include "cjson.h"

// One test per isolated Android service process. No JNI reference crosses threads.
static JNIEnv *callback_env;
static jobject callback_sink;
static jmethodID callback_method;
static int reported;

static void report_interval(struct iperf_test *test) {
    iperf_reporter_callback(test);
    int count = cJSON_GetArraySize(test->json_intervals);
    while (reported < count) {
        char *json = cJSON_PrintUnformatted(cJSON_GetArrayItem(test->json_intervals, reported++));
        if (!json) continue;
        jstring value = (*callback_env)->NewStringUTF(callback_env, json);
        free(json);
        if (!value) return;
        (*callback_env)->CallVoidMethod(callback_env, callback_sink, callback_method, value);
        (*callback_env)->DeleteLocalRef(callback_env, value);
        if ((*callback_env)->ExceptionCheck(callback_env)) {
            (*callback_env)->ExceptionClear(callback_env);
            return;
        }
    }
}

JNIEXPORT jstring JNICALL
Java_cn_lanperf_lan_1iperf_IperfService_nativeRun(JNIEnv *env, jobject sink,
    jstring host_value, jint port, jint seconds, jint streams, jint mbps,
    jboolean udp, jboolean reverse, jboolean bidirectional, jboolean constant_load, jstring cache_value) {
    signal(SIGPIPE, SIG_IGN);
    const char *host = (*env)->GetStringUTFChars(env, host_value, NULL);
    const char *cache = (*env)->GetStringUTFChars(env, cache_value, NULL);
    if (!host || !cache) return NULL;
    struct iperf_test *test = iperf_new_test();
    if (!test || iperf_defaults(test) < 0) {
        if (test) iperf_free_test(test);
        (*env)->ReleaseStringUTFChars(env, host_value, host);
        (*env)->ReleaseStringUTFChars(env, cache_value, cache);
        return (*env)->NewStringUTF(env, "{\"error\":\"Cannot initialize iperf3\"}");
    }
    iperf_set_test_role(test, 'c');
    iperf_set_test_server_hostname(test, host);
    iperf_set_test_server_port(test, port);
    iperf_set_test_duration(test, seconds);
    iperf_set_test_num_streams(test, streams);
    iperf_set_test_connect_timeout(test, 5000);
    iperf_set_test_reverse(test, reverse);
    iperf_set_test_bidirectional(test, bidirectional);
    iperf_set_test_json_output(test, 1);
    iperf_set_test_reporter_interval(test, 0.1);
    iperf_set_test_stats_interval(test, 0.1);
    if (udp) {
        set_protocol(test, Pudp);
        iperf_set_test_blksize(test, 1200);

    }
    if (udp || constant_load) iperf_set_test_rate(test, (uint64_t)mbps * 1000000 / streams);
    char temporary[4096];
    snprintf(temporary, sizeof(temporary), "%s/iperf.XXXXXX", cache);
    iperf_set_test_template(test, temporary);
    test->settings->rcv_timeout.secs = 10;
    test->settings->rcv_timeout.usecs = 0;
    FILE *quiet = fopen("/dev/null", "w");
    if (quiet) test->outfile = quiet;
    callback_env = env;
    callback_sink = sink;
    jclass cls = (*env)->GetObjectClass(env, sink);
    callback_method = (*env)->GetMethodID(env, cls, "onSample", "(Ljava/lang/String;)V");
    reported = 0;
    test->reporter_callback = report_interval;
    int status = iperf_run_client(test);
    const char *output = iperf_get_test_json_output_string(test);
    char *fallback = NULL;
    if (!output || (status < 0 && !strstr(output, "\"error\""))) {
        cJSON *error = cJSON_CreateObject();
        cJSON_AddStringToObject(error, "error", status < 0 ? iperf_strerror(i_errno) : "No result returned");
        fallback = cJSON_PrintUnformatted(error);
        cJSON_Delete(error);
        output = fallback;
    }
    jstring result = (*env)->NewStringUTF(env, output ? output : "{\"error\":\"No result\"}");
    free(fallback);
    // iperf_free_test does not close outfile; its ownership stays with the bridge.
    iperf_free_test(test);
    if (quiet) fclose(quiet);
    (*env)->DeleteLocalRef(env, cls);
    (*env)->ReleaseStringUTFChars(env, host_value, host);
    (*env)->ReleaseStringUTFChars(env, cache_value, cache);
    return result;
}

static jmethodID server_event_method;
static int server_started;

static void emit_server_event(const char *event, cJSON *data) {
    cJSON *object = cJSON_CreateObject();
    cJSON_AddStringToObject(object, "event", event);
    cJSON_AddItemToObject(object, "data", data ? cJSON_Duplicate(data, 1) : cJSON_CreateObject());
    char *text = cJSON_PrintUnformatted(object);
    cJSON_Delete(object);
    if (!text) return;
    jstring value = (*callback_env)->NewStringUTF(callback_env, text);
    free(text);
    if (value) {
        (*callback_env)->CallVoidMethod(callback_env, callback_sink, server_event_method, value);
        (*callback_env)->DeleteLocalRef(callback_env, value);
        if ((*callback_env)->ExceptionCheck(callback_env)) (*callback_env)->ExceptionClear(callback_env);
    }
}
static void server_test_start(struct iperf_test *test) {
    iperf_on_test_start(test);
    server_started = 1;
    emit_server_event("start", test->json_start);
}

JNIEXPORT jstring JNICALL
Java_cn_lanperf_lan_1iperf_IperfServerService_nativeServe(JNIEnv *env, jobject sink,
    jint port, jstring cache_value) {
    callback_env = env;
    callback_sink = sink;
    jclass cls = (*env)->GetObjectClass(env, sink);
    callback_method = (*env)->GetMethodID(env, cls, "onSample", "(Ljava/lang/String;)V");
    server_event_method = (*env)->GetMethodID(env, cls, "onEvent", "(Ljava/lang/String;)V");
    (*env)->DeleteLocalRef(env, cls);
    signal(SIGPIPE, SIG_IGN);
    struct iperf_test *test = iperf_new_test();
    if (!test || iperf_defaults(test) < 0) {
        if (test) iperf_free_test(test);
        return (*env)->NewStringUTF(env, "Cannot initialize iperf3 server");
    }
    const char *cache = (*env)->GetStringUTFChars(env, cache_value, NULL);
    if (!cache) { iperf_free_test(test); return NULL; }
    char temporary[4096];
    snprintf(temporary, sizeof(temporary), "%s/server.XXXXXX", cache);
    iperf_set_test_template(test, temporary);
    (*env)->ReleaseStringUTFChars(env, cache_value, cache);
    iperf_set_test_role(test, 's');
    iperf_set_test_json_output(test, 1);
    test->on_test_start = server_test_start;
    test->reporter_callback = report_interval;
    iperf_set_test_server_port(test, port);
    test->settings->domain = AF_UNSPEC;
    for (;;) {
        // iperf_reset_test closes outfile, including after discovery probes.
        // Give every session a fresh stream and let libiperf close it on reset.
        test->outfile = fopen("/dev/null", "w");
        if (!test->outfile) {
            iperf_free_test(test);
            return (*env)->NewStringUTF(env, "Cannot open iperf3 server output");
        }
        reported = 0;
        server_started = 0;
        iperf_set_test_reporter_interval(test, 0.1);
        iperf_set_test_stats_interval(test, 0.1);
        int status = iperf_run_server(test);
        if (server_started) {
            const char *output = iperf_get_test_json_output_string(test);
            cJSON *json = output ? cJSON_Parse(output) : NULL;
            emit_server_event("end", json ? cJSON_GetObjectItem(json, "end") : NULL);
            cJSON_Delete(json);
        }
        // A discovery probe intentionally terminates its session. Reset and listen again.
        if (status < -1) break;

        iperf_reset_test(test);
    }
    jstring error = (*env)->NewStringUTF(env, iperf_strerror(i_errno));
    iperf_close_logfile(test);
    iperf_free_test(test);
    return error;
}

