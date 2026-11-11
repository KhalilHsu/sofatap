using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;

namespace SofaTap;

public static class NetworkAddresses
{
    public static string[] LocalIPv4() => NetworkInterface.GetAllNetworkInterfaces()
        .Where(adapter => adapter.OperationalStatus == OperationalStatus.Up && adapter.NetworkInterfaceType != NetworkInterfaceType.Loopback)
        .SelectMany(adapter => adapter.GetIPProperties().UnicastAddresses)
        .Where(address => address.Address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(address.Address))
        .Select(address => address.Address.ToString()).Distinct().OrderBy(address => address.StartsWith("192.168.", StringComparison.Ordinal) ? 0 : 1).ToArray();
}

public sealed class Credentials : IDisposable
{
    public string Token { get; }
    public X509Certificate2 Certificate { get; }
    public string Fingerprint => Convert.ToHexStringLower(SHA256.HashData(Certificate.RawData));
    public string[] CertificateIPv4 => Certificate.Extensions.OfType<X509SubjectAlternativeNameExtension>()
        .SelectMany(extension => extension.EnumerateIPAddresses()).Where(address => address.AddressFamily == AddressFamily.InterNetwork)
        .Select(address => address.ToString()).ToArray();
    private readonly FileStream _lock;
    private Credentials(string token, X509Certificate2 certificate, FileStream fileLock)
    { Token = token; Certificate = certificate; _lock = fileLock; }
    public static string DefaultDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SofaTap");

    public static Credentials LoadOrCreate(string directory, bool resetPairing = false) =>
        LoadOrCreate(directory, NetworkAddresses.LocalIPv4(), resetPairing);

    /// The pairing identity (TLS leaf + bearer token) is deliberately independent
    /// of the current network. Phones pin the DER leaf fingerprint, so adapters,
    /// DHCP leases and VPNs may come and go without a new QR scan. Only an explicit
    /// reset, an unreadable/corrupt profile, or an expiring certificate renews it.
    internal static Credentials LoadOrCreate(string directory, IReadOnlyCollection<string> localAddresses, bool resetPairing = false)
    {
        Directory.CreateDirectory(directory);
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(directory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        var lockPath = Path.Combine(directory, "receiver.lock");
        FileStream fileLock;
        try { fileLock = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
        catch (IOException) { throw new InvalidOperationException("Another Sofatap receiver is using this profile. Close it before starting another."); }
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(lockPath, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        try
        {
            var path = Path.Combine(directory, "pairing.dat");
            Secret? secret = null;
            X509Certificate2? loaded = null;
            if (resetPairing) Console.Error.WriteLine("Pairing reset requested. Scan the new pairing QR on the iPhone.");
            else if (File.Exists(path))
            {
                try
                {
                    var stored = File.ReadAllBytes(path);
                    var clear = OperatingSystem.IsWindows() ? Dpapi.Unprotect(stored) : stored;
                    try { secret = JsonSerializer.Deserialize<Secret>(clear) ?? throw new InvalidDataException("Invalid pairing profile."); }
                    finally { CryptographicOperations.ZeroMemory(clear); }
                    if (secret.Token is null || secret.Pfx is null || secret.Token.Length != 43
                        || secret.Token.Any(c => !(char.IsAsciiLetterOrDigit(c) || c is '-' or '_')))
                        throw new InvalidDataException("Invalid pairing profile.");
                    loaded = LoadCertificate(secret);
                    if (!loaded.HasPrivateKey) throw new InvalidDataException("Pairing certificate has no private key.");
                }
                catch (Exception error) when (error is InvalidDataException or JsonException or FormatException or CryptographicException or ArgumentException)
                {
                    // Corrupt profile: keep the unreadable bytes for diagnosis and pair again.
                    loaded?.Dispose(); loaded = null; secret = null;
                    var backup = path + ".corrupt-" + DateTime.UtcNow.ToString("yyyyMMddHHmmss");
                    try { File.Copy(path, backup, true); } catch (IOException) { }
                    Console.Error.WriteLine("Pairing profile was unreadable. Scan the new pairing QR on the iPhone.");
                }
                if (loaded is not null && (loaded.NotAfter.ToUniversalTime() < DateTime.UtcNow.AddDays(30)
                    || loaded.NotAfter.ToUniversalTime() - loaded.NotBefore.ToUniversalTime() > TimeSpan.FromDays(366)))
                {
                    // iOS rejects expired or over-long leaves even when pinned.
                    loaded.Dispose(); loaded = null; secret = null;
                    Console.Error.WriteLine("Pairing certificate renewed before expiry. Scan the pairing QR again on the iPhone.");
                }
            }
            if (secret is null) { secret = CreateSecret(localAddresses); SaveSecret(path, secret); }
            loaded ??= LoadCertificate(secret);
            return new(secret.Token, loaded, fileLock);
        }
        catch { fileLock.Dispose(); throw; }
    }
    private static X509Certificate2 LoadCertificate(Secret secret) => X509CertificateLoader.LoadPkcs12(Convert.FromBase64String(secret.Pfx), "",
        // Schannel needs a named key container for server TLS. Keep it in this
        // user's store and let certificate disposal remove it (no PersistKeySet).
        OperatingSystem.IsWindows() ? X509KeyStorageFlags.UserKeySet :
        (OperatingSystem.IsMacOS() ? X509KeyStorageFlags.DefaultKeySet : X509KeyStorageFlags.EphemeralKeySet) | X509KeyStorageFlags.Exportable);
    private static Secret CreateSecret(IEnumerable<string> localAddresses)
    {
        using var rsa = RSA.Create(3072);
        var request = new CertificateRequest("CN=Sofatap Local Receiver", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, true));
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(new OidCollection { new("1.3.6.1.5.5.7.3.1") }, true));
        var sans = new SubjectAlternativeNameBuilder(); sans.AddDnsName("localhost"); sans.AddIpAddress(IPAddress.Loopback); sans.AddIpAddress(IPAddress.IPv6Loopback);
        foreach (var address in localAddresses) sans.AddIpAddress(IPAddress.Parse(address));
        request.CertificateExtensions.Add(sans.Build());
        var notBefore = DateTimeOffset.UtcNow.AddMinutes(-5);
        using var certificate = request.CreateSelfSigned(notBefore, notBefore.AddDays(365));
        return new(Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)).TrimEnd('=').Replace('+', '-').Replace('/', '_'),
            Convert.ToBase64String(certificate.Export(X509ContentType.Pfx, "")));
    }
    private static void SaveSecret(string path, Secret secret)
    {
        var clear = JsonSerializer.SerializeToUtf8Bytes(secret);
        var stored = OperatingSystem.IsWindows() ? Dpapi.Protect(clear) : clear;
        var temporary = path + ".new-" + Guid.NewGuid().ToString("N");
        try
        {
            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(temporary, UnixFileMode.UserRead | UnixFileMode.UserWrite);
                output.Write(stored); output.Flush(true);
            }
            File.Move(temporary, path, true);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(clear);
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }
    public void Dispose() { Certificate.Dispose(); _lock.Dispose(); }
    private sealed record Secret(string Token, string Pfx);

    internal static class Dpapi
    {
        [StructLayout(LayoutKind.Sequential)] private struct Blob { public int Size; public IntPtr Data; }
        public static byte[] Protect(byte[] bytes) => Transform(bytes, true);
        public static byte[] Unprotect(byte[] bytes) => Transform(bytes, false);
        private static byte[] Transform(byte[] bytes, bool protect)
        {
            var input = new Blob { Size = bytes.Length, Data = Marshal.AllocHGlobal(bytes.Length) };
            Blob output = default;
            try
            {
                Marshal.Copy(bytes, 0, input.Data, bytes.Length);
                var ok = protect
                    ? CryptProtectData(ref input, "Sofatap local pairing", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output)
                    : CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output);
                if (!ok) throw new InvalidOperationException("Windows could not unlock this user's pairing profile. Run under the original Windows user, or choose a new data directory.");
                var result = new byte[output.Size]; Marshal.Copy(output.Data, result, 0, output.Size); return result;
            }
            finally
            {
                for (var index = 0; index < bytes.Length; index++) Marshal.WriteByte(input.Data, index, 0);
                Marshal.FreeHGlobal(input.Data);
                if (output.Data != IntPtr.Zero) { for (var index = 0; index < output.Size; index++) Marshal.WriteByte(output.Data, index, 0); LocalFree(output.Data); }
            }
        }
        [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CryptProtectData(ref Blob input, string description, IntPtr entropy, IntPtr reserved, IntPtr prompt, uint flags, out Blob output);
        [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CryptUnprotectData(ref Blob input, IntPtr description, IntPtr entropy, IntPtr reserved, IntPtr prompt, uint flags, out Blob output);
        [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr pointer);
    }
}
