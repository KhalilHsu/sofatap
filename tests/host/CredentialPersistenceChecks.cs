using SofaTap;

internal static class CredentialPersistenceChecks
{
    internal static void Run(Action<bool, string> check)
    {
        // Synthetic documentation addresses keep this regression independent of
        // the runner's NICs and never start a listener or send desktop input.
        const string homeAddress = "192.0.2.10";
        const string virtualAddress = "198.51.100.20";
        const string replacementHomeAddress = "203.0.113.30";
        var directory = Path.Combine(Path.GetTempPath(), "sofatap-credentials-" + Guid.NewGuid().ToString("N"));
        var path = Path.Combine(directory, "pairing.dat");
        try
        {
            string token; string fingerprint;
            using (var credentials = Credentials.LoadOrCreate(directory, [homeAddress]))
            {
                token = credentials.Token; fingerprint = credentials.Fingerprint;
                check(credentials.CertificateIPv4.Contains(homeAddress), "initial pairing certificate covers home address");
            }
            var persisted = File.ReadAllBytes(path);
            var stamp = File.GetLastWriteTimeUtc(path);
            void Same(IReadOnlyCollection<string> addresses, string label)
            {
                using (var credentials = Credentials.LoadOrCreate(directory, addresses))
                    check(credentials.Token == token && credentials.Fingerprint == fingerprint, label);
                check(File.ReadAllBytes(path).AsSpan().SequenceEqual(persisted) && File.GetLastWriteTimeUtc(path) == stamp,
                    label + " (pairing.dat untouched)");
            }
            // Network changes only change what is advertised, never the identity.
            Same([virtualAddress, homeAddress], "new virtual adapter keeps credentials");
            Same([], "offline restart keeps credentials");
            Same([virtualAddress], "complete address change keeps credentials");
            Same([replacementHomeAddress], "home address replacement keeps credentials");
            Same([virtualAddress, replacementHomeAddress], "VPN + replaced home address keeps credentials");
            Same([homeAddress], "returning to the original network keeps credentials");

            // A new Host build reuses an old pairing.dat written by the previous build:
            // copy the bytes into a fresh profile, as an app update/replacement would.
            var upgraded = Path.Combine(directory, "upgraded-host");
            Directory.CreateDirectory(upgraded);
            File.WriteAllBytes(Path.Combine(upgraded, "pairing.dat"), persisted);
            using (var credentials = Credentials.LoadOrCreate(upgraded, [replacementHomeAddress]))
                check(credentials.Token == token && credentials.Fingerprint == fingerprint,
                    "new Host on a different network reuses the old pairing.dat");
            check(File.ReadAllBytes(Path.Combine(upgraded, "pairing.dat")).AsSpan().SequenceEqual(persisted),
                "new Host does not rewrite the old pairing.dat");

            // Explicit reset is the user-facing way to rotate.
            using (var credentials = Credentials.LoadOrCreate(directory, [homeAddress], resetPairing: true))
            {
                check(credentials.Token != token && credentials.Fingerprint != fingerprint, "explicit reset rotates certificate and token");
                token = credentials.Token; fingerprint = credentials.Fingerprint;
            }
            using (var credentials = Credentials.LoadOrCreate(directory, [virtualAddress]))
                check(credentials.Token == token && credentials.Fingerprint == fingerprint, "reset pairing persists across restart");

            // Corrupt profile: regenerate, keep a diagnostic copy.
            var corrupt = Path.Combine(directory, "corrupt");
            Directory.CreateDirectory(corrupt);
            File.WriteAllText(Path.Combine(corrupt, "pairing.dat"), "{not json");
            using (var credentials = Credentials.LoadOrCreate(corrupt, [homeAddress]))
                check(credentials.Token.Length == 43 && credentials.Certificate.HasPrivateKey, "corrupt pairing.dat is regenerated");
            check(Directory.GetFiles(corrupt, "pairing.dat.corrupt-*").Length == 1, "corrupt pairing.dat is kept for diagnosis");
            File.WriteAllText(Path.Combine(corrupt, "pairing.dat"), "{\"Token\":\"short\",\"Pfx\":\"AA==\"}");
            using (var credentials = Credentials.LoadOrCreate(corrupt, [homeAddress]))
                check(credentials.Token.Length == 43, "invalid token in pairing.dat is regenerated");
        }
        finally { Directory.Delete(directory, true); }
    }
}
