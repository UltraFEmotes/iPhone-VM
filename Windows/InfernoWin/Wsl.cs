using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace InfernoWin;

/// Bridge to the bash backend inside WSL2. Everything Linux-side (building Inferno, the companion VM,
/// restore, patching, running the iPhone VM) happens in scripts under ~/.infernowin/wsl.
public static class Wsl
{
    public const string ScriptsDir = "$HOME/.infernowin/wsl";

    /// A wsl.exe process that runs one bash command line in the default distro.
    public static ProcessStartInfo Info(string bashCommand)
    {
        var psi = new ProcessStartInfo("wsl.exe")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        psi.ArgumentList.Add("-e");
        psi.ArgumentList.Add("bash");
        psi.ArgumentList.Add("-lc");
        psi.ArgumentList.Add(bashCommand);
        return psi;
    }

    /// Runs a bash command, streaming each output line; returns the exit code and all output.
    public static async Task<(int Code, string Output)> Run(string bashCommand, Action<string>? onLine = null,
                                                            string? stdin = null, CancellationToken ct = default)
    {
        using var p = new Process { StartInfo = Info(bashCommand) };
        var all = new StringBuilder();
        void Handle(string? line)
        {
            if (line == null) return;
            lock (all) all.AppendLine(line);
            onLine?.Invoke(line);
        }
        p.OutputDataReceived += (_, e) => Handle(e.Data);
        p.ErrorDataReceived += (_, e) => Handle(e.Data);
        p.Start();
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
        if (stdin != null) await p.StandardInput.WriteAsync(stdin);
        p.StandardInput.Close();
        await p.WaitForExitAsync(ct);
        return (p.ExitCode, all.ToString());
    }

    /// Runs one of the backend scripts. Arguments must already be bash words (see <see cref="Q"/>).
    public static Task<(int Code, string Output)> Script(string name, IEnumerable<string> args, Action<string>? onLine = null)
        => Run($"{ScriptsDir}/{name} " + string.Join(" ", args), onLine);

    /// Single-quotes a value for bash.
    public static string Q(string value) => "'" + value.Replace("'", "'\\''") + "'";

    /// Is WSL itself installed? (wsl.exe's own messages are UTF-16.)
    public static async Task<bool> IsInstalled()
    {
        try
        {
            var psi = new ProcessStartInfo("wsl.exe", "--status")
            {
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, StandardOutputEncoding = Encoding.Unicode,
            };
            using var p = Process.Start(psi)!;
            await p.StandardOutput.ReadToEndAsync();
            await p.WaitForExitAsync();
            return p.ExitCode == 0;
        }
        catch
        {
            return false;
        }
    }

    /// Is there a working Linux distro (WSL2) to run bash in?
    public static async Task<bool> HasLinux()
    {
        try
        {
            var (code, output) = await Run("echo INFERNO_OK; uname -r");
            return code == 0 && output.Contains("INFERNO_OK");
        }
        catch
        {
            return false;
        }
    }

    /// Installs WSL2 + Ubuntu (asks for administrator rights; Windows usually needs a restart after).
    public static void InstallUbuntu()
    {
        Process.Start(new ProcessStartInfo("wsl.exe", "--install -d Ubuntu") { UseShellExecute = true, Verb = "runas" });
    }

    /// Copies the bundled bash backend into WSL (fixing Windows line endings on the way).
    public static Task<(int Code, string Output)> DeployScripts(Action<string>? onLine = null)
    {
        var src = Path.Combine(AppContext.BaseDirectory, "wsl");
        var cmd = $"src=$(wslpath {Q(src)}) && rm -rf {ScriptsDir} && mkdir -p \"$HOME/.infernowin\" && cp -r \"$src\" {ScriptsDir}" +
                  $" && find {ScriptsDir} -type f ! -name '*.shsh2' -exec sed -i 's/\\r$//' {{}} +" +
                  $" && chmod +x {ScriptsDir}/*.sh {ScriptsDir}/companion-files/*.sh && echo DEPLOYED";
        return Run(cmd, onLine);
    }

    /// Writes text to a file inside WSL (creating its folder).
    public static Task<(int Code, string Output)> WriteFile(string bashPath, string folderBashPath, string content)
        => Run($"mkdir -p {folderBashPath} && cat > {bashPath}", stdin: content);

    public static string Join(params string[] words) => string.Join(" ", words.Where(w => w.Length > 0));
}
