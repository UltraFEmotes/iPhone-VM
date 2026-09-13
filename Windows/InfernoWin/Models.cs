using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace InfernoWin;

/// One supported device + iOS version (same manifest.json as InfernoMac).
public sealed class SupportEntry
{
    public string Id { get; set; } = "";
    public string DeviceName { get; set; } = "";
    public string Device { get; set; } = "";
    public string Machine { get; set; } = "";
    public string Ios { get; set; } = "";
    public string Build { get; set; } = "";
    public string Status { get; set; } = "";
    public int? SepVersion { get; set; }
    public bool? UsesSEPSim { get; set; }
    public JailbreakInfo? Jailbreak { get; set; }

    /// The entry exactly as it appears in the manifest; written to the VM folder for the WSL scripts.
    [JsonIgnore] public string RawJson { get; set; } = "";

    public bool IsTested => Status == "tested";
    public bool CanJailbreak => Jailbreak?.Bootstrap == true;
    public string Title => $"{DeviceName} — iOS {Ios} ({Build})" + (IsTested ? "" : "   · experimental");
    public override string ToString() => Title;
}

public sealed class JailbreakInfo
{
    public bool Bootstrap { get; set; }
}

public static class Manifest
{
    static readonly JsonSerializerOptions Options = new() { PropertyNameCaseInsensitive = true };

    public static IReadOnlyList<SupportEntry> Load()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("InfernoWin.manifest.json")
            ?? throw new InvalidOperationException("manifest.json missing from the app");
        using var doc = JsonDocument.Parse(stream);
        return doc.RootElement.GetProperty("entries").EnumerateArray().Select(el =>
        {
            var entry = el.Deserialize<SupportEntry>(Options)!;
            entry.RawJson = el.GetRawText();
            return entry;
        }).ToList();
    }
}

public enum VmState { New, SettingUp, Ready, Failed }

public sealed class VmRecord
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public string EntryId { get; set; } = "";
    public bool Jailbroken { get; set; }
    public VmState State { get; set; } = VmState.New;

    /// Folder inside WSL, as a double-quoted bash word ($HOME expands, the GUID needs no escaping).
    public string WslFolder => $"\"$HOME/InfernoData/VMs/{Id}\"";
    public string WslFile(string name) => $"\"$HOME/InfernoData/VMs/{Id}/{name}\"";
    public override string ToString() => Name;
}
