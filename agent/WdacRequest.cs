// WdacRequest.cs - 用户自助申请工具
// 被拦截用户运行此工具：选择程序 → 提交申请 → 管理员在控制台批准
// 编译: csc /nologo /target:winexe /out:WdacRequest.exe WdacRequest.cs /r:System.Windows.Forms.dll
// 注意: 申请写入用户 LOCALAPPDATA（普通用户可写），Agent 以 SYSTEM 扫描所有用户

using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Forms;

namespace WdacRequest
{
    internal static class Program
    {
        private static readonly string ReqDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "WdacPlatform", "requests");

        [STAThread]
        private static void Main()
        {
            try
            {
                using (var dlg = new OpenFileDialog())
                {
                    dlg.Title = "选择要申请运行的程序";
                    dlg.Filter = "可执行文件|*.exe;*.dll;*.msi;*.bat;*.cmd;*.ps1;*.com|所有文件|*.*";
                    if (dlg.ShowDialog() != DialogResult.OK) { return; }
                    string path = dlg.FileName;

                    Directory.CreateDirectory(ReqDir);
                    string hash = ComputeSha256(path);
                    string json = "{" +
                        "\"FilePath\":\"" + Escape(path) + "\"," +
                        "\"SHA256\":\"" + hash + "\"," +
                        "\"Time\":\"" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "\"," +
                        "\"User\":\"" + Escape(Environment.UserName) + "\"" +
                        "}";
                    File.WriteAllText(Path.Combine(ReqDir, Guid.NewGuid().ToString("N") + ".json"), json, Encoding.UTF8);

                    MessageBox.Show(
                        "申请已提交，等待管理员审批。\n\n程序: " + Path.GetFileName(path),
                        "WDAC 申请", MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show("申请失败: " + ex.Message, "WDAC 申请", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private static string ComputeSha256(string file)
        {
            using (var sha = SHA256.Create())
            using (var fs = File.OpenRead(file))
            {
                byte[] h = sha.ComputeHash(fs);
                var sb = new StringBuilder();
                foreach (byte b in h) sb.Append(b.ToString("X2"));
                return sb.ToString();
            }
        }

        private static string Escape(string s)
        {
            return s.Replace("\\", "\\\\").Replace("\"", "\\\"");
        }
    }
}
