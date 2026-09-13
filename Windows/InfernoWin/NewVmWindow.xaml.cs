using System.Collections.Generic;
using System.Linq;
using System.Windows;

namespace InfernoWin;

public partial class NewVmWindow : Window
{
    readonly IReadOnlyList<SupportEntry> entries;
    public VmRecord? Result { get; private set; }

    public NewVmWindow(IReadOnlyList<SupportEntry> entries)
    {
        InitializeComponent();
        this.entries = entries;
        Fill();
    }

    void Fill()
    {
        var shown = entries.Where(e => e.IsTested || ExperimentalBox.IsChecked == true).ToList();
        EntryBox.ItemsSource = shown;
        EntryBox.SelectedIndex = shown.Count > 0 ? 0 : -1;
    }

    void ExperimentalBox_Changed(object sender, RoutedEventArgs e) => Fill();

    void EntryBox_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (EntryBox.SelectedItem is not SupportEntry entry) return;
        JailbreakBox.IsEnabled = entry.CanJailbreak;
        if (!entry.CanJailbreak) JailbreakBox.IsChecked = false;
        if (string.IsNullOrWhiteSpace(NameBox.Text) || NameBox.Tag as string == NameBox.Text)
        {
            NameBox.Text = $"{entry.DeviceName} (iOS {entry.Ios})";
            NameBox.Tag = NameBox.Text;
        }
        Note.Text = (entry.IsTested ? "" : "Experimental: this version hasn't been tested and may not finish setup or boot. ") +
                    (entry.SepVersion is > 14 ? $"Needs the emulator built for iOS {entry.SepVersion}. " : "") +
                    "Setup downloads the firmware from Apple (~5–8 GB) and needs about 18 GB free inside WSL.";
    }

    void Create_Click(object sender, RoutedEventArgs e)
    {
        if (EntryBox.SelectedItem is not SupportEntry entry) return;
        Result = new VmRecord
        {
            Name = string.IsNullOrWhiteSpace(NameBox.Text) ? entry.DeviceName : NameBox.Text.Trim(),
            EntryId = entry.Id,
            Jailbroken = JailbreakBox.IsChecked == true && entry.CanJailbreak,
        };
        DialogResult = true;
    }
}
