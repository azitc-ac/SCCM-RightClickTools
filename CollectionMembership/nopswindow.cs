using System;
using System.Diagnostics;
using System.Linq;

/// <summary>
/// Startet ein PowerShell-Skript ohne sichtbares Fenster.
/// Kompilierung: csc.exe /out:nopswindow.exe nopswindow.cs
/// </summary>
class Program
{
    static void Main(string[] args)
    {
        if (args.Length == 0)
        {
            Console.WriteLine("Usage: nopswindow.exe <script.ps1> [args...]");
            Environment.Exit(1);
        }

        string scriptPath = args[0];

        // Restliche Parameter zusammensetzen
        string additionalArgs = args.Length > 1
            ? " " + string.Join(" ", args.Skip(1))
            : "";

        ProcessStartInfo psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = "-ExecutionPolicy Bypass -NonInteractive -File \"" + scriptPath + "\"" + additionalArgs,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        Process.Start(psi);
    }
}
