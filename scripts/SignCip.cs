// sign-cip.cs - 用 PKCS#7 给 CIP 策略签名（多策略格式必需）
// 用法: SignCip.exe <pfx> <password> <cip-input> <p7-output>
using System;
using System.IO;
using System.Security.Cryptography;
using System.Security.Cryptography.Pkcs;
using System.Security.Cryptography.X509Certificates;

internal static class Program
{
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length < 4)
            {
                Console.WriteLine("用法: SignCip.exe <pfx> <password> <cip-input> <p7-output>");
                return 2;
            }
            var cert = new X509Certificate2(args[0], args[1]);
            byte[] cip = File.ReadAllBytes(args[2]);

            // CIP 是原始二进制：作为 CMS 内容（OCTET STRING）包装后签名
            var content = new ContentInfo(cip);
            var cms = new SignedCms(content, false);
            var signer = new CmsSigner(SubjectIdentifierType.IssuerAndSerialNumber, cert)
            {
                IncludeOption = X509IncludeOption.EndCertOnly
            };
            cms.ComputeSignature(signer);
            byte[] signed = cms.Encode();
            File.WriteAllBytes(args[3], signed);
            Console.WriteLine("OK: " + args[3] + " (" + signed.Length + " bytes)");
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine("ERROR: " + ex.Message);
            return 1;
        }
    }
}
