// Launcher for Run-Maintenance.ps1
//
// - Embeds the PowerShell script as a resource, so the .exe is one single file.
// - Asks for administrator rights through its manifest (UAC prompt).
// - Extracts the script into a folder under "Program Files" (writable by
//   administrators only, so a normal program cannot swap the script while it
//   runs with elevated rights), runs it with Windows PowerShell, and deletes it.
// - With no arguments the PowerShell process runs without a console window, so
//   only the maintenance window is visible. With arguments (for example -All)
//   the output is shown in the console.
//
// Written in plain C# 5 so it compiles with the csc.exe that ships with Windows.

using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("PC Maintenance")]
[assembly: AssemblyProduct("PC Maintenance")]
[assembly: AssemblyDescription("Automated Windows PC maintenance")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

internal static class Launcher
{
    private const int ATTACH_PARENT_PROCESS = -1;
    private const string ResourceName = "Run-Maintenance.ps1";

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(int dwProcessId);

    [STAThread]
    private static int Main(string[] args)
    {
        string workDir = null;
        try
        {
            bool unattended = args.Length > 0;
            if (unattended)
            {
                // Best effort: show output in the terminal this was started from
                AttachConsole(ATTACH_PARENT_PROCESS);
            }

            string powershell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(powershell))
            {
                ShowError("Windows PowerShell was not found at:\r\n" + powershell);
                return 2;
            }

            string baseDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                "PCMaintenance");
            CleanOldRuns(baseDir);

            workDir = Path.Combine(baseDir, "run-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(workDir);
            string scriptPath = Path.Combine(workDir, "Run-Maintenance.ps1");
            ExtractScript(scriptPath);

            StringBuilder arguments = new StringBuilder();
            arguments.Append("-NoProfile -ExecutionPolicy Bypass -File ");
            arguments.Append(QuoteArg(scriptPath));
            foreach (string a in args)
            {
                arguments.Append(' ');
                arguments.Append(QuoteArg(a));
            }

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = powershell;
            psi.Arguments = arguments.ToString();
            psi.UseShellExecute = false;
            psi.CreateNoWindow = !unattended;

            using (Process p = Process.Start(psi))
            {
                p.WaitForExit();
                return p.ExitCode;
            }
        }
        catch (Exception ex)
        {
            ShowError("PC Maintenance could not start:\r\n\r\n" + ex.Message);
            return 1;
        }
        finally
        {
            if (workDir != null)
            {
                try { Directory.Delete(workDir, true); } catch { }
            }
        }
    }

    private static void ExtractScript(string path)
    {
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(ResourceName))
        {
            if (s == null)
            {
                throw new InvalidOperationException("The embedded script was not found in this program.");
            }
            using (FileStream f = File.Create(path))
            {
                s.CopyTo(f);
            }
        }
    }

    // Removes leftovers from runs that were killed before they could clean up
    private static void CleanOldRuns(string baseDir)
    {
        try
        {
            if (!Directory.Exists(baseDir)) { return; }
            foreach (string dir in Directory.GetDirectories(baseDir, "run-*"))
            {
                try
                {
                    if (Directory.GetCreationTimeUtc(dir) < DateTime.UtcNow.AddDays(-1))
                    {
                        Directory.Delete(dir, true);
                    }
                }
                catch { }
            }
        }
        catch { }
    }

    // Standard Windows command-line quoting for one argument
    private static string QuoteArg(string arg)
    {
        if (arg.Length > 0 && arg.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0)
        {
            return arg;
        }
        StringBuilder sb = new StringBuilder();
        sb.Append('"');
        int backslashes = 0;
        foreach (char c in arg)
        {
            if (c == '\\')
            {
                backslashes++;
            }
            else if (c == '"')
            {
                sb.Append('\\', backslashes * 2 + 1);
                sb.Append('"');
                backslashes = 0;
            }
            else
            {
                sb.Append('\\', backslashes);
                backslashes = 0;
                sb.Append(c);
            }
        }
        sb.Append('\\', backslashes * 2);
        sb.Append('"');
        return sb.ToString();
    }

    private static void ShowError(string text)
    {
        MessageBox.Show(text, "PC Maintenance", MessageBoxButtons.OK, MessageBoxIcon.Error);
    }
}
