using System;
using System.Diagnostics;
using System.Text;

/// <summary>
/// Starts AZITC-TK.ps1 in Windows PowerShell 5.1 without a console window, STA for WPF.
/// The console passes the device as separate arguments; each one is quoted again here, so a
/// device name or server name with a space survives the trip.
///
/// Usage: AZITC-TK-Launcher.exe <script.ps1> [-Name value ...]
/// Compile: csc.exe /target:winexe /out:AZITC-TK-Launcher.exe AZITC-TK-Launcher.cs
/// </summary>
class Program
{
    static int Main(string[] args)
    {
        if (args.Length == 0)
        {
            return 1;
        }

        StringBuilder arguments = new StringBuilder();
        arguments.Append("-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File ");
        arguments.Append(Quote(args[0]));
        for (int i = 1; i < args.Length; i++)
        {
            arguments.Append(' ');
            arguments.Append(Quote(args[i]));
        }

        ProcessStartInfo psi = new ProcessStartInfo
        {
            FileName = Environment.ExpandEnvironmentVariables(@"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"),
            Arguments = arguments.ToString(),
            UseShellExecute = false,
            CreateNoWindow = true
        };

        Process.Start(psi);
        return 0;
    }

    // Switches (-Name) stay bare so PowerShell binds them; everything else is quoted.
    static string Quote(string value)
    {
        if (value.StartsWith("-") && value.IndexOf(' ') < 0)
        {
            return value;
        }
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }
}
