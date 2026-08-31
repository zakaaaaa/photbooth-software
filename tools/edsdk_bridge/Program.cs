// ===========================================================================
// edsdk_bridge.exe — jembatan proses-terpisah antara Flutter dan Canon EDSDK.
//
// KENAPA PROSES TERPISAH?
//   1. EDSDK.dll yang tersedia (13.18.40, ikut digiCamControl) adalah x86,
//      sedangkan photobooth_app.exe adalah x64 → tidak bisa satu proses.
//   2. EDSDK butuh message pump Win32 di thread yang memanggil
//      EdsInitializeSDK. Di sini kita punya thread sendiri yang bersih,
//      tanpa berebut dengan event loop Flutter.
//   3. Kalau kamera dicabut / EDSDK crash, yang mati hanya bridge — app
//      photobooth tetap hidup dan tinggal me-respawn.
//
// PROTOKOL
//   stdout : BINER murni, berbingkai. Tiap frame:
//              magic "EDS1" (4B) | type (u32 LE) | length (u32 LE) | payload
//            type 1 = frame live view (JPEG)
//            type 2 = foto hasil jepret resolusi penuh (JPEG)
//   stderr : TEKS baris demi baris (UTF-8), untuk log & event:
//              READY model=<nama> port=<port>
//              EVENT LIVEVIEW=ON|OFF
//              EVENT AF_DONE | EVENT AF_FAIL <sebab>
//              EVENT CAPTURE_BEGIN
//              EVENT CAPTURE_DONE file=<nama> bytes=<n>
//              EVENT CAPTURE_FAIL <sebab>
//              EVENT DISCONNECTED
//              LOG <pesan>   /   ERR <kode> <pesan>
//   stdin  : TEKS baris demi baris, satu perintah per baris:
//              PING | LIVEVIEW ON [fps] | LIVEVIEW OFF | AF | CAPTURE
//              CAPTURE AF | INFO | QUIT
//
// Argumen CLI:
//   --list              hanya deteksi kamera lalu keluar (exit 0 = ada)
//   --wait <detik>      lama menunggu kamera muncul saat start (default 6)
//   --evf-fps <n>       batas atas fps live view (default 30)
//   --af-mode <m>       quick|live|face|multi|keep (default live)
//                       PENGARUH TERBESAR ke fps — lihat catatan di _afMode.
//                       'quick' paling kencang TAPI preview blur (AF fase
//                       butuh cermin turun) → jangan dipakai.
//   --save-to-camera    simpan juga ke kartu SD kamera (default: host saja)
//   --keep-quality      jangan paksa JPEG Large (default: dipaksa Large)
//   --quality <hex>     paksa nilai kEdsImageQuality tertentu
//   --evf-small         coba minta frame EVF kecil (ditolak EOS 100D)
//   --bench             ukur fps EVF di beberapa setelan AF, lalu keluar
//
// Exit code: 0 normal, 2 tidak ada kamera, 3 gagal buka sesi, 4 EDSDK error.
// ===========================================================================

using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace EdsdkBridge
{
    internal static class Program
    {
        // ---------- Win32 message pump ----------
        [StructLayout(LayoutKind.Sequential)]
        private struct MSG
        {
            public IntPtr hwnd;
            public uint message;
            public IntPtr wParam;
            public IntPtr lParam;
            public uint time;
            public int ptX;
            public int ptY;
        }

        [DllImport("user32.dll")]
        private static extern bool PeekMessage(out MSG lpMsg, IntPtr hWnd, uint min, uint max, uint remove);
        [DllImport("user32.dll")]
        private static extern bool TranslateMessage(ref MSG lpMsg);
        [DllImport("user32.dll")]
        private static extern IntPtr DispatchMessage(ref MSG lpMsg);
        private const uint PM_REMOVE = 1;

        // ---------- Pembacaan stdin lewat Win32 ----------
        // JANGAN pakai Console.In / Console.OpenStandardInput() di sini.
        // Diuji 2026-08-24: ketika proses induknya Dart (Flutter), KETIGA
        // cara .NET (Console.In.ReadLine, StreamReader, Stream.Read mentah)
        // memblokir SELAMANYA dan tidak pernah memberi EOF — padahal
        // datanya benar-benar sampai: PeekNamedPipe melihat byte-nya
        // bertambah dan ReadFile mentah membacanya utuh. Dari induk
        // PowerShell/.NET semuanya normal, jadi ini khusus interaksi pipe
        // Dart <-> lapisan Console .NET. ReadFile langsung bekerja di
        // kedua kasus (termasuk saat stdin berupa konsol sungguhan).
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GetStdHandle(int nStdHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool ReadFile(IntPtr hFile, byte[] lpBuffer, uint nNumberOfBytesToRead,
                                            out uint lpNumberOfBytesRead, IntPtr lpOverlapped);

        private const int STD_INPUT_HANDLE = -10;

        // ---------- State ----------
        private static readonly ConcurrentQueue<string> _commands = new ConcurrentQueue<string>();
        private static volatile bool _quit;

        private static Stream _stdout;
        private static readonly object _outLock = new object();
        private static readonly byte[] Magic = { (byte)'E', (byte)'D', (byte)'S', (byte)'1' };
        private const uint FrameTypeEvf = 1;
        private const uint FrameTypePhoto = 2;

        private static IntPtr _camera = IntPtr.Zero;
        private static bool _sessionOpen;
        private static bool _liveViewWanted;
        private static bool _liveViewOn;
        private static int _evfMinIntervalMs = 33; // ~30fps
        private static long _lastEvfTicks;
        private static long _lastEvfOkTicks;
        private static long _lastTimerExtendTicks;

        private static volatile bool _afResultSeen;
        private static uint _afResultParam;
        private static bool _afRunning;
        private static long _afDeadline;

        // Lama AF dibiarkan berjalan sebelum dihentikan. EOS 100D tidak
        // mengirim AfResult, jadi jendela ini SELALU habis penuh — itulah
        // sebabnya AF tidak boleh memblokir loop utama.
        private const int AfWindowMs = 3000;

        private static bool _capturePending;
        private static long _captureDeadlineTicks;
        private static string _lastDownloadKey;

        private static int _waitSeconds = 6;

        // Watchdog: bunuh diri kalau app berhenti mengirim perintah.
        //
        // Terjadi 2026-08-24: layar kamera ditinggalkan, QUIT tidak pernah
        // sampai/dieksekusi, dan bridge terus hidup memegang sesi USB —
        // sehingga sesi foto BERIKUTNYA ditolak (EdsOpenSession 0xC0) dan app
        // diam-diam jatuh ke EOS Webcam Utility 720p. Menutup sesi dengan
        // rapi dari sisi Dart saja terbukti tidak cukup; bridge harus punya
        // pengaman sendiri. Dart mengirim PING berkala sebagai tanda hidup.
        // 0 = mati (dipakai saat --bench / dijalankan manual dari terminal).
        private static int _idleTimeoutMs;
        private static long _lastCommandTicks;

        private static bool _saveToCamera;
        private static bool _keepQuality;
        private static uint _forcedQuality;
        private static bool _evfSmall;
        private static bool _bench;
        private static long _captureStartTicks;

        // Mode AF live view. Diukur 2026-08-24 pada EOS 100D:
        //   LiveMulti (3, setelan awal body) 11,7fps — download 75ms/frame
        //   Quick     (0)                    19,0fps — download 48ms/frame
        //   Live      (1)                    17,2fps
        //   LiveFace  (2)                    15,9fps
        // Mode Live/LiveFace/LiveMulti memakai deteksi kontras/wajah yang
        // menganalisis setiap frame, dan itu memperlambat aliran EVF.
        //
        // JANGAN pakai Quick sebagai default meski paling kencang: Quick
        // memakai sensor FASE yang butuh cermin turun, sehingga kamera tidak
        // bisa mengunci fokus selama live view — dicoba 2026-08-24 dan
        // hasilnya preview blur total. Live (1) hampir secepat Quick tapi
        // AF-nya benar-benar bekerja saat live view.
        // -1 = biarkan setelan body apa adanya.
        private static int _afMode = 1;

        // JANGAN pre-alokasi stream EVF. Diuji 2026-08-24: dengan
        // EdsCreateMemoryStream(1MB), EdsGetLength mengembalikan ukuran
        // ALOKASI (1024KB), bukan byte yang benar-benar ditulis — jadi frame
        // yang dikirim penuh sampah di belakang JPEG-nya. Dengan ukuran 0
        // EDSDK menumbuhkan stream tepat sebesar datanya, dan waktu download
        // ternyata sama saja (~80ms), jadi pre-alokasi tidak ada untungnya.
        private const ulong EvfStreamPrealloc = 0;

        // Statistik EVF, dilaporkan berkala. Penting untuk debugging: fps yang
        // diukur pembaca pipe bisa jauh lebih rendah dari fps sebenarnya kalau
        // pembacanya lambat, jadi bridge mengukur sisinya sendiri.
        private static int _evfFrames;
        private static long _evfBytes;
        private static long _statsTicks;

        // Rincian waktu per tahap pengambilan EVF. Tanpa ini mustahil tahu
        // apakah fps rendah berasal dari kamera (EdsDownloadEvfImage lama =
        // eksposur live view panjang / USB) atau dari overhead kita sendiri.
        private static long _tCreate, _tDownload, _tCopy, _tWrite;

        // Delegate WAJIB disimpan di field statis: kalau hanya dilewatkan
        // langsung ke P/Invoke, GC bisa mengumpulkannya dan callback dari
        // EDSDK akan menabrak memori yang sudah dibebaskan.
        private static Eds.EdsObjectEventHandler _objectHandler;
        private static Eds.EdsStateEventHandler _stateHandler;

        // =====================================================================
        private static int Main(string[] args)
        {
            _stdout = Console.OpenStandardOutput();

            for (int i = 0; i < args.Length; i++)
            {
                switch (args[i])
                {
                    case "--wait":
                        if (i + 1 < args.Length) int.TryParse(args[++i], out _waitSeconds);
                        break;
                    case "--evf-fps":
                        if (i + 1 < args.Length)
                        {
                            int fps;
                            if (int.TryParse(args[++i], out fps) && fps > 0)
                                _evfMinIntervalMs = Math.Max(1, 1000 / Math.Min(fps, 60));
                        }
                        break;
                    case "--save-to-camera":
                        _saveToCamera = true;
                        break;
                    case "--keep-quality":
                        _keepQuality = true;
                        break;
                    case "--evf-small":
                        _evfSmall = true;
                        break;
                    case "--bench":
                        _bench = true;
                        break;
                    case "--idle-timeout":
                        if (i + 1 < args.Length)
                        {
                            int sec;
                            if (int.TryParse(args[++i], out sec) && sec > 0)
                                _idleTimeoutMs = sec * 1000;
                        }
                        break;
                    case "--af-mode":
                        if (i + 1 < args.Length)
                        {
                            switch (args[++i].ToLowerInvariant())
                            {
                                case "quick": _afMode = 0; break;
                                case "live": _afMode = 1; break;
                                case "face": _afMode = 2; break;
                                case "multi": _afMode = 3; break;
                                case "keep": _afMode = -1; break;
                            }
                        }
                        break;
                    case "--quality":
                        if (i + 1 < args.Length)
                        {
                            string q = args[++i];
                            if (q.StartsWith("0x", StringComparison.OrdinalIgnoreCase)) q = q.Substring(2);
                            uint parsed;
                            if (uint.TryParse(q, System.Globalization.NumberStyles.HexNumber, null, out parsed))
                                _forcedQuality = parsed;
                        }
                        break;
                    case "--list":
                        return ListOnly();
                }
            }

            StartWriter();

            int exitCode = 0;
            var sdkThread = new Thread(() => exitCode = SdkThread());
            sdkThread.IsBackground = false;
            sdkThread.SetApartmentState(ApartmentState.STA);
            sdkThread.Start();

            if (_bench)
            {
                // Bench tidak menerima perintah; cukup tunggu sampai selesai.
                // (Kalau tetap membaca stdin, prosesnya menggantung di
                // ReadFile pada konsol setelah bench-nya rampung.)
                sdkThread.Join(300000);
                return exitCode;
            }

            // Pembacaan stdin WAJIB di thread background, bukan di thread
            // utama. ReadFile pada pipe memblokir sampai ada data atau pipe
            // ditutup — dan app yang memegang ujung pipe bisa saja diam
            // selamanya tanpa menutupnya. Kalau ini dijalankan di thread
            // utama, proses tetap hidup memegang kamera meski thread EDSDK
            // sudah selesai (mis. watchdog idle memicu). Terbukti 2026-08-24:
            // watchdog menyala dan melepas kamera, tapi prosesnya bertahan
            // >45 detik. Sebagai thread background, ia tidak menahan proses.
            var stdinThread = new Thread(() =>
            {
                try { ReadCommandsFromStdin(); }
                catch (Exception ex) { Console.Error.WriteLine("ERR STDIN " + ex.Message); }
                _quit = true; // stdin tertutup = app hilang
            });
            stdinThread.IsBackground = true;
            stdinThread.Start();

            // Tunggu kerja EDSDK-nya yang selesai — entah karena QUIT, stdin
            // tertutup, watchdog idle, atau kamera dicabut.
            sdkThread.Join();
            // Beri kesempatan foto yang masih antre benar-benar terkirim
            // sebelum proses berakhir.
            _qSignal.Set();
            if (_writerThread != null) _writerThread.Join(3000);
            return exitCode;
        }

        // Baca baris perintah dari stdin memakai ReadFile langsung.
        // Kembali saat menerima QUIT atau saat pipe ditutup (parent mati).
        private static void ReadCommandsFromStdin()
        {
            IntPtr h = GetStdHandle(STD_INPUT_HANDLE);
            if (h == IntPtr.Zero || h == new IntPtr(-1))
            {
                Console.Error.WriteLine("ERR STDIN handle tidak tersedia");
                return;
            }

            var buf = new byte[4096];
            var line = new StringBuilder();
            while (true)
            {
                uint read;
                if (!ReadFile(h, buf, (uint)buf.Length, out read, IntPtr.Zero) || read == 0)
                    return; // pipe ditutup / parent mati

                for (int i = 0; i < read; i++)
                {
                    byte b = buf[i];
                    if (b == (byte)'\n')
                    {
                        string cmd = line.ToString().Trim();
                        line.Length = 0;
                        if (cmd.Length == 0) continue;
                        _commands.Enqueue(cmd);
                        if (cmd.Equals("QUIT", StringComparison.OrdinalIgnoreCase)) return;
                    }
                    else if (b != (byte)'\r')
                    {
                        // Buang byte non-ASCII di AWAL baris. StreamWriter
                        // .NET/PowerShell menyisipkan BOM UTF-8 (EF BB BF)
                        // pada tulisan pertama; dulu tersembunyi karena
                        // Console.In membuangnya, tapi kita membaca byte
                        // mentah sehingga BOM ikut masuk dan merusak
                        // perintah pertama ("﻿LIVEVIEW"). Perintah
                        // selalu ASCII, jadi ini aman.
                        if (line.Length == 0 && b >= 0x80) continue;
                        line.Append((char)b);
                    }
                }
            }
        }

        // =====================================================================
        private static int ListOnly()
        {
            uint err = Eds.EdsInitializeSDK();
            if (err != Eds.EDS_ERR_OK) { Err(err, "EdsInitializeSDK gagal"); return 4; }
            try
            {
                IntPtr cam;
                string model, port;
                if (!FindCamera(out cam, out model, out port))
                {
                    Console.Error.WriteLine("ERR NO_CAMERA tidak ada kamera Canon terhubung");
                    return 2;
                }
                Console.Error.WriteLine("READY model=" + model + " port=" + port);
                Eds.EdsRelease(cam);
                return 0;
            }
            finally { Eds.EdsTerminateSDK(); }
        }

        // =====================================================================
        // Seluruh pemanggilan EDSDK terjadi HANYA di thread ini.
        private static int SdkThread()
        {
            uint err = Eds.EdsInitializeSDK();
            if (err != Eds.EDS_ERR_OK) { Err(err, "EdsInitializeSDK gagal"); return 4; }

            try
            {
                string model = null, port = null;
                var deadline = Stopwatch.StartNew();
                while (!_quit)
                {
                    if (FindCamera(out _camera, out model, out port)) break;
                    if (deadline.Elapsed.TotalSeconds >= _waitSeconds)
                    {
                        Console.Error.WriteLine("ERR NO_CAMERA tidak ada kamera Canon terhubung " +
                                                "(pastikan kamera menyala, mode M/Av/Tv, dan " +
                                                "EOS Webcam Utility tidak sedang memakainya)");
                        return 2;
                    }
                    PumpMessages();
                    Thread.Sleep(300);
                }
                if (_quit) return 0;

                err = Eds.EdsOpenSession(_camera);
                if (err != Eds.EDS_ERR_OK)
                {
                    // Penyebab paling sering di mesin ini: EOS Webcam Utility
                    // masih memegang kamera secara eksklusif.
                    Err(err, err == Eds.EDS_ERR_DEVICE_BUSY || err == Eds.EDS_ERR_DEVICE_INVALID
                        ? "EdsOpenSession gagal — kamera dipakai aplikasi lain " +
                          "(tutup EOS Webcam Utility / digiCamControl / EOS Utility)"
                        : "EdsOpenSession gagal");
                    return 3;
                }
                _sessionOpen = true;

                // SaveTo=Host → foto dikirim ke PC lewat USB, tidak menunggu
                // penulisan kartu SD. SetCapacity wajib, kalau tidak kamera
                // mengira host kehabisan ruang dan menolak transfer.
                SetPropU32(_camera, Eds.PropID_SaveTo, _saveToCamera ? Eds.SaveTo_Both : Eds.SaveTo_Host);
                ApplyCapacity();
                EnsureImageQuality();

                _objectHandler = OnObjectEvent;
                _stateHandler = OnStateEvent;
                Eds.EdsSetObjectEventHandler(_camera, Eds.ObjectEvent_All, _objectHandler, IntPtr.Zero);
                Eds.EdsSetCameraStateEventHandler(_camera, Eds.StateEvent_All, _stateHandler, IntPtr.Zero);

                string product = GetPropStr(_camera, Eds.PropID_ProductName) ?? model;
                Console.Error.WriteLine("READY model=" + product + " port=" + port);

                if (_bench) { RunBench(); return 0; }

                _lastCommandTicks = Environment.TickCount; // mulai hitung watchdog
                MainLoop();
                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("ERR EXCEPTION " + ex.GetType().Name + ": " + ex.Message);
                return 4;
            }
            finally
            {
                try
                {
                    if (_liveViewOn) SetLiveView(false);
                    if (_sessionOpen) Eds.EdsCloseSession(_camera);
                    if (_camera != IntPtr.Zero) Eds.EdsRelease(_camera);
                }
                catch { }
                Eds.EdsTerminateSDK();
            }
        }

        // =====================================================================
        // BENCH — ukur fps EVF di beberapa setelan kamera.
        //
        // Tujuannya menjawab: apakah ~11fps itu benar-benar plafon body, atau
        // ada setelan (deteksi wajah per-frame, histogram, dsb) yang diam-diam
        // memakan waktu di tiap frame. Frame TIDAK dikirim ke stdout selama
        // bench — tidak ada yang membacanya, pipe akan penuh dan memblokir.
        // =====================================================================
        private static void RunBench()
        {
            uint afMode = 0;
            bool afReadable =
                GetPropU32(_camera, Eds.PropID_Evf_AFMode, out afMode) == Eds.EDS_ERR_OK;
            Console.Error.WriteLine("LOG BENCH mulai. Evf_AFMode awal = " +
                (afReadable ? "0x" + afMode.ToString("X2") : "tidak terbaca"));

            SetLiveView(true);
            Thread.Sleep(1500);

            BenchOne("baseline", 0, 0);
            BenchOne("AFMode=Quick", Eds.PropID_Evf_AFMode, 0);
            BenchOne("AFMode=Live", Eds.PropID_Evf_AFMode, 1);
            BenchOne("AFMode=LiveFace", Eds.PropID_Evf_AFMode, 2);
            BenchOne("Histogram=OFF", Eds.PropID_Evf_Histogram, 0);
            BenchOne("DoFPreview=OFF", Eds.PropID_Evf_DepthOfFieldPreview, 0);

            if (afReadable) SetPropU32(_camera, Eds.PropID_Evf_AFMode, afMode);
            SetLiveView(false);
            Console.Error.WriteLine("LOG BENCH selesai.");
        }

        private static void BenchOne(string name, uint propId, uint value)
        {
            if (propId != 0)
            {
                uint e = SetPropU32(_camera, propId, value);
                if (e != Eds.EDS_ERR_OK)
                {
                    Console.Error.WriteLine(string.Format(
                        "LOG BENCH {0,-16} DITOLAK body (err=0x{1:X8})", name, e));
                    return;
                }
                Thread.Sleep(900); // beri waktu setelan meresap
            }

            // Buang beberapa frame pertama supaya transisi setelan tidak terhitung.
            for (int i = 0; i < 5; i++) { PumpMessages(); GrabEvfFrame(); }

            _evfFrames = 0; _evfBytes = 0; _tDownload = 0;
            var sw = Stopwatch.StartNew();
            while (sw.Elapsed.TotalSeconds < 5.0)
            {
                PumpMessages();
                GrabEvfFrame();
            }
            double secs = sw.Elapsed.TotalSeconds;
            int n = Math.Max(_evfFrames, 1);
            double ms = 1000.0 / Stopwatch.Frequency / n;
            Console.Error.WriteLine(string.Format(
                "LOG BENCH {0,-16} fps={1,5:0.0}  avg={2,4:0}KB  download={3,5:0.0}ms",
                name, _evfFrames / secs, _evfBytes / 1024.0 / n, _tDownload * ms));
        }

        // =====================================================================
        private static void MainLoop()
        {
            while (!_quit)
            {
                PumpMessages();
                ProcessCommands();
                PollAutoFocus();

                if (_idleTimeoutMs > 0 &&
                    Environment.TickCount - _lastCommandTicks > _idleTimeoutMs)
                {
                    Console.Error.WriteLine("ERR IDLE app berhenti menyapa " +
                        (_idleTimeoutMs / 1000) + " detik — melepas kamera dan keluar");
                    _quit = true;
                    break;
                }

                if (_capturePending && Environment.TickCount > _captureDeadlineTicks)
                {
                    _capturePending = false;
                    Console.Error.WriteLine("EVENT CAPTURE_FAIL timeout");
                }

                // Cegah kamera auto-off saat booth menganggur.
                if (Environment.TickCount - _lastTimerExtendTicks > 30000)
                {
                    _lastTimerExtendTicks = Environment.TickCount;
                    Eds.EdsSendCommand(_camera, Eds.CameraCommand_ExtendShutDownTimer, 0);
                }

                bool grabbed = false;
                if (_liveViewOn && Environment.TickCount - _lastEvfTicks >= _evfMinIntervalMs)
                {
                    _lastEvfTicks = Environment.TickCount;
                    grabbed = GrabEvfFrame();
                }

                // Live view sempat mati sendiri (mis. setelah mirror flip saat
                // jepret, atau kamera keluar dari mode LV) → pasang ulang.
                if (_liveViewWanted && _liveViewOn && !_capturePending &&
                    Environment.TickCount - _lastEvfOkTicks > 2500)
                {
                    Log("live view stall → re-arm EVF output device");
                    _lastEvfOkTicks = Environment.TickCount;
                    ArmEvfOutputDevice();
                }

                // Laporkan fps yang DIUKUR BRIDGE, bukan yang dilihat pembaca
                // pipe — kalau keduanya beda jauh, berarti konsumennya yang
                // lambat, bukan kamera/USB-nya.
                if (_evfFrames > 0 && Environment.TickCount - _statsTicks >= 5000)
                {
                    double secs = (Environment.TickCount - _statsTicks) / 1000.0;
                    double ms = 1000.0 / Stopwatch.Frequency / _evfFrames;
                    Log(string.Format(
                        "evf fps={0:0.0} avg={1:0}KB | create={2:0.0}ms download={3:0.0}ms " +
                        "copy={4:0.0}ms enqueue={5:0.0}ms dropped={6}",
                        _evfFrames / secs, _evfBytes / 1024.0 / _evfFrames,
                        _tCreate * ms, _tDownload * ms, _tCopy * ms, _tWrite * ms, _droppedEvf));
                    _evfFrames = 0;
                    _evfBytes = 0;
                    _droppedEvf = 0;
                    _tCreate = _tDownload = _tCopy = _tWrite = 0;
                    _statsTicks = Environment.TickCount;
                }

                if (!grabbed) Thread.Sleep(_liveViewOn ? 2 : 15);
            }
        }

        private static void PumpMessages()
        {
            MSG msg;
            int guard = 0;
            while (PeekMessage(out msg, IntPtr.Zero, 0, 0, PM_REMOVE) && guard++ < 64)
            {
                TranslateMessage(ref msg);
                DispatchMessage(ref msg);
            }
        }

        private static void ProcessCommands()
        {
            string cmd;
            while (_commands.TryDequeue(out cmd))
            {
                _lastCommandTicks = Environment.TickCount; // tanda app masih hidup
                var parts = cmd.Split(' ');
                switch (parts[0].ToUpperInvariant())
                {
                    case "PING":
                        Console.Error.WriteLine("EVENT PONG");
                        break;

                    case "LIVEVIEW":
                        if (parts.Length > 1 && parts[1].Equals("ON", StringComparison.OrdinalIgnoreCase))
                        {
                            if (parts.Length > 2)
                            {
                                int fps;
                                if (int.TryParse(parts[2], out fps) && fps > 0)
                                    _evfMinIntervalMs = Math.Max(1, 1000 / Math.Min(fps, 60));
                            }
                            SetLiveView(true);
                        }
                        else SetLiveView(false);
                        break;

                    case "AF":
                        DoAutoFocus();
                        break;

                    case "CAPTURE":
                        DoCapture(parts.Length > 1 && parts[1].Equals("AF", StringComparison.OrdinalIgnoreCase));
                        break;

                    case "INFO":
                        DumpInfo();
                        break;

                    case "QUIT":
                        _quit = true;
                        break;

                    default:
                        Console.Error.WriteLine("ERR UNKNOWN_COMMAND " + parts[0]);
                        break;
                }
            }
        }

        // =====================================================================
        // Live view
        // =====================================================================
        private static void SetLiveView(bool on)
        {
            _liveViewWanted = on;
            if (on == _liveViewOn) return;

            if (on)
            {
                // Evf_Mode harus 1 sebelum output device dialihkan ke PC.
                // Sebagian body menolak diam-diam kalau urutannya dibalik.
                SetPropU32(_camera, Eds.PropID_Evf_Mode, 1);
                if (!ArmEvfOutputDevice()) return;
                _liveViewOn = true;
                _lastEvfOkTicks = Environment.TickCount;
                ApplyAfMode(); // baru bisa diatur setelah EVF menyala
                Console.Error.WriteLine("EVENT LIVEVIEW=ON");
                // Eksposur ikut menentukan laju refresh EVF: di ruangan gelap
                // kamera memperpanjang waktu per frame dan fps ikut turun.
                DumpInfo();
            }
            else
            {
                uint device;
                if (GetPropU32(_camera, Eds.PropID_Evf_OutputDevice, out device) == Eds.EDS_ERR_OK)
                {
                    device &= ~Eds.EvfOutputDevice_PC;
                    SetPropU32(_camera, Eds.PropID_Evf_OutputDevice, device);
                }
                SetPropU32(_camera, Eds.PropID_Evf_Mode, 0);
                _liveViewOn = false;
                Console.Error.WriteLine("EVENT LIVEVIEW=OFF");
            }
        }

        // Pilih mode AF live view. Ini penentu fps terbesar yang kita punya —
        // lihat tabel pengukuran di deklarasi _afMode.
        private static void ApplyAfMode()
        {
            if (_afMode < 0) return; // --af-mode keep

            uint cur;
            if (GetPropU32(_camera, Eds.PropID_Evf_AFMode, out cur) != Eds.EDS_ERR_OK) return;
            if (cur == (uint)_afMode) return;

            uint err = SetPropU32(_camera, Eds.PropID_Evf_AFMode, (uint)_afMode);
            if (err == Eds.EDS_ERR_OK)
                Log("Evf_AFMode: 0x" + cur.ToString("X2") + " -> 0x" + _afMode.ToString("X2"));
            else
                Err(err, "set Evf_AFMode gagal (tetap 0x" + cur.ToString("X2") + ")");
        }

        private static bool ArmEvfOutputDevice()
        {
            uint device;
            uint err = GetPropU32(_camera, Eds.PropID_Evf_OutputDevice, out device);
            if (err != Eds.EDS_ERR_OK) { Err(err, "baca Evf_OutputDevice gagal"); return false; }
            // PC_SMALL meminta frame EVF berukuran lebih kecil → transfer USB
            // lebih ringan. Tidak semua body mendukungnya (100D generasi 2013
            // kemungkinan besar tidak), jadi selalu sediakan jalur mundur.
            if (_evfSmall)
            {
                uint small = (device | Eds.EvfOutputDevice_PC_Small) & ~Eds.EvfOutputDevice_PC;
                if (SetPropU32(_camera, Eds.PropID_Evf_OutputDevice, small) == Eds.EDS_ERR_OK)
                {
                    Log("Evf_OutputDevice=PC_SMALL diterima body ini");
                    return true;
                }
                Log("body menolak PC_SMALL → pakai PC biasa");
            }

            device |= Eds.EvfOutputDevice_PC;
            err = SetPropU32(_camera, Eds.PropID_Evf_OutputDevice, device);
            if (err != Eds.EDS_ERR_OK) { Err(err, "set Evf_OutputDevice=PC gagal"); return false; }
            return true;
        }

        // Ambil satu frame EVF. Return true bila ada frame yang benar-benar
        // dikirim (dipakai untuk mengatur ritme sleep loop).
        private static bool GrabEvfFrame()
        {
            IntPtr stream = IntPtr.Zero, evfImage = IntPtr.Zero;
            long t0 = Stopwatch.GetTimestamp();
            try
            {
                uint err = Eds.EdsCreateMemoryStream(EvfStreamPrealloc, out stream);
                if (err != Eds.EDS_ERR_OK) return false;

                err = Eds.EdsCreateEvfImageRef(stream, out evfImage);
                if (err != Eds.EDS_ERR_OK) return false;

                long t1 = Stopwatch.GetTimestamp();
                err = Eds.EdsDownloadEvfImage(_camera, evfImage);
                long t2 = Stopwatch.GetTimestamp();
                if (err != Eds.EDS_ERR_OK)
                {
                    // OBJECT_NOTREADY & DEVICE_BUSY normal terjadi: kamera
                    // belum siap / sedang sibuk menjepret. Jangan spam log.
                    if (err != Eds.EDS_ERR_OBJECT_NOTREADY && err != Eds.EDS_ERR_DEVICE_BUSY)
                        Err(err, "EdsDownloadEvfImage gagal");
                    if (err == Eds.EDS_ERR_COMM_DISCONNECTED)
                    {
                        Console.Error.WriteLine("EVENT DISCONNECTED");
                        _quit = true;
                    }
                    return false;
                }

                IntPtr ptr;
                ulong len;
                if (Eds.EdsGetPointer(stream, out ptr) != Eds.EDS_ERR_OK) return false;
                if (Eds.EdsGetLength(stream, out len) != Eds.EDS_ERR_OK) return false;
                if (ptr == IntPtr.Zero || len == 0) return false;

                var buf = new byte[len];
                Marshal.Copy(ptr, buf, 0, (int)len);
                long t3 = Stopwatch.GetTimestamp();
                if (!_bench) EnqueueEvf(buf); // saat bench tak ada yang membaca pipe
                long t4 = Stopwatch.GetTimestamp();

                _lastEvfOkTicks = Environment.TickCount;
                if (_statsTicks == 0) _statsTicks = Environment.TickCount;
                _evfFrames++;
                _evfBytes += buf.Length;
                _tCreate += t1 - t0;
                _tDownload += t2 - t1;
                _tCopy += t3 - t2;
                _tWrite += t4 - t3;
                return true;
            }
            finally
            {
                if (evfImage != IntPtr.Zero) Eds.EdsRelease(evfImage);
                if (stream != IntPtr.Zero) Eds.EdsRelease(stream);
            }
        }

        // =====================================================================
        // Autofocus & jepret
        // =====================================================================
        private static void DoAutoFocus()
        {
            if (!_liveViewOn)
            {
                Console.Error.WriteLine("EVENT AF_FAIL liveview_off");
                return;
            }

            _afResultSeen = false;
            _afResultParam = 0;

            uint err = Eds.EdsSendCommand(_camera, Eds.CameraCommand_DoEvfAf, 1);
            if (err != Eds.EDS_ERR_OK)
            {
                Console.Error.WriteLine("EVENT AF_FAIL err=0x" + err.ToString("X8"));
                return;
            }

            // AF berjalan TANPA memblokir loop utama. Kalau ditunggu di sini,
            // seluruh thread EDSDK berhenti melayani perintah — dan karena
            // bodi ini tak pernah mengirim AfResult, jendelanya SELALU habis
            // penuh, sehingga CAPTURE yang datang saat countdown selesai ikut
            // tertahan. Penyelesaiannya ditangani MainLoop lewat _afDeadline.
            _afRunning = true;
            _afDeadline = Environment.TickCount + AfWindowMs;
        }

        // Akhiri AF bila kamera sudah melapor atau jendelanya habis.
        private static void PollAutoFocus()
        {
            if (!_afRunning) return;
            if (!_afResultSeen && Environment.TickCount < _afDeadline) return;

            _afRunning = false;
            Eds.EdsSendCommand(_camera, Eds.CameraCommand_DoEvfAf, 0);

            // "unconfirmed" = AF dijalankan sampai tuntas, hanya saja bodi ini
            // tidak mengirim AfResult. Ini kondisi NORMAL di EOS 100D, bukan
            // kegagalan — laporkan apa adanya supaya log tidak menyesatkan.
            Console.Error.WriteLine(_afResultSeen
                ? "EVENT AF_DONE result=" + _afResultParam
                : "EVENT AF_DONE unconfirmed (bodi tidak mengirim AfResult)");
        }

        private static void DoCapture(bool withAf)
        {
            Console.Error.WriteLine("EVENT CAPTURE_BEGIN");
            _captureStartTicks = Stopwatch.GetTimestamp();
            ApplyCapacity();

            uint err;
            int attempt = 0;
            do
            {
                if (withAf)
                {
                    err = Eds.EdsSendCommand(_camera, Eds.CameraCommand_TakePicture, 0);
                }
                else
                {
                    // Non-AF: fokus sudah dikunci lewat perintah AF di awal
                    // sesi, jadi shutter tidak perlu menunggu lensa hunting.
                    err = Eds.EdsSendCommand(_camera, Eds.CameraCommand_PressShutterButton,
                                             Eds.ShutterButton_Completely_NonAF);
                    Eds.EdsSendCommand(_camera, Eds.CameraCommand_PressShutterButton,
                                       Eds.ShutterButton_OFF);
                }

                if (err == Eds.EDS_ERR_DEVICE_BUSY && attempt < 4)
                {
                    // Kamera masih menulis buffer foto sebelumnya.
                    for (int i = 0; i < 12; i++) { PumpMessages(); Thread.Sleep(25); }
                    attempt++;
                    continue;
                }
                break;
            } while (true);

            if (err != Eds.EDS_ERR_OK)
            {
                Console.Error.WriteLine("EVENT CAPTURE_FAIL err=0x" + err.ToString("X8"));
                return;
            }

            _capturePending = true;
            _captureDeadlineTicks = Environment.TickCount + 15000;
        }

        // =====================================================================
        // Kualitas gambar
        //
        // Body bisa saja tertinggal di setelan S1/S2 dari pemakaian sebelumnya
        // — dan EDSDK akan menurut saja, sehingga foto keluar 4,5MP bukan 18MP.
        // Untuk photobooth kita selalu mau JPEG Large Fine.
        // =====================================================================
        private static void EnsureImageQuality()
        {
            uint current;
            if (GetPropU32(_camera, Eds.PropID_ImageQuality, out current) != Eds.EDS_ERR_OK)
            {
                Log("tidak bisa membaca ImageQuality");
                return;
            }

            if (_keepQuality)
            {
                Log("image quality dibiarkan apa adanya: 0x" + current.ToString("X8"));
                return;
            }

            uint target = _forcedQuality != 0 ? _forcedQuality : PickBestJpeg();
            if (target == 0 || target == current)
            {
                Log("image quality: 0x" + current.ToString("X8") + " (sudah optimal)");
                return;
            }

            uint err = SetPropU32(_camera, Eds.PropID_ImageQuality, target);
            if (err == Eds.EDS_ERR_OK)
                Log("image quality: 0x" + current.ToString("X8") + " -> 0x" + target.ToString("X8"));
            else
                Err(err, "gagal set ImageQuality ke 0x" + target.ToString("X8") +
                         " (tetap di 0x" + current.ToString("X8") + ")");
        }

        // Pilih dari daftar nilai yang BENAR-BENAR didukung body ini, bukan
        // dari konstanta hafalan — beda body menawarkan kombinasi berbeda.
        private static uint PickBestJpeg()
        {
            Eds.EdsPropertyDesc desc;
            if (Eds.EdsGetPropertyDesc(_camera, Eds.PropID_ImageQuality, out desc) == Eds.EDS_ERR_OK &&
                desc.NumElements > 0 && desc.PropDesc != null)
            {
                uint best = 0;
                int bestScore = 0;
                int n = Math.Min(desc.NumElements, desc.PropDesc.Length);
                for (int i = 0; i < n; i++)
                {
                    uint v = unchecked((uint)desc.PropDesc[i]);
                    int score = ScoreJpegQuality(v);
                    if (score > bestScore) { bestScore = score; best = v; }
                }
                if (bestScore > 0) return best;
                Log("body tidak menawarkan JPEG Large — pakai konstanta default");
            }
            return Eds.ImageQuality_LargeFineJpeg;
        }

        // Skor tinggi = JPEG saja, ukuran Large, kompresi paling halus.
        // Nilai negatif = tidak dipakai.
        private static int ScoreJpegQuality(uint v)
        {
            uint size1 = (v >> 24) & 0xFF;
            uint qual1 = (v >> 16) & 0xFF;
            uint size2 = (v >> 8) & 0xFF;
            uint qual2 = v & 0xFF;

            // Slot kedua terisi = RAW+JPEG → dua file tiap jepret, memperlambat
            // transfer dan tidak ada gunanya untuk cetak photobooth.
            if (size2 != 0xFF || qual2 != 0x0F) return -1;
            if ((qual1 & 0xF0) != 0x10) return -1; // 0x6x = RAW, bukan JPEG
            if (size1 != 0x00) return -1;          // bukan Large
            return 100 - (int)(qual1 & 0x0F);      // 0x10 Fine > 0x13 Normal
        }

        private static void ApplyCapacity()
        {
            // Angka besar = "host masih lega". Reset=1 memberi tahu kamera
            // untuk memperbarui perhitungan sisa jepretan.
            var cap = new Eds.EdsCapacity
            {
                NumberOfFreeClusters = 0x7FFFFFFF,
                BytesPerSector = 0x1000,
                Reset = 1
            };
            Eds.EdsSetCapacity(_camera, cap);
        }

        // =====================================================================
        // Event dari EDSDK (dipanggil di thread ini lewat message pump)
        // =====================================================================
        private static uint OnObjectEvent(uint inEvent, IntPtr inRef, IntPtr inContext)
        {
            try
            {
                if (inEvent == Eds.ObjectEvent_DirItemRequestTransfer ||
                    inEvent == Eds.ObjectEvent_DirItemCreated)
                {
                    DownloadItem(inRef);
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("ERR DOWNLOAD " + ex.Message);
            }
            finally
            {
                if (inRef != IntPtr.Zero) Eds.EdsRelease(inRef);
            }
            return 0;
        }

        private static void DownloadItem(IntPtr dirItem)
        {
            Eds.EdsDirectoryItemInfo info;
            uint err = Eds.EdsGetDirectoryItemInfo(dirItem, out info);
            if (err != Eds.EDS_ERR_OK) { Err(err, "EdsGetDirectoryItemInfo gagal"); return; }

            // SaveTo=Both memunculkan DirItemCreated *dan* DirItemRequestTransfer
            // untuk file yang sama → jangan kirim dua kali ke Flutter.
            string key = info.szFileName + ":" + info.Size;
            if (key == _lastDownloadKey) return;
            _lastDownloadKey = key;

            // Waktu dari perintah shutter sampai kamera memberi tahu "file siap"
            // (mirror flip + eksposur + tulis buffer internal).
            long tEvent = Stopwatch.GetTimestamp();

            IntPtr stream = IntPtr.Zero;
            try
            {
                err = Eds.EdsCreateMemoryStream(info.Size, out stream);
                if (err != Eds.EDS_ERR_OK) { Err(err, "EdsCreateMemoryStream gagal"); return; }

                err = Eds.EdsDownload(dirItem, info.Size, stream);
                if (err != Eds.EDS_ERR_OK)
                {
                    Eds.EdsDownloadCancel(dirItem);
                    Err(err, "EdsDownload gagal");
                    return;
                }
                Eds.EdsDownloadComplete(dirItem);

                IntPtr ptr;
                ulong len;
                if (Eds.EdsGetPointer(stream, out ptr) != Eds.EDS_ERR_OK) return;
                if (Eds.EdsGetLength(stream, out len) != Eds.EDS_ERR_OK) return;
                if (ptr == IntPtr.Zero || len == 0) return;

                var buf = new byte[len];
                Marshal.Copy(ptr, buf, 0, (int)len);
                EnqueuePhoto(buf);

                _capturePending = false;

                // Pecah waktunya supaya jelas mana yang bisa dikejar: kamera
                // (shutter->siap) atau transfer USB (download).
                double f = 1000.0 / Stopwatch.Frequency;
                double msShutter = (tEvent - _captureStartTicks) * f;
                double msDownload = (Stopwatch.GetTimestamp() - tEvent) * f;
                Console.Error.WriteLine(string.Format(
                    "EVENT CAPTURE_DONE file={0} bytes={1} shutter={2:0}ms download={3:0}ms total={4:0}ms",
                    info.szFileName, len, msShutter, msDownload, msShutter + msDownload));

                // Setelah mirror turun lagi, EVF sering perlu di-arm ulang.
                if (_liveViewWanted && _liveViewOn) ArmEvfOutputDevice();
            }
            finally
            {
                if (stream != IntPtr.Zero) Eds.EdsRelease(stream);
            }
        }

        private static uint OnStateEvent(uint inEvent, uint inParameter, IntPtr inContext)
        {
            switch (inEvent)
            {
                case Eds.StateEvent_Shutdown:
                    Console.Error.WriteLine("EVENT DISCONNECTED");
                    _quit = true;
                    break;
                case Eds.StateEvent_WillSoonShutDown:
                    Eds.EdsSendCommand(_camera, Eds.CameraCommand_ExtendShutDownTimer, 0);
                    break;
                case Eds.StateEvent_CaptureError:
                    _capturePending = false;
                    Console.Error.WriteLine("EVENT CAPTURE_FAIL capture_error param=" + inParameter);
                    break;
                case Eds.StateEvent_InternalError:
                    Console.Error.WriteLine("ERR INTERNAL param=" + inParameter);
                    break;
                case Eds.StateEvent_AfResult:
                    // Satu-satunya kabar dari kamera bahwa AF benar-benar
                    // selesai (berhasil maupun gagal mengunci).
                    _afResultParam = inParameter;
                    _afResultSeen = true;
                    break;
            }
            return 0;
        }

        // =====================================================================
        // Util
        // =====================================================================
        private static bool FindCamera(out IntPtr camera, out string model, out string port)
        {
            camera = IntPtr.Zero;
            model = null;
            port = null;

            IntPtr list = IntPtr.Zero;
            try
            {
                if (Eds.EdsGetCameraList(out list) != Eds.EDS_ERR_OK) return false;
                int count;
                if (Eds.EdsGetChildCount(list, out count) != Eds.EDS_ERR_OK || count <= 0) return false;
                if (Eds.EdsGetChildAtIndex(list, 0, out camera) != Eds.EDS_ERR_OK) return false;

                Eds.EdsDeviceInfo info;
                if (Eds.EdsGetDeviceInfo(camera, out info) == Eds.EDS_ERR_OK)
                {
                    model = info.szDeviceDescription;
                    port = info.szPortName;
                }
                return true;
            }
            finally
            {
                if (list != IntPtr.Zero) Eds.EdsRelease(list);
            }
        }

        private static void DumpInfo()
        {
            uint iso, av, tv, aeMode, shots;
            GetPropU32(_camera, Eds.PropID_ISOSpeed, out iso);
            GetPropU32(_camera, Eds.PropID_Av, out av);
            GetPropU32(_camera, Eds.PropID_Tv, out tv);
            GetPropU32(_camera, Eds.PropID_AEMode, out aeMode);
            GetPropU32(_camera, Eds.PropID_AvailableShots, out shots);
            Console.Error.WriteLine(string.Format(
                "EVENT INFO iso=0x{0:X2} av=0x{1:X2} tv=0x{2:X2} aemode=0x{3:X2} shots={4} liveview={5}",
                iso, av, tv, aeMode, shots, _liveViewOn ? "on" : "off"));
        }

        private static uint SetPropU32(IntPtr cam, uint prop, uint val)
        {
            IntPtr p = Marshal.AllocHGlobal(4);
            try
            {
                Marshal.WriteInt32(p, unchecked((int)val));
                return Eds.EdsSetPropertyData(cam, prop, 0, 4, p);
            }
            finally { Marshal.FreeHGlobal(p); }
        }

        private static uint GetPropU32(IntPtr cam, uint prop, out uint val)
        {
            IntPtr p = Marshal.AllocHGlobal(4);
            try
            {
                Marshal.WriteInt32(p, 0);
                uint err = Eds.EdsGetPropertyData(cam, prop, 0, 4, p);
                val = unchecked((uint)Marshal.ReadInt32(p));
                return err;
            }
            finally { Marshal.FreeHGlobal(p); }
        }

        private static string GetPropStr(IntPtr cam, uint prop)
        {
            IntPtr p = Marshal.AllocHGlobal(256);
            try
            {
                for (int i = 0; i < 256; i++) Marshal.WriteByte(p, i, 0);
                if (Eds.EdsGetPropertyData(cam, prop, 0, 256, p) != Eds.EDS_ERR_OK) return null;
                return Marshal.PtrToStringAnsi(p);
            }
            finally { Marshal.FreeHGlobal(p); }
        }

        // =====================================================================
        // Penulisan ke stdout dilakukan thread TERPISAH.
        //
        // Kalau ditulis langsung dari thread EDSDK, konsumen yang lambat
        // (pipe penuh) akan memblokir thread itu — live view melambat DAN
        // event object (foto siap di-download) ikut tertunda. Di sini frame
        // live view boleh dibuang kalau konsumen tertinggal (yang terbaru
        // selalu menang), sedangkan FOTO tidak pernah dibuang.
        // =====================================================================
        private static readonly object _qLock = new object();
        private static byte[] _queuedEvf;
        private static readonly System.Collections.Generic.Queue<byte[]> _queuedPhotos =
            new System.Collections.Generic.Queue<byte[]>();
        private static readonly AutoResetEvent _qSignal = new AutoResetEvent(false);
        private static int _droppedEvf;
        private static Thread _writerThread;

        private static void StartWriter()
        {
            _writerThread = new Thread(WriterLoop);
            _writerThread.IsBackground = true;
            _writerThread.Start();
        }

        private static void EnqueueEvf(byte[] payload)
        {
            lock (_qLock)
            {
                if (_queuedEvf != null) _droppedEvf++; // konsumen tertinggal
                _queuedEvf = payload;
            }
            _qSignal.Set();
        }

        private static void EnqueuePhoto(byte[] payload)
        {
            lock (_qLock) { _queuedPhotos.Enqueue(payload); }
            _qSignal.Set();
        }

        private static void WriterLoop()
        {
            while (true)
            {
                _qSignal.WaitOne(200);
                while (true)
                {
                    byte[] photo = null, evf = null;
                    lock (_qLock)
                    {
                        if (_queuedPhotos.Count > 0) photo = _queuedPhotos.Dequeue();
                        else { evf = _queuedEvf; _queuedEvf = null; }
                    }
                    if (photo != null) WriteFrame(FrameTypePhoto, photo);
                    else if (evf != null) WriteFrame(FrameTypeEvf, evf);
                    else break;
                }
                if (_quit)
                {
                    lock (_qLock)
                    {
                        if (_queuedPhotos.Count == 0 && _queuedEvf == null) return;
                    }
                }
            }
        }

        private static void WriteFrame(uint type, byte[] payload)
        {
            try
            {
                WriteFrameUnsafe(type, payload);
            }
            catch (IOException)
            {
                // Pipe putus = app di seberang sudah tidak ada. Jangan
                // menggantung memegang kamera; ini lapis pengaman kedua
                // setelah watchdog idle.
                Console.Error.WriteLine("ERR PIPE stdout putus — app hilang, keluar");
                _quit = true;
            }
            catch (ObjectDisposedException)
            {
                _quit = true;
            }
        }

        private static void WriteFrameUnsafe(uint type, byte[] payload)
        {
            lock (_outLock)
            {
                var header = new byte[12];
                Buffer.BlockCopy(Magic, 0, header, 0, 4);
                WriteU32(header, 4, type);
                WriteU32(header, 8, (uint)payload.Length);
                _stdout.Write(header, 0, 12);
                _stdout.Write(payload, 0, payload.Length);
                _stdout.Flush();
            }
        }

        private static void WriteU32(byte[] buf, int offset, uint v)
        {
            buf[offset] = (byte)(v & 0xFF);
            buf[offset + 1] = (byte)((v >> 8) & 0xFF);
            buf[offset + 2] = (byte)((v >> 16) & 0xFF);
            buf[offset + 3] = (byte)((v >> 24) & 0xFF);
        }

        private static void Log(string msg)
        {
            Console.Error.WriteLine("LOG " + msg);
        }

        private static void Err(uint code, string msg)
        {
            Console.Error.WriteLine("ERR 0x" + code.ToString("X8") + " " + msg);
        }
    }
}
