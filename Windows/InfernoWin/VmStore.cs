using System;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace InfernoWin;

/// The VM list, saved as JSON in %LOCALAPPDATA%\InfernoWin. The VMs' disks live inside WSL.
public sealed class VmStore
{
    static readonly string Folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "InfernoWin");
    static readonly string File = Path.Combine(Folder, "vms.json");
    static readonly string InstalledFlag = Path.Combine(Folder, "installed");
    static readonly JsonSerializerOptions Options = new() { WriteIndented = true, Converters = { new JsonStringEnumConverter() } };

    public ObservableCollection<VmRecord> Machines { get; } = new();

    public VmStore()
    {
        Directory.CreateDirectory(Folder);
        if (!System.IO.File.Exists(File)) return;
        try
        {
            var list = JsonSerializer.Deserialize<VmRecord[]>(System.IO.File.ReadAllText(File), Options) ?? Array.Empty<VmRecord>();
            foreach (var vm in list) Machines.Add(vm);
        }
        catch
        {
            // A damaged list starts empty; the VM folders in WSL are untouched.
        }
    }

    public void Save() => System.IO.File.WriteAllText(File, JsonSerializer.Serialize(Machines.ToArray(), Options));

    public void Add(VmRecord vm)
    {
        Machines.Add(vm);
        Save();
    }

    public void Remove(VmRecord vm)
    {
        Machines.Remove(vm);
        Save();
    }

    /// Set once install.sh has finished, so the first-run window isn't shown again.
    public static bool BackendInstalled
    {
        get => System.IO.File.Exists(InstalledFlag);
        set
        {
            if (value) System.IO.File.WriteAllText(InstalledFlag, DateTime.Now.ToString("O"));
            else System.IO.File.Delete(InstalledFlag);
        }
    }
}
