// WdacAgent.cs - WDAC 平台 Agent（.NET Framework 4.8，零依赖）
// 功能：本地 HTTP API + 定时学习采集 + 策略部署/回滚（调用 PowerShell 脚本）
// 编译：csc /target:exe /out:WdacAgent.exe WdacAgent.cs /r:System.ServiceProcess.dll
// 运行：WdacAgent.exe --console   （前台调试）
//       WdacAgent.exe --install   （注册为 Windows 服务，自启动）
//       WdacAgent.exe --uninstall

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.ServiceProcess;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace WdacPlatform
{
    public class WdacAgent : ServiceBase
    {
        public const string Root = @"C:\wdac-platform";
        static readonly string Scripts = Path.Combine(Root, "scripts");
        static readonly string LogDir = Path.Combine(Root, "logs");
        static readonly string LogFile = Path.Combine(LogDir, "agent.log");
        static readonly string ConsoleFile = Path.Combine(Root, "console", "index.html");
        static HttpListener listener;
        static Timer learnTimer;
        static Timer autostartTimer;
        static volatile bool learning = false;
        static DateTime lastLearn = DateTime.MinValue;
        static string lastLearnResult = "";

        public WdacAgent() { ServiceName = "WdacAgent"; }

        public static void Log(string msg)
        {
            try
            {
                Directory.CreateDirectory(LogDir);
                File.AppendAllText(LogFile, "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] " + msg + "\r\n", Encoding.UTF8);
            }
            catch { }
        }

        // ---------- 入口 ----------
        static void Main(string[] args)
        {
            if (args.Length > 0 && args[0] == "--install") { InstallService(); return; }
            if (args.Length > 0 && args[0] == "--uninstall") { UninstallService(); return; }
            if (args.Length > 0 && args[0] == "--console")
            {
                var a = new WdacAgent();
                a.StartInternal();
                Console.WriteLine("WdacAgent 运行中，按 Ctrl+C 退出...");
                Console.ReadLine();
                a.StopInternal();
                return;
            }
            ServiceBase.Run(new WdacAgent());
        }

        static void InstallService()
        {
            string exe = Path.Combine(Root, "agent", "WdacAgent.exe");
            if (!File.Exists(exe)) { Console.WriteLine("找不到 " + exe); return; }
            RunCmd("sc.exe", "create WdacAgent binPath= \"" + exe + "\" start= auto DisplayName= \"WDAC Platform Agent\"");
            RunCmd("sc.exe", "description WdacAgent \"WDAC 应用白名单平台 Agent（本地 API + 学习采集）\"");
            RunCmd("sc.exe", "start WdacAgent");
            Console.WriteLine("服务已安装并启动。");
            Console.WriteLine("也可用: sc.exe start WdacAgent");
        }

        static void UninstallService()
        {
            RunCmd("sc.exe", "stop WdacAgent");
            RunCmd("sc.exe", "delete WdacAgent");
            Console.WriteLine("服务已卸载。");
        }

        static int RunCmd(string file, string args)
        {
            try
            {
                var psi = new ProcessStartInfo(file, args)
                {
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true
                };
                var p = Process.Start(psi);
                p.WaitForExit(30000);
                return p.ExitCode;
            }
            catch (Exception ex) { Log("RunCmd 失败: " + ex.Message); return -1; }
        }

        // ---------- 服务生命周期 ----------
        protected override void OnStart(string[] args) { StartInternal(); }
        protected override void OnStop() { StopInternal(); }

        void StartInternal()
        {
            CheckWatchdog();
            Log("Agent 启动");
            try
            {
                int port = ChoosePort();
                if (port < 0)
                {
                    Log("没有可用端口（8765-8775 均被占用），HTTP 服务未启动");
                    return;
                }
                listener = new HttpListener();
                listener.Prefixes.Add("http://localhost:" + port + "/");
                listener.Start();
                try
                {
                    File.WriteAllText(Path.Combine(Root, "out", "port.txt"), port.ToString());
                }
                catch { }
                Thread t = new Thread(ListenLoop);
                t.IsBackground = true;
                t.Start();
                Log("HTTP 监听 http://localhost:" + port + "/");
            }
            catch (Exception ex) { Log("HTTP 启动失败: " + ex.Message); }

            // 定时学习：每 5 分钟采集一次
            learnTimer = new Timer(delegate { RunLearnAsync(); }, null, 10000, 300000);
            Log("定时学习已启动（5 分钟）");

            // 定时监视启动项：每 60 秒扫描并检测变化
            autostartTimer = new Timer(delegate { RunAutostartScan(); }, null, 30000, 60000);
            Log("启动项监视已启动（60 秒）");
        }

        // 扫描启动项；如有变化写入日志（供控制台展示）
        static void RunAutostartScan()
        {
            try
            {
                RunPS("autostart.ps1", "");
                string cf = Path.Combine(Root, "out", "autostart-changes.json");
                if (File.Exists(cf))
                {
                    string c = File.ReadAllText(cf, Encoding.UTF8).Trim();
                    if (c.Length > 2 && c.Contains("\"Action\""))
                    {
                        string compact = c.Replace("\r", "").Replace("\n", " ");
                        Log("启动项变化: " + (compact.Length > 300 ? compact.Substring(0, 300) : compact));
                    }
                }
            }
            catch (Exception ex) { Log("启动项扫描失败: " + ex.Message); }
        }

        // 选择可用端口：优先 8765，被占用则递增（最多尝试到 8775）
        static int ChoosePort()
        {
            for (int port = 8765; port <= 8775; port++)
            {
                try
                {
                    var probe = new HttpListener();
                    probe.Prefixes.Add("http://localhost:" + port + "/");
                    probe.Start();
                    probe.Stop();
                    probe.Close();
                    return port;
                }
                catch { }
            }
            return -1;
        }

        void StopInternal()
        {
            try { if (learnTimer != null) learnTimer.Dispose(); } catch { }
            try { if (autostartTimer != null) autostartTimer.Dispose(); } catch { }
            try { if (listener != null) { listener.Stop(); listener.Close(); } } catch { }
            Log("Agent 停止");
        }

        // 看门狗：上次强制部署后若 Agent 迟迟未启动（系统异常），自动回滚策略
        static void CheckWatchdog()
        {
            string flag = Path.Combine(Root, "out", "pending-enforce.json");
            if (!File.Exists(flag)) return;
            try
            {
                string content = File.ReadAllText(flag);
                bool rollback = false;
                Match m = Regex.Match(content, "\"(\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2})\"");
                if (m.Success)
                {
                    DateTime t;
                    if (DateTime.TryParseExact(m.Groups[1].Value, "yyyy-MM-dd HH:mm:ss", null,
                            System.Globalization.DateTimeStyles.None, out t))
                    {
                        if ((DateTime.Now - t).TotalMinutes > 5) rollback = true;
                    }
                }
                if (rollback)
                {
                    string sip = @"C:\Windows\System32\CodeIntegrity\SIPolicy.p7b";
                    if (File.Exists(sip))
                    {
                        File.Delete(sip);
                        Log("看门狗: 上次强制部署后 Agent 未在 5 分钟内确认启动，已自动回滚策略（重启后生效）");
                    }
                }
                File.Delete(flag);
            }
            catch (Exception ex) { Log("看门狗异常: " + ex.Message); }
        }

        // ---------- HTTP ----------
        static void ListenLoop()
        {
            while (listener != null && listener.IsListening)
            {
                HttpListenerContext ctx;
                try { ctx = listener.GetContext(); }
                catch { break; }
                try { Handle(ctx); }
                catch (Exception ex) { Log("请求处理失败: " + ex.Message); try { WriteJson(ctx, 500, "{\"error\":\"" + Escape(ex.Message) + "\"}"); } catch { } }
            }
        }

        static void Handle(HttpListenerContext ctx)
        {
            string path = ctx.Request.Url.AbsolutePath.ToLower();
            string method = ctx.Request.HttpMethod;

            if (method == "GET" && (path == "/" || path == "/index.html"))
            {
                if (File.Exists(ConsoleFile))
                {
                    byte[] data = File.ReadAllBytes(ConsoleFile);
                    ctx.Response.ContentType = "text/html; charset=utf-8";
                    ctx.Response.ContentLength64 = data.Length;
                    ctx.Response.OutputStream.Write(data, 0, data.Length);
                    ctx.Response.Close();
                }
                else { WriteJson(ctx, 404, "{\"error\":\"console/index.html 不存在\"}"); }
                return;
            }
            if (method == "GET" && path == "/api/status") { WriteJson(ctx, 200, StatusJson()); return; }
            if (method == "GET" && path == "/api/rules")
            {
                string rf = Path.Combine(Root, "out", "rules.json");
                if (File.Exists(rf)) { WriteJson(ctx, 200, File.ReadAllText(rf, Encoding.UTF8)); }
                else { WriteJson(ctx, 200, "{\"RuleCount\":0,\"Rules\":[]}"); }
                return;
            }
            if (method == "POST" && path == "/api/learn")
            {
                bool started = RunLearnAsync();
                WriteJson(ctx, 200, "{\"ok\":true,\"started\":" + (started ? "true" : "false") + "}");
                return;
            }
            if (method == "POST" && path == "/api/deploy")
            {
                string mode = ctx.Request.QueryString["mode"];
                if (string.IsNullOrEmpty(mode)) mode = "audit";
                var sw = Stopwatch.StartNew();
                string buildArgs = "-RulesFile \"" + Path.Combine(Root, "out", "rules.json") + "\" -OutputFile \"" + Path.Combine(Root, "out", "policy.xml") + "\"";
                if (mode == "audit") buildArgs += " -AuditMode";
                string r = RunPS("wdac-build.ps1", buildArgs);
                if (mode == "enforce")
                {
                    string pc = Path.Combine(Root, "out", "precheck.json");
                    RunPS("precheck.ps1", "-PolicyXml \"" + Path.Combine(Root, "out", "policy.xml") + "\"");
                    bool pass = false;
                    string preJson = "null";
                    if (File.Exists(pc))
                    {
                        preJson = File.ReadAllText(pc, Encoding.UTF8);
                        pass = Regex.IsMatch(preJson, "\"Pass\"\\s*:\\s*true");
                    }
                    if (!pass)
                    {
                        sw.Stop();
                        WriteJson(ctx, 200, "{\"ok\":false,\"blocked\":true,\"precheck\":" + preJson + "}");
                        return;
                    }
                }
                r += RunPS("wdac-deploy.ps1", "-PolicyXml \"" + Path.Combine(Root, "out", "policy.xml") + "\"");
                if (mode == "enforce")
                {
                    File.WriteAllText(Path.Combine(Root, "out", "pending-enforce.json"),
                        "{\"time\":\"" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "\"}");
                }
                sw.Stop();
                WriteJson(ctx, 200, "{\"ok\":true,\"mode\":\"" + mode + "\",\"elapsed\":" + sw.Elapsed.TotalSeconds.ToString("F1") + ",\"output\":\"" + Escape(r) + "\"}");
                return;
            }
            if (method == "GET" && path == "/api/precheck")
            {
                string pc = Path.Combine(Root, "out", "precheck.json");
                RunPS("precheck.ps1", "-PolicyXml \"" + Path.Combine(Root, "out", "policy.xml") + "\"");
                WriteJson(ctx, 200, File.Exists(pc) ? File.ReadAllText(pc, Encoding.UTF8) : "{}");
                return;
            }
            if (method == "POST" && path == "/api/rollback")
            {
                string r = RunPS("wdac-deploy.ps1", "-Rollback");
                WriteJson(ctx, 200, "{\"ok\":true,\"output\":\"" + Escape(r) + "\"}");
                return;
            }
            if (method == "GET" && path == "/api/pending")
            {
                RunPS("pending.ps1", "");
                string pf = Path.Combine(Root, "out", "pending.json");
                if (File.Exists(pf)) { WriteJson(ctx, 200, File.ReadAllText(pf, Encoding.UTF8)); }
                else { WriteJson(ctx, 200, "[]"); }
                return;
            }
            if (method == "POST" && path == "/api/approve")
            {
                string q = ctx.Request.QueryString["path"];
                if (string.IsNullOrEmpty(q)) { WriteJson(ctx, 400, "{\"error\":\"缺少 path 参数\"}"); return; }
                string r = RunPS("approve.ps1", "-Path \"" + q + "\"");
                WriteJson(ctx, 200, "{\"ok\":true,\"output\":\"" + Escape(r) + "\"}");
                return;
            }
            if (method == "GET" && path == "/api/audit")
            {
                RunPS("audit.ps1", "");
                string af = Path.Combine(Root, "out", "audit.json");
                if (File.Exists(af)) { WriteJson(ctx, 200, File.ReadAllText(af, Encoding.UTF8)); }
                else { WriteJson(ctx, 200, "[]"); }
                return;
            }
            if (method == "POST" && path == "/api/addpath")
            {
                string q = ctx.Request.QueryString["path"];
                string t = ctx.Request.QueryString["type"];
                if (string.IsNullOrEmpty(q)) { WriteJson(ctx, 400, "{\"error\":\"缺少 path 参数\"}"); return; }
                if (string.IsNullOrEmpty(t)) t = "path";
                string r = RunPS("addpath.ps1", "-Path \"" + q + "\" -Type " + t);
                WriteJson(ctx, 200, "{\"ok\":true,\"output\":\"" + Escape(r) + "\"}");
                return;
            }
            if (method == "POST" && path == "/api/deny")
            {
                string q = ctx.Request.QueryString["path"];
                if (string.IsNullOrEmpty(q)) { WriteJson(ctx, 400, "{\"error\":\"缺少 path 参数\"}"); return; }
                string r = RunPS("deny.ps1", "-Path \"" + q + "\"");
                WriteJson(ctx, 200, "{\"ok\":true,\"output\":\"" + Escape(r) + "\"}");
                return;
            }
            if (method == "GET" && path == "/api/report")
            {
                string fmt = ctx.Request.QueryString["format"];
                if (string.IsNullOrEmpty(fmt)) fmt = "csv";
                RunPS("report.ps1", "-Format " + fmt);
                string rf = Path.Combine(Root, "out", fmt == "html" ? "report.html" : "report.csv");
                if (File.Exists(rf))
                {
                    byte[] data = File.ReadAllBytes(rf);
                    ctx.Response.ContentType = fmt == "html" ? "text/html; charset=utf-8" : "text/csv; charset=utf-8";
                    ctx.Response.AddHeader("Content-Disposition", "attachment; filename=\"wdac-report." + fmt + "\"");
                    ctx.Response.ContentLength64 = data.Length;
                    ctx.Response.OutputStream.Write(data, 0, data.Length);
                    ctx.Response.Close();
                    return;
                }
                WriteJson(ctx, 404, "{\"error\":\"报告生成失败\"}");
                return;
            }
            if (method == "GET" && path == "/api/health")
            {
                RunPS("healthcheck.ps1", "");
                string hf = Path.Combine(Root, "out", "health.json");
                WriteJson(ctx, 200, File.Exists(hf) ? File.ReadAllText(hf, Encoding.UTF8) : "{}");
                return;
            }
            if (method == "GET" && path == "/api/requests")
            {
                var items = new List<string>();
                try
                {
                    foreach (string userDir in Directory.GetDirectories(@"C:\Users"))
                    {
                        string rd = Path.Combine(userDir, "AppData", "Local", "WdacPlatform", "requests");
                        if (!Directory.Exists(rd)) continue;
                        foreach (string f in Directory.GetFiles(rd, "*.json"))
                        {
                            try { items.Add(File.ReadAllText(f, Encoding.UTF8).Trim()); } catch { }
                        }
                    }
                }
                catch { }
                WriteJson(ctx, 200, "[" + string.Join(",", items) + "]");
                return;
            }
            if (method == "GET" && path == "/api/inventory")
            {
                RunPS("inventory.ps1", "");
                string f = Path.Combine(Root, "out", "inventory.json");
                WriteJson(ctx, 200, File.Exists(f) ? File.ReadAllText(f, Encoding.UTF8) : "{}");
                return;
            }
            if (method == "POST" && path == "/api/netblock")
            {
                string q = ctx.Request.QueryString["path"];
                string addr = ctx.Request.QueryString["remoteAddress"];
                if (string.IsNullOrEmpty(q)) { WriteJson(ctx, 400, "{\"error\":\"缺少 path 参数\"}"); return; }
                string args = "-Path \"" + q + "\" -Action block";
                if (!string.IsNullOrEmpty(addr)) args += " -RemoteAddress \"" + addr + "\"";
                string r = RunPS("netctl.ps1", args);
                WriteJson(ctx, 200, "{\"ok\":true,\"output\":\"" + Escape(r) + "\"}");
                return;
            }
            if (method == "POST" && path == "/api/netunblock")
            {
                string q = ctx.Request.QueryString["path"];
                string addr = ctx.Request.QueryString["remoteAddress"];
                if (string.IsNullOrEmpty(q)) { WriteJson(ctx, 400, "{\"error\":\"缺少 path 参数\"}"); return; }
                string args = "-Path \"" + q + "\" -Action unblock";
                if (!string.IsNullOrEmpty(addr)) args += " -RemoteAddress \"" + addr + "\"";
                string r = RunPS("netctl.ps1", args);
                WriteJson(ctx, 200, "{\"ok\":true,\"output\":\"" + Escape(r) + "\"}");
                return;
            }
            if (method == "GET" && path == "/api/autostart")
            {
                RunPS("autostart.ps1", "");
                string f = Path.Combine(Root, "out", "autostart.json");
                WriteJson(ctx, 200, File.Exists(f) ? File.ReadAllText(f, Encoding.UTF8) : "{\"Items\":[]}");
                return;
            }
            if (method == "GET" && path == "/api/autostart-changes")
            {
                string f = Path.Combine(Root, "out", "autostart-history.json");
                WriteJson(ctx, 200, File.Exists(f) ? File.ReadAllText(f, Encoding.UTF8) : "[]");
                return;
            }
            if (method == "POST" && path == "/api/autostart-add")
            {
                string n = ctx.Request.QueryString["name"];
                string c = ctx.Request.QueryString["command"];
                if (string.IsNullOrEmpty(n) || string.IsNullOrEmpty(c)) { WriteJson(ctx, 400, "{\"error\":\"缺少 name 或 command\"}"); return; }
                string r = RunPS("autostart-manage.ps1", "-Action add -Name \"" + n + "\" -Command \"" + c + "\"");
                WriteJson(ctx, 200, "{\"ok\":true,\"output\":\"" + Escape(r) + "\"}");
                return;
            }
            if (method == "POST" && path == "/api/autostart-remove")
            {
                string n = ctx.Request.QueryString["name"];
                if (string.IsNullOrEmpty(n)) { WriteJson(ctx, 400, "{\"error\":\"缺少 name\"}"); return; }
                string r = RunPS("autostart-manage.ps1", "-Action remove -Name \"" + n + "\"");
                WriteJson(ctx, 200, "{\"ok\":true,\"output\":\"" + Escape(r) + "\"}");
                return;
            }
            if (method == "GET" && path == "/api/autostart-backups")
            {
                RunPS("autostart-manage.ps1", "-Action list");
                string f = Path.Combine(Root, "out", "autostart-backups.json");
                WriteJson(ctx, 200, File.Exists(f) ? File.ReadAllText(f, Encoding.UTF8) : "[]");
                return;
            }
            if (method == "POST" && path == "/api/autostart-restore")
            {
                string b = ctx.Request.QueryString["backupId"];
                if (string.IsNullOrEmpty(b)) { WriteJson(ctx, 400, "{\"error\":\"缺少 backupId\"}"); return; }
                string r = RunPS("autostart-manage.ps1", "-Action restore -BackupId \"" + b + "\"");
                WriteJson(ctx, 200, "{\"ok\":true,\"output\":\"" + Escape(r) + "\"}");
                return;
            }
            if (method == "GET" && path == "/api/apps")
            {
                RunPS("uninstall-app.ps1", "-Action scan");
                string f = Path.Combine(Root, "out", "apps.json");
                WriteJson(ctx, 200, File.Exists(f) ? File.ReadAllText(f, Encoding.UTF8) : "{\"Apps\":[]}");
                return;
            }
            if (method == "POST" && path == "/api/app-uninstall")
            {
                string n = ctx.Request.QueryString["name"];
                string purge = ctx.Request.QueryString["purge"];
                if (string.IsNullOrEmpty(n)) { WriteJson(ctx, 400, "{\"error\":\"缺少 name\"}"); return; }
                string args = "-Action uninstall -Name \"" + n + "\"";
                if (purge == "1") args += " -Purge";
                string r = RunPS("uninstall-app.ps1", args);
                WriteJson(ctx, 200, "{\"ok\":true,\"output\":\"" + Escape(r) + "\"}");
                return;
            }
            if (method == "POST" && path == "/api/publisher-action")
            {
                string pub = ctx.Request.QueryString["publisher"];
                string act = ctx.Request.QueryString["action"];
                if (string.IsNullOrEmpty(pub) || string.IsNullOrEmpty(act)) { WriteJson(ctx, 400, "{\"error\":\"缺少 publisher 或 action\"}"); return; }
                string r = RunPS("publisher-action.ps1", "-Publisher \"" + pub + "\" -Action " + act);
                WriteJson(ctx, 200, "{\"ok\":true,\"output\":\"" + Escape(r) + "\"}");
                return;
            }
            if (method == "POST" && path == "/api/elevation-request")
            {
                string q = ctx.Request.QueryString["path"];
                if (string.IsNullOrEmpty(q)) { WriteJson(ctx, 400, "{\"error\":\"缺少 path\"}"); return; }
                string r = RunPS("elevation.ps1", "-Action request -Path \"" + q + "\"");
                WriteJson(ctx, 200, "{\"ok\":true,\"output\":\"" + Escape(r) + "\"}");
                return;
            }
            if (method == "POST" && path == "/api/elevation-approve")
            {
                string id = ctx.Request.QueryString["id"];
                if (string.IsNullOrEmpty(id)) { WriteJson(ctx, 400, "{\"error\":\"缺少 id\"}"); return; }
                string r = RunPS("elevation.ps1", "-Action approve -Id \"" + id + "\"");
                WriteJson(ctx, 200, "{\"ok\":true,\"output\":\"" + Escape(r) + "\"}");
                return;
            }
            if (method == "POST" && path == "/api/elevation-deny")
            {
                string id = ctx.Request.QueryString["id"];
                if (string.IsNullOrEmpty(id)) { WriteJson(ctx, 400, "{\"error\":\"缺少 id\"}"); return; }
                string r = RunPS("elevation.ps1", "-Action deny -Id \"" + id + "\"");
                WriteJson(ctx, 200, "{\"ok\":true,\"output\":\"" + Escape(r) + "\"}");
                return;
            }
            if (method == "GET" && path == "/api/elevation-list")
            {
                RunPS("elevation.ps1", "-Action list");
                string f = Path.Combine(Root, "out", "elevation-requests.json");
                WriteJson(ctx, 200, File.Exists(f) ? File.ReadAllText(f, Encoding.UTF8) : "[]");
                return;
            }
            WriteJson(ctx, 404, "{\"error\":\"未知接口\"}");
        }

        static string StatusJson()
        {
            string state = "Unknown";
            int raw = -1;
            try
            {
                string r = RunPSCmd("try { $d=Get-CimInstance -Namespace root\\Microsoft\\Windows\\DeviceGuard -ClassName Win32_DeviceGuard; $d.CodeIntegrityPolicyEnforcementStatus } catch { -1 }");
                int.TryParse(r.Trim(), out raw);
                state = raw == 0 ? "Off" : raw == 1 ? "Audit" : raw == 2 ? "Enforced" : "Unknown";
            }
            catch { }

            string sb = "{";
            sb += "\"state\":\"" + state + "\",";
            sb += "\"raw\":" + raw + ",";
            sb += "\"sipolicy\":" + (File.Exists(@"C:\Windows\System32\CodeIntegrity\SIPolicy.p7b") ? "true" : "false") + ",";
            sb += "\"learning\":" + (learning ? "true" : "false") + ",";
            sb += "\"lastLearn\":\"" + (lastLearn == DateTime.MinValue ? "" : lastLearn.ToString("yyyy-MM-dd HH:mm:ss")) + "\",";
            sb += "\"lastLearnResult\":\"" + Escape(lastLearnResult) + "\",";
            sb += "\"root\":\"" + Escape(Root) + "\"";
            sb += "}";
            return sb;
        }

        // ---------- 学习 ----------
        static bool RunLearnAsync()
        {
            if (learning) return false;
            learning = true;
            ThreadPool.QueueUserWorkItem(delegate
            {
                try
                {
                    Log("开始学习采集...");
                    string r = RunPS("wdac-learn.ps1", "-MaxEvents 2000");
                    lastLearn = DateTime.Now;
                    lastLearnResult = r;
                    Log("学习完成: " + r);
                }
                catch (Exception ex) { Log("学习失败: " + ex.Message); lastLearnResult = ex.Message; }
                finally { learning = false; }
            });
            return true;
        }

        static string RunPS(string script, string args)
        {
            string path = Path.Combine(Scripts, script);
            string cmd = "-NoProfile -ExecutionPolicy Bypass -File \"" + path + "\"";
            if (!string.IsNullOrEmpty(args)) cmd += " " + args;
            return RunProcess(@"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe", cmd);
        }

        static string RunPSCmd(string command)
        {
            return RunProcess(@"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe", "-NoProfile -ExecutionPolicy Bypass -Command \"" + command + "\"");
        }

        static string RunProcess(string file, string args)
        {
            try
            {
                var psi = new ProcessStartInfo(file, args)
                {
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true,
                    StandardOutputEncoding = Encoding.GetEncoding(936),
                    StandardErrorEncoding = Encoding.GetEncoding(936)
                };
                using (var p = Process.Start(psi))
                {
                    var sbOut = new StringBuilder();
                    var sbErr = new StringBuilder();
                    p.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null) { lock (sbOut) sbOut.AppendLine(e.Data); } };
                    p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null) { lock (sbErr) sbErr.AppendLine(e.Data); } };
                    p.BeginOutputReadLine();
                    p.BeginErrorReadLine();
                    bool exited = p.WaitForExit(120000);
                    if (!exited)
                    {
                        try { p.Kill(); } catch { }
                        Log("子进程超时被终止: " + args);
                    }
                    lock (sbOut) return (sbOut.ToString() + sbErr.ToString()).Trim();
                }
            }
            catch (Exception ex) { return "ERROR: " + ex.Message; }
        }

        static void WriteJson(HttpListenerContext ctx, int code, string body)
        {
            byte[] data = Encoding.UTF8.GetBytes(body);
            ctx.Response.StatusCode = code;
            ctx.Response.ContentType = "application/json; charset=utf-8";
            ctx.Response.ContentLength64 = data.Length;
            ctx.Response.OutputStream.Write(data, 0, data.Length);
            ctx.Response.Close();
        }

        static string Escape(string s)
        {
            if (s == null) return "";
            return s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "").Replace("\n", "\\n");
        }
    }
}
