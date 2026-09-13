using System;
using System.Diagnostics;
using System.Threading.Tasks;

namespace InfernoWin;

/// One running iPhone VM: start_vm.sh inside WSL, with its serial console on stdin/stdout.
/// The phone screen is a GTK window that WSLg shows on the Windows desktop.
public sealed class VmSession
{
    public VmRecord Vm { get; }
    public SupportEntry Entry { get; }
    public int QmpPort { get; }
    Process? process;

    public bool IsRunning => process is { HasExited: false };
    public event Action<string>? Output;
    public event Action<int>? Exited;

    public VmSession(VmRecord vm, SupportEntry entry, int qmpPort)
    {
        Vm = vm;
        Entry = entry;
        QmpPort = qmpPort;
    }

    public async Task Start()
    {
        if (IsRunning) return;
        Output?.Invoke("[starting companion VM for USB internet]\n");
        var (code, _) = await Wsl.Script("companion.sh", new[] { "start" }, line => Output?.Invoke(line + "\n"));
        if (code != 0) Output?.Invoke("[companion failed to start — booting without USB internet]\n");

        var cmd = Wsl.Join($"{Wsl.ScriptsDir}/start_vm.sh", Vm.WslFolder, Vm.WslFile("entry.json"),
                           Vm.Jailbroken ? "1" : "0", QmpPort.ToString());
        var p = new Process { StartInfo = Wsl.Info(cmd), EnableRaisingEvents = true };
        p.ErrorDataReceived += (_, e) => { if (e.Data != null) Output?.Invoke(e.Data + "\n"); };
        p.Exited += (_, _) => Exited?.Invoke(SafeExitCode(p));
        p.Start();
        p.BeginErrorReadLine();
        process = p;
        // Read stdout in chunks, not lines: the shell prompt ("bash-5.0# ") has no newline.
        _ = Task.Run(async () =>
        {
            var buffer = new char[4096];
            int n;
            while ((n = await p.StandardOutput.ReadAsync(buffer, 0, buffer.Length)) > 0)
                Output?.Invoke(new string(buffer, 0, n));
        });
    }

    /// Text typed in the Console goes to the guest's serial console (e.g. the jailbreak root shell).
    public void Send(string line)
    {
        if (!IsRunning) return;
        process!.StandardInput.Write(line + "\n");
        process.StandardInput.Flush();
    }

    public Task Stop() => IsRunning ? Qmp.Quit(QmpPort) : Task.CompletedTask;

    public Task Press(DeviceButton button, int holdMilliseconds = 120) => Qmp.SendKey(QmpPort, button.QCode, holdMilliseconds);

    static int SafeExitCode(Process p)
    {
        try { return p.ExitCode; } catch { return -1; }
    }
}
