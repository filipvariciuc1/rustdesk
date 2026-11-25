// rdp-view: shows one Remote Desktop session inside a RustDesk tab.
//
// RustDesk starts it (instead of mstsc) for a seat card, with the local end of
// the RDP tunnel (--port) and a loopback control port (--ctl) that the tab
// listens on. The tab sends, one per line:
//   parent <hwnd>            the RustDesk window to live in, as a child window
//   rect <x> <y> <w> <h> <s> where the tab's page is, physical px inside the
//                            Flutter view, s = display scale in percent
//   show | hide | focus
// and gets back "state connecting|connected|disconnected". It exits when the
// control socket closes (tab closed), the session ends, or the window is gone.
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace RdpView
{
    // "Microsoft RDP Client Control - version 10", hosted by CLSID (no aximp needed).
    public class RdpAx : AxHost
    {
        public RdpAx() : base("8B918B82-7985-4C24-89DF-C33AD2BBFBCD") { }
    }

    // Copied from nuc-seats SeatHost/Native.cs (vtable order read from mstscax.dll's type library, 11/23/2026).
    [ComImport, Guid("2F079C4C-87B2-4AFD-97AB-20CDB43038AE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMsRdpClientNonScriptable
    {
        void put_ClearTextPassword([MarshalAs(UnmanagedType.BStr)] string p);
    }

    [ComImport, Guid("4F6996D5-D7B1-412C-B0FF-063718566907"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMsRdpClientNonScriptable5
    {
        void s03(); void s04(); void s05(); void s06(); void s07(); void s08(); void s09(); void s10();
        void s11(); void s12(); void s13(); void s14(); void s15(); void s16(); void s17(); void s18();
        void put_PromptForCredentials([MarshalAs(UnmanagedType.VariantBool)] bool v);                       // 19
        void s20(); void s21(); void s22(); void s23(); void s24(); void s25(); void s26(); void s27(); void s28(); void s29(); void s30();
        void put_WarnAboutSendingCredentials([MarshalAs(UnmanagedType.VariantBool)] bool v);                // 31
        void s32(); void s33(); void s34(); void s35(); void s36(); void s37(); void s38(); void s39(); void s40(); void s41(); void s42(); void s43(); void s44();
        void put_AllowCredentialSaving([MarshalAs(UnmanagedType.VariantBool)] bool v);                      // 45
        void s46();
        void put_PromptForCredsOnClient([MarshalAs(UnmanagedType.VariantBool)] bool v);                     // 47
        void s48(); void s49(); void s50(); void s51(); void s52(); void s53(); void s54(); void s55(); void s56(); void s57(); void s58(); void s59(); void s60(); void s61(); void s62();
        void put_AllowPromptingForCredentials([MarshalAs(UnmanagedType.VariantBool)] bool v);               // 63
    }

    static class N
    {
        [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
        [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
        [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetParent(IntPtr child, IntPtr parent);
        [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
        [DllImport("user32.dll")] public static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string name);
        [DllImport("user32.dll")] public static extern int MapWindowPoints(IntPtr from, IntPtr to, ref POINT p, int n);
        public const int GWL_STYLE = -16, GWL_EXSTYLE = -20;
        public const int GWLP_HWNDPARENT = -8;
        public const long WS_POPUP = 0x80000000, WS_CHILD = 0x40000000, WS_CLIPSIBLINGS = 0x04000000, WS_CLIPCHILDREN = 0x02000000;
        public const long WS_EX_TOOLWINDOW = 0x80;
        public const uint SWP_NOACTIVATE = 0x10, SWP_FRAMECHANGED = 0x20, SWP_NOMOVE = 0x2, SWP_NOSIZE = 0x1, SWP_NOZORDER = 0x4;
        public const int SW_HIDE = 0, SW_SHOWNA = 8;
    }

    static class Log
    {
        static string file; static readonly object gate = new object();
        public static void Open()
        {
            try
            {
                var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "RustDesk", "log");
                Directory.CreateDirectory(dir);
                file = Path.Combine(dir, "rdp-view.log");
                var fi = new FileInfo(file);
                if (fi.Exists && fi.Length > 2_000_000) fi.Delete();
            }
            catch { }
        }
        public static void W(string s)
        {
            if (file == null) return;
            var line = DateTime.Now.ToString("MM/dd HH:mm:ss.fff") + " [" + Process.GetCurrentProcess().Id + "] " + s + Environment.NewLine;
            lock (gate)
                for (int i = 0; i < 5; i++)
                {
                    try { File.AppendAllText(file, line); return; } catch { Thread.Sleep(20); }
                }
        }
    }

    static class Program
    {
        [STAThread]
        static int Main(string[] args)
        {
            N.SetProcessDpiAwarenessContext((IntPtr)(-4)); // per-monitor v2, same as RustDesk
            Log.Open();
            int port = 0, ctl = 0;
            for (int i = 0; i + 1 < args.Length; i++)
            {
                if (args[i] == "--port") int.TryParse(args[i + 1], out port);
                if (args[i] == "--ctl") int.TryParse(args[i + 1], out ctl);
            }
            Log.W("start port=" + port + " ctl=" + ctl);
            if (port <= 0 || ctl <= 0) { Log.W("bad args: " + string.Join(" ", args)); return 2; }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new ViewForm(port, ctl));
            return 0;
        }

        public static void Quit(string why)
        {
            Log.W("exit: " + why);
            Environment.Exit(0);
        }
    }

    class ViewForm : Form
    {
        readonly int port, ctl;
        readonly RdpAx ax;
        dynamic ocx;
        TcpClient tcp;
        StreamWriter writer;
        readonly object sendGate = new object();
        readonly System.Windows.Forms.Timer tick = new System.Windows.Forms.Timer { Interval = 300 };
        // Follows the RustDesk window while it is dragged.
        readonly System.Windows.Forms.Timer follow = new System.Windows.Forms.Timer { Interval = 15 };
        IntPtr parent, flutterView;
        Rectangle want, placed;
        int scale = 100;
        bool started, sawActive, connected;
        DateTime startedAt, displayAt = DateTime.MaxValue;
        Size sessionSize; int sessionScale = 100;

        public ViewForm(int port, int ctl)
        {
            this.port = port; this.ctl = ctl;
            Text = "rdp-view";
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            Location = new Point(-32000, -32000); // until RustDesk hands us its window
            Size = new Size(800, 600);
            BackColor = Color.FromArgb(24, 24, 24);
            ax = new RdpAx { Dock = DockStyle.Fill, TabStop = true };
            Controls.Add(ax);
        }

        protected override bool ShowWithoutActivation => true;

        protected override CreateParams CreateParams
        {
            get { var cp = base.CreateParams; cp.ExStyle |= (int)N.WS_EX_TOOLWINDOW; return cp; }
        }

        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);
            try
            {
                tcp = new TcpClient();
                tcp.Connect(IPAddress.Loopback, ctl);
                tcp.NoDelay = true;
                writer = new StreamWriter(tcp.GetStream(), new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" };
            }
            catch (Exception ex) { Program.Quit("control connect failed: " + ex.Message); }
            new Thread(ReadLoop) { IsBackground = true, Name = "ctl" }.Start();
            tick.Tick += (o, a) => OnTick();
            follow.Tick += (o, a) => Place();
            tick.Start();
            Send("hello");
        }

        void Send(string s)
        {
            try { lock (sendGate) writer?.WriteLine(s); } catch (Exception ex) { Log.W("send failed " + ex.Message); }
        }

        void ReadLoop()
        {
            try
            {
                var r = new StreamReader(tcp.GetStream(), Encoding.UTF8);
                string line;
                while ((line = r.ReadLine()) != null)
                {
                    var l = line;
                    BeginInvoke((Action)(() => { try { OnCommand(l); } catch (Exception ex) { Log.W("handle '" + l + "' failed " + ex); } }));
                }
            }
            catch (Exception ex) { Log.W("control read failed " + ex.Message); }
            Program.Quit("control socket closed (tab closed)");
        }

        void OnCommand(string line)
        {
            var p = line.Trim().Split(' ');
            switch (p[0])
            {
                case "parent":
                    {
                        var h = (IntPtr)long.Parse(p[1]);
                        // An owned borderless window over the tab, not a child window:
                        // Flutter's swap chain paints over child windows. Owned windows
                        // stay above their owner and minimize with it.
                        N.ShowWindow(Handle, N.SW_HIDE);
                        N.SetWindowLongPtr(Handle, N.GWL_STYLE, (IntPtr)(N.WS_POPUP | N.WS_CLIPCHILDREN));
                        N.SetWindowLongPtr(Handle, N.GWLP_HWNDPARENT, h);
                        parent = h;
                        flutterView = N.FindWindowEx(h, IntPtr.Zero, "FLUTTERVIEW", null);
                        N.SetWindowPos(Handle, IntPtr.Zero, 0, 0, 0, 0, N.SWP_NOMOVE | N.SWP_NOSIZE | N.SWP_NOZORDER | N.SWP_NOACTIVATE | N.SWP_FRAMECHANGED);
                        follow.Start();
                        Log.W("parent " + h + " owner set, flutterView=" + flutterView);
                        break;
                    }
                case "rect":
                    {
                        want = new Rectangle(int.Parse(p[1]), int.Parse(p[2]), int.Parse(p[3]), int.Parse(p[4]));
                        if (p.Length > 5) scale = int.Parse(p[5]);
                        Place();
                        if (!started) Start();
                        else displayAt = DateTime.Now.AddMilliseconds(600);
                        break;
                    }
                case "show":
                    Place();
                    N.ShowWindow(Handle, N.SW_SHOWNA);
                    break;
                case "hide":
                    N.ShowWindow(Handle, N.SW_HIDE);
                    break;
                case "focus":
                    ax.Focus();
                    break;
            }
        }

        void Place()
        {
            if (parent == IntPtr.Zero || want.Width <= 0) return;
            // want is relative to the Flutter view; place in screen pixels.
            var o = new N.POINT();
            N.MapWindowPoints(flutterView != IntPtr.Zero ? flutterView : parent, IntPtr.Zero, ref o, 1);
            var r = new Rectangle(want.X + o.X, want.Y + o.Y, Math.Max(1, want.Width), Math.Max(1, want.Height));
            if (r == placed) return;
            placed = r;
            N.SetWindowPos(Handle, IntPtr.Zero, r.X, r.Y, r.Width, r.Height, N.SWP_NOZORDER | N.SWP_NOACTIVATE);
        }

        static int Even(int v) => Math.Max(200, v) & ~1;

        static int ValidScale(int s)
        {
            int[] ok = { 100, 125, 150, 175, 200, 250, 300 };
            int best = 100;
            foreach (var v in ok) if (Math.Abs(v - s) < Math.Abs(best - s)) best = v;
            return best;
        }

        void Start()
        {
            started = true; startedAt = DateTime.Now;
            try
            {
                ocx = ax.GetOcx();
                ocx.Server = "localhost";
                var user = Environment.GetEnvironmentVariable("rdp_username") ?? "";
                var pass = Environment.GetEnvironmentVariable("rdp_password") ?? "";
                if (user.Length > 0) ocx.UserName = user;
                sessionSize = new Size(Even(want.Width), Even(want.Height));
                ocx.DesktopWidth = sessionSize.Width; ocx.DesktopHeight = sessionSize.Height;
                ocx.ColorDepth = 32;
                var adv = ocx.AdvancedSettings9;
                try { adv.PerformanceFlags = 0x180; } catch (Exception ex) { Log.W("PerformanceFlags failed " + ex.Message); } // desktop composition + font smoothing (see-through taskbar)
                adv.RDPPort = port;
                adv.EnableCredSspSupport = true;
                adv.AuthenticationLevel = 0; // localhost tunnel: the name never matches the NUC's certificate
                adv.RedirectPrinters = false; adv.RedirectDrives = false; adv.RedirectSmartCards = false; adv.RedirectPorts = false;
                adv.RedirectClipboard = true;
                adv.SmartSizing = false;
                if (pass.Length > 0)
                {
                    ((IMsRdpClientNonScriptable)ocx).put_ClearTextPassword(pass);
                    NoPrompts();
                }
                Log.W("connect localhost:" + port + " user=" + (user.Length > 0 ? user : "(none)") + " password=" + (pass.Length > 0 ? "set" : "none") + " size=" + sessionSize + " scale=" + scale);
                ocx.Connect();
                Send("state connecting");
            }
            catch (Exception ex) { Log.W("start failed " + ex); Send("state disconnected start-failed"); Program.Quit("start failed"); }
        }

        // With a saved password the control must never pop its own credential prompt.
        void NoPrompts()
        {
            IMsRdpClientNonScriptable5 n;
            try { n = (IMsRdpClientNonScriptable5)ocx; } catch (Exception ex) { Log.W("NonScriptable5 missing " + ex.Message); return; }
            Action[] set =
            {
                () => n.put_PromptForCredentials(false),
                () => n.put_AllowPromptingForCredentials(false),
                () => n.put_AllowCredentialSaving(false),
                () => n.put_PromptForCredsOnClient(false),
                () => n.put_WarnAboutSendingCredentials(false),
            };
            foreach (var a in set) try { a(); } catch (Exception ex) { Log.W("no-prompt setter failed " + ex.Message); }
        }

        bool ApplyDisplay()
        {
            var size = new Size(Even(want.Width), Even(want.Height));
            var sc = ValidScale(scale);
            if (size == sessionSize && sc == sessionScale) return true;
            try
            {
                ocx.UpdateSessionDisplaySettings((uint)size.Width, (uint)size.Height, (uint)size.Width, (uint)size.Height, 0u, (uint)sc, 100u);
                Log.W("display " + sessionSize + "@" + sessionScale + " -> " + size + "@" + sc);
                sessionSize = size; sessionScale = sc;
                return true;
            }
            catch (Exception ex) { Log.W("display update failed " + ex.Message); return false; }
        }

        void OnTick()
        {
            if (parent != IntPtr.Zero && !N.IsWindow(parent)) Program.Quit("RustDesk window gone");
            if (!started || ocx == null) return;
            int c;
            try { c = (int)ocx.Connected; } catch { return; }
            if (c != 0) sawActive = true;
            if (c == 1 && !connected)
            {
                connected = true;
                Log.W("connected");
                Send("state connected");
                displayAt = DateTime.Now.AddSeconds(2); // let the sign-in finish first
            }
            if (c == 0 && (sawActive || DateTime.Now - startedAt > TimeSpan.FromSeconds(30)))
            {
                string reason = "";
                try { reason = " reason=" + (int)ocx.ExtendedDisconnectReason; } catch { }
                Send("state disconnected" + reason);
                Program.Quit("session ended" + reason);
            }
            if (connected && DateTime.Now >= displayAt)
                displayAt = ApplyDisplay() ? DateTime.MaxValue : DateTime.Now.AddSeconds(2);
        }
    }
}
