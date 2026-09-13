using System;
using System.Collections.Generic;
using System.Threading.Tasks;

namespace InfernoWin;

/// Runs setup_vm.sh for one VM and turns its STEP:/SKIP:/PROGRESS:/FAIL:/DONE lines into events.
public sealed class SetupRunner
{
    public static readonly (string Id, string Title)[] Steps =
    {
        ("check-space", "Check free space"),
        ("download-ipsw", "Download firmware from Apple"),
        ("download-seprom", "Download SEP ROM"),
        ("extract", "Unpack firmware"),
        ("tickets", "Create boot tickets"),
        ("sep-firmware", "Prepare Secure Enclave firmware"),
        ("disks", "Create disks"),
        ("restore", "Restore iOS (companion VM)"),
        ("patch", "Patch filesystem (companion VM, experimental on Windows)"),
    };

    public enum StepState { Pending, Running, Done, Failed }

    public Dictionary<string, StepState> States { get; } = new();
    public bool IsRunning { get; private set; }

    public event Action? Changed;
    public event Action<string>? Log;
    public event Action<int>? Progress;
    public event Action<bool, string>? Finished;

    readonly VmRecord vm;
    readonly SupportEntry entry;

    public SetupRunner(VmRecord vm, SupportEntry entry)
    {
        this.vm = vm;
        this.entry = entry;
        foreach (var (id, _) in Steps) States[id] = StepState.Pending;
    }

    public async Task Run()
    {
        if (IsRunning) return;
        IsRunning = true;
        string? current = null;
        string failure = "";
        bool done = false;
        try
        {
            var (writeCode, writeOut) = await Wsl.WriteFile(vm.WslFile("entry.json"), vm.WslFolder, entry.RawJson);
            if (writeCode != 0) throw new InvalidOperationException("couldn't create the VM folder in WSL: " + writeOut);

            var args = new[] { vm.WslFolder, vm.WslFile("entry.json"), vm.Jailbroken ? "1" : "0" };
            await Wsl.Script("setup_vm.sh", args, line =>
            {
                if (line.StartsWith("STEP:") || line.StartsWith("SKIP:"))
                {
                    if (current != null && States[current] == StepState.Running) States[current] = StepState.Done;
                    current = line[5..];
                    if (States.ContainsKey(current)) States[current] = line.StartsWith("SKIP:") ? StepState.Done : StepState.Running;
                    Changed?.Invoke();
                    Progress?.Invoke(-1);
                }
                else if (line.StartsWith("PROGRESS:") && int.TryParse(line[9..], out var pct))
                {
                    Progress?.Invoke(pct);
                    return;
                }
                else if (line.StartsWith("FAIL:"))
                {
                    failure = line[5..];
                    if (current != null && States.ContainsKey(current)) States[current] = StepState.Failed;
                    Changed?.Invoke();
                }
                else if (line == "DONE")
                {
                    if (current != null && States.ContainsKey(current)) States[current] = StepState.Done;
                    done = true;
                    Changed?.Invoke();
                }
                Log?.Invoke(line);
            });
        }
        catch (Exception ex)
        {
            failure = ex.Message;
        }
        finally
        {
            IsRunning = false;
        }
        Finished?.Invoke(done, done ? "Ready" : (failure.Length > 0 ? failure : "setup stopped"));
    }
}
