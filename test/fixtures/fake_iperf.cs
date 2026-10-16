// Process fixture: emits known values, not a network speed test.
using System;
using System.Threading;
class FakeIperf {
    static int Main(string[] args) {
        if (Array.IndexOf(args, "hang.local") >= 0) {
            Thread.Sleep(60000); return 0;
        }
        if (Array.IndexOf(args, "error.local") >= 0) {
            Console.Error.WriteLine("connection refused"); return 1;
        }
        Console.WriteLine("{\"event\":\"start\",\"data\":{}}");
        Console.WriteLine("{\"event\":\"interval\",\"data\":{\"sum\":{\"end\":0.1,\"bits_per_second\":125000000},\"sum_bidir_reverse\":{\"end\":0.1,\"bits_per_second\":95000000}}}");
        Console.Out.Flush();
        Thread.Sleep(500);
        Console.WriteLine("{\"event\":\"end\",\"data\":{\"sum_received\":{\"bits_per_second\":120000000},\"sum_received_bidir_reverse\":{\"bits_per_second\":90000000}}}");
        return 0;
    }
}
