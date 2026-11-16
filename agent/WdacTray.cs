// WdacTray.cs - 托盘告警程序
// 轮询 Agent API，检测到启动项变化时弹出气泡通知；双击/菜单打开控制台
// 编译: csc /nologo /target:winexe /out:WdacTray.exe WdacTray.cs /r:System.Windows.Forms.dll /r:System.Drawing.dll
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

namespace WdacTray
{
    internal static class Program
    {
        private static NotifyIcon tray;
        private static string api = "http://localhost:8765";
        private static int lastCount = -1;
        private static System.Windows.Forms.Timer timer;

        [STAThread]
        private static void Main()
        {
            // 读取端口文件（Agent 可能因冲突使用其他端口）
            try
            {
                string pf = @"C:\wdac-platform\out\port.txt";
                if (File.Exists(pf))
                {
                    string p = File.ReadAllText(pf).Trim();
                    int n;
                    if (int.TryParse(p, out n) && n > 0) { api = "http://localhost:" + p; }
                }
            }
            catch { }

            Application.EnableVisualStyles();
            tray = new NotifyIcon();
            try { tray.Icon = Icon.ExtractAssociatedIcon(Assembly.GetExecutingAssembly().Location) ?? SystemIcons.Shield; }
            catch { tray.Icon = SystemIcons.Shield; }
            tray.Text = "AppFence 应用围栏";
            tray.Visible = true;

            var menu = new ContextMenuStrip();
            menu.Items.Add("打开控制台", null, delegate { OpenConsole(); });
            menu.Items.Add("立即检查", null, delegate { CheckChanges(); });
            menu.Items.Add("重新启动", null, delegate { Application.Restart(); });
            menu.Items.Add("重启 Agent 服务", null, delegate { RestartAgent(); });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("退出", null, delegate { tray.Visible = false; Application.Exit(); });
            tray.ContextMenuStrip = menu;
            tray.DoubleClick += delegate { OpenConsole(); };

            timer = new System.Windows.Forms.Timer();
            timer.Interval = 30000;
            timer.Tick += delegate { CheckChanges(); };
            timer.Start();

            Thread t = new Thread(delegate () { Thread.Sleep(3000); CheckChanges(); });
            t.IsBackground = true;
            t.Start();

            Application.Run();
        }

        private static void OpenConsole()
        {
            try { Process.Start("explorer.exe", api); } catch { }
        }

        private static void RestartAgent()
        {
            try
            {
                Process.Start("sc.exe", "stop WdacAgent");
                Thread.Sleep(3000);
                Process.Start("sc.exe", "start WdacAgent");
                tray.ShowBalloonTip(4000, "AppFence", "Agent 服务已重启", ToolTipIcon.Info);
            }
            catch
            {
                tray.ShowBalloonTip(4000, "AppFence", "重启 Agent 需要管理员权限", ToolTipIcon.Warning);
            }
        }

        private static void CheckChanges()
        {
            try
            {
                using (var wc = new WebClient())
                {
                    wc.Encoding = Encoding.UTF8;
                    wc.Headers.Add("User-Agent", "WdacTray");
                    string s = wc.DownloadString(api + "/api/autostart-changes");
                    int count = Regex.Matches(s, "\"Action\"").Count;
                    if (lastCount >= 0 && count > lastCount)
                    {
                        string title = "启动项变化";
                        string msg = "检测到新的启动项变化";
                        Match m = Regex.Match(s, "\"Action\"\\s*:\\s*\"([^\"]+)\"[\\s\\S]*?\"Name\"\\s*:\\s*\"([^\"]+)\"");
                        if (m.Success) { msg = m.Groups[1].Value + ": " + m.Groups[2].Value; }
                        tray.ShowBalloonTip(6000, title, msg, ToolTipIcon.Warning);
                    }
                    lastCount = count;
                }
            }
            catch { }
        }
    }
}
