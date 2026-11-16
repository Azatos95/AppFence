// Installer.cs - WDAC Platform 自解压安装器
// 编译: csc /nologo /target:winexe /out:WdacPlatform-Setup.exe Installer.cs
//       /resource:payload.zip,WdacPayload /r:System.IO.Compression.dll
//       /r:System.IO.Compression.FileSystem.dll /win32manifest:app.manifest
// 行为: 解压内嵌 payload 到 C:\wdac-platform，编译 Agent，注册并启动服务

using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

namespace WdacPlatform
{
    internal static class Installer
    {
        private const string Root = @"C:\wdac-platform";

        [STAThread]
        private static void Main(string[] args)
        {
            bool silent = false;
            bool uninstall = false;
            if (args != null)
            {
                foreach (string a in args)
                {
                    if (a.Equals("/S", StringComparison.OrdinalIgnoreCase) ||
                        a.Equals("-silent", StringComparison.OrdinalIgnoreCase) ||
                        a.Equals("--silent", StringComparison.OrdinalIgnoreCase))
                    {
                        silent = true;
                    }
                    if (a.Equals("/U", StringComparison.OrdinalIgnoreCase) ||
                        a.Equals("-uninstall", StringComparison.OrdinalIgnoreCase) ||
                        a.Equals("--uninstall", StringComparison.OrdinalIgnoreCase))
                    {
                        uninstall = true;
                    }
                }
            }
            if (uninstall) { DoUninstall(silent); return; }
            Console.WriteLine("AppFence 安装程序" + (silent ? "（静默模式）" : ""));
            try
            {
                Directory.CreateDirectory(Root);

                // 0. 停止旧服务并清理程序目录（保留数据目录：out/logs/backup/state）
                Console.WriteLine("[0/3] 停止旧服务并清理旧版本程序文件...");
                Run("sc.exe", "stop WdacAgent");
                Thread.Sleep(2000);
                foreach (string sub in new string[] { "scripts", "agent", "console" })
                {
                    string d = Path.Combine(Root, sub);
                    if (Directory.Exists(d))
                    {
                        try { Directory.Delete(d, true); }
                        catch { Console.WriteLine("  清理失败（可能被占用）: " + d); }
                    }
                }

                // 1. 解压内嵌 payload
                Console.WriteLine("[1/3] 释放文件到 " + Root + " ...");
                using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("WdacPayload"))
                {
                    if (s == null) { throw new InvalidOperationException("安装包损坏：内嵌 payload 缺失"); }
                    using (var zip = new ZipArchive(s, ZipArchiveMode.Read))
                    {
                        foreach (ZipArchiveEntry entry in zip.Entries)
                        {
                            string dest = Path.Combine(Root, entry.FullName.Replace('/', '\\'));
                            if (entry.Name.Length == 0) { Directory.CreateDirectory(dest); continue; }
                            Directory.CreateDirectory(Path.GetDirectoryName(dest));
                            entry.ExtractToFile(dest, true);
                        }
                    }
                }

                // 2. 运行安装脚本
                Console.WriteLine("[2/3] 执行安装脚本（编译 Agent + 注册服务）...");
                var psi = new ProcessStartInfo(
                    Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"),
                    "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(Root, "setup.ps1") + "\"")
                {
                    UseShellExecute = false,
                    CreateNoWindow = false,
                    WorkingDirectory = Root
                };
                using (Process p = Process.Start(psi))
                {
                    p.WaitForExit();
                    if (p.ExitCode != 0 && p.ExitCode != -1)
                    {
                        Console.WriteLine("警告: 安装脚本返回 " + p.ExitCode + "，请查看上方输出。");
                    }
                }

                // 3. 完成
                Console.WriteLine("[3/3] 完成！");
                string port = ReadPort();
                Console.WriteLine("控制台: http://localhost:" + port);
                Console.WriteLine("卸载: WdacPlatform-Setup.exe /U");
                if (!silent)
                {
                    // 以当前用户桌面 shell 打开默认浏览器（避免使用管理员上下文）
                    try { Process.Start("explorer.exe", "http://localhost:" + port); } catch { }
                }
                return;
            }
            catch (Exception ex)
            {
                Console.WriteLine("安装失败: " + ex.Message);
                if (!silent)
                {
                    MessageBox.Show("安装失败: " + ex.Message, "AppFence", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }
        }

        private static string ReadPort()
        {
            try
            {
                string pf = @"C:\wdac-platform\out\port.txt";
                if (File.Exists(pf))
                {
                    string s = File.ReadAllText(pf).Trim();
                    int p;
                    if (int.TryParse(s, out p) && p > 0) return s;
                }
            }
            catch { }
            return "8765";
        }

        private static void DoUninstall(bool silent)
        {            Console.WriteLine("卸载 WDAC Platform...");
            Run("sc.exe", "stop WdacAgent");
            Thread.Sleep(2000);
            Run("sc.exe", "delete WdacAgent");

            string sip = @"C:\Windows\System32\CodeIntegrity\SIPolicy.p7b";
            if (File.Exists(sip)) { try { File.Delete(sip); } catch { } }

            string root = @"C:\wdac-platform";
            if (Directory.Exists(root)) { try { Directory.Delete(root, true); } catch { } }

            Console.WriteLine("卸载完成，建议重启系统。");
            if (!silent)
            {
                MessageBox.Show("卸载完成，建议重启系统。", "AppFence", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
        }

        private static void Run(string file, string args)
        {
            try
            {
                var psi = new ProcessStartInfo(file, args) { UseShellExecute = false, CreateNoWindow = true };
                using (Process p = Process.Start(psi)) { p.WaitForExit(30000); }
            }
            catch { }
        }
    }
}
