// ---------------------------------------------------------------------------
// DshDeck.cs - the source of Start.exe, the double-click entry point.
//
// WHY AN EXE EXISTS AT ALL
//
// A Windows shortcut stores ABSOLUTE paths, so a .lnk committed to this repo
// would point at whichever machine generated it - and *.lnk is git-ignored
// because a shortcut is a per-user artefact. An exe has the opposite property:
// it lives in the repo, a shortcut may point at it, and the path is then only
// as fragile as the checkout itself. It also carries the panel's own icon, so
// "right-click -> Send to -> Desktop (create shortcut)" produces something that
// looks like an application instead of a generic console file.
//
// WHAT IT DOES
//
//   * finds the panel payload: the checkout it was launched from, or - when it
//     was copied somewhere on its own - the payload embedded in this binary;
//   * extracts embedded files to %LOCALAPPDATA%\dsh-deck\<version>\ and runs
//     from there, so the exe works when separated from the repo;
//   * starts the panel by delegating to dsh.ps1, which owns all the real logic.
//     This deliberately does not reimplement any of it: one launcher, one place
//     where behaviour is decided.
//
// NOT A SINGLE-FILE PANEL. Node.js is still required, and the panel backend is
// still app/server.js run by node. Bundling a Node runtime is a different and
// much larger promise, and README's "What it needs" section says so.
//
// BUILD IT WITH tools/build-exe.ps1, which uses the C# compiler that ships with
// Windows - no SDK, no Visual Studio, no NuGet.
// ---------------------------------------------------------------------------
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;

namespace DshDeck
{
    internal static class Program
    {
        private static int Main(string[] args)
        {
            try
            {
                string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
                string payload = ResolvePayload(exeDir);
                string launcher = Path.Combine(payload, "dsh.ps1");

                string powershell = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.System),
                    @"WindowsPowerShell\v1.0\powershell.exe");
                if (!File.Exists(powershell)) { powershell = "powershell.exe"; }

                ProcessStartInfo psi = new ProcessStartInfo(powershell);
                psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + launcher + "\" -Command app";
                if (args != null && args.Length > 0)
                {
                    psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + launcher + "\" " + JoinArgs(args);
                }
                // Console + UseShellExecute=false: stdout and stderr stay attached
                // to this window, so a failure is visible instead of vanishing.
                // That was the original complaint about this entry point.
                psi.UseShellExecute = false;
                psi.WorkingDirectory = payload;
                using (Process p = Process.Start(psi))
                {
                    p.WaitForExit();
                    if (p.ExitCode != 0)
                    {
                        Console.Error.WriteLine();
                        Console.Error.WriteLine("  The panel did not start (exit code " + p.ExitCode + ").");
                        Console.Error.WriteLine();
                        Console.Error.WriteLine("  See what is wrong with:");
                        Console.Error.WriteLine("    powershell -NoProfile -ExecutionPolicy Bypass -File \"" + launcher + "\" -Command doctor");
                        Console.Error.WriteLine();
                        Console.Error.WriteLine("  Press any key to close.");
                        try { Console.ReadKey(true); } catch { }
                    }
                    return p.ExitCode;
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine();
                Console.Error.WriteLine("  dsh-deck could not start: " + ex.Message);
                Console.Error.WriteLine();
                Console.Error.WriteLine("  Press any key to close.");
                try { Console.ReadKey(true); } catch { }
                return 1;
            }
        }

        private static string JoinArgs(string[] args)
        {
            List<string> parts = new List<string>();
            foreach (string a in args)
            {
                if (a.IndexOf(' ') >= 0) { parts.Add("\"" + a + "\""); }
                else { parts.Add(a); }
            }
            return string.Join(" ", parts.ToArray());
        }

        /// <summary>
        /// The directory that holds dsh.ps1 and app/, or null when neither the
        /// checkout nor the embedded copy can provide one.
        ///
        /// Order: the checkout first (dsh.ps1 beside this exe, or one or two
        /// levels up, which covers bin\Start.exe and tools\exe\Start.exe), then
        /// the embedded payload. Checking the checkout first keeps a developer's
        /// working tree authoritative - an exe built last week must not shadow
        /// the dsh.ps1 someone is editing right now.
        /// </summary>
        private static string ResolvePayload(string exeDir)
        {
            string[] roots = new string[]
            {
                exeDir,
                exeDir == null ? null : Path.GetDirectoryName(exeDir),
                exeDir == null ? null : Path.GetDirectoryName(Path.GetDirectoryName(exeDir)),
            };
            foreach (string root in roots)
            {
                if (string.IsNullOrEmpty(root)) { continue; }
                if (File.Exists(Path.Combine(root, "dsh.ps1")) &&
                    File.Exists(Path.Combine(root, "app", "server.js")))
                {
                    return root;
                }
            }
            return ExtractEmbedded();
        }

        /// <summary>
        /// Write the embedded panel payload into the per-user cache and return
        /// that directory.
        ///
        /// Extraction is skipped only when the cache is complete AND carries the
        /// fingerprint of the payload this binary holds. Keying that on the
        /// assembly version alone was not enough: rebuilding Start.exe with a
        /// changed dsh.ps1 but the same version left a cache that looked complete,
        /// so a copied exe kept running the OLD panel with no way to tell. The
        /// fingerprint is a new file in a new version of this binary, so an
        /// existing cache never matches it and is refreshed once, after which
        /// launches skip extraction again.
        /// </summary>
        private static string ExtractEmbedded()
        {
            string version = Assembly.GetExecutingAssembly().GetName().Version.ToString();
            string root = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "dsh-deck", version);

            Assembly asm = Assembly.GetExecutingAssembly();
            string[] names = asm.GetManifestResourceNames();

            List<string> files = new List<string>();
            foreach (string n in names)
            {
                if (n.StartsWith("payload/", StringComparison.Ordinal)) { files.Add(n); }
            }
            files.Sort(StringComparer.Ordinal);
            if (files.Count == 0)
            {
                throw new InvalidOperationException(
                    "no embedded panel payload found. Start.exe is built by tools/build-exe.ps1, " +
                    "which embeds dsh.ps1, app/ and the icon; an exe without them cannot run " +
                    "outside a checkout.");
            }

            string stamp = PayloadStamp(asm, files);
            string stampFile = Path.Combine(root, ".payload");

            bool current = false;
            try { current = File.Exists(stampFile) && File.ReadAllText(stampFile).Trim() == stamp; }
            catch { current = false; }

            if (current)
            {
                bool complete = true;
                foreach (string n in files)
                {
                    string rel = n.Substring("payload/".Length).Replace('/', Path.DirectorySeparatorChar);
                    if (!File.Exists(Path.Combine(root, rel))) { complete = false; break; }
                }
                if (complete) { return root; }
            }

            Directory.CreateDirectory(root);
            foreach (string n in files)
            {
                string rel = n.Substring("payload/".Length).Replace('/', Path.DirectorySeparatorChar);
                string target = Path.Combine(root, rel);
                string dir = Path.GetDirectoryName(target);
                if (!string.IsNullOrEmpty(dir)) { Directory.CreateDirectory(dir); }

                // Write beside the target and move into place, so an interrupted
                // extraction cannot leave a half-written dsh.ps1 that then fails
                // to parse on the next launch.
                string staging = target + ".new";
                using (Stream src = asm.GetManifestResourceStream(n))
                using (FileStream dst = new FileStream(staging, FileMode.Create, FileAccess.Write))
                {
                    src.CopyTo(dst);
                }
                // A file the running panel holds open makes the replace fail; the
                // extracted copy is still the right one, so continue.
                try
                {
                    if (File.Exists(target)) { File.Delete(target); }
                    File.Move(staging, target);
                }
                catch (IOException)
                {
                    try { File.Delete(staging); } catch { }
                }
            }
            SweepStaging(root);
            try { File.WriteAllText(stampFile, stamp); } catch { }

            return root;
        }

        /// <summary>
        /// A fingerprint of the embedded payload: the binary's version plus each
        /// resource's length and write time. Length and timestamp come from the
        /// resource table, so nothing is read or hashed here - and since the
        /// build stamps resources as it embeds them, a rebuilt payload always
        /// differs.
        /// </summary>
        private static string PayloadStamp(Assembly asm, List<string> files)
        {
            string version;
            try { version = asm.GetName().Version.ToString(); }
            catch { version = "0.0.0.0"; }
            StringBuilder sb = new StringBuilder(version);
            foreach (string n in files)
            {
                sb.Append('|').Append(n);
                try
                {
                    using (Stream s = asm.GetManifestResourceStream(n))
                    {
                        sb.Append(':').Append(s == null ? -1 : s.Length);
                    }
                    sb.Append('@').Append(File.GetLastWriteTimeUtc(asm.Location).Ticks);
                }
                catch { sb.Append(":?"); }
            }
            return sb.ToString();
        }

        /// <summary>Remove staging files left by an interrupted extraction.</summary>
        private static void SweepStaging(string root)
        {
            try
            {
                string[] stale = Directory.GetFiles(root, "*.new", SearchOption.AllDirectories);
                foreach (string f in stale) { try { File.Delete(f); } catch { } }
            }
            catch { }
        }
    }
}
