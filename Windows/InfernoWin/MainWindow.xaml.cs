using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace InfernoWin;

public partial class MainWindow : Window
{
    readonly VmStore store = new();
    readonly IReadOnlyList<SupportEntry> entries = Manifest.Load();
    // One setup runner and one session per VM for the whole app session.
    readonly Dictionary<Guid, SetupRunner> runners = new();
    readonly Dictionary<Guid, VmSession> sessions = new();
    readonly Dictionary<Guid, System.Text.StringBuilder> setupLogs = new();
    readonly Dictionary<Guid, System.Text.StringBuilder> consoleLogs = new();

    VmRecord? Selected => VmList.SelectedItem as VmRecord;
    SupportEntry? EntryFor(VmRecord vm) => entries.FirstOrDefault(e => e.Id == vm.EntryId);

    public MainWindow()
    {
        InitializeComponent();
        VmList.ItemsSource = store.Machines;
        foreach (var button in DeviceButton.All)
        {
            var b = new Button { Content = button.Title, Padding = new Thickness(10, 3, 10, 3), Margin = new Thickness(0, 0, 6, 0) };
            b.Click += async (_, _) => await OnSession(s => s.Press(button));
            ButtonsPanel.Children.Add(b);
        }
        Loaded += (_, _) =>
        {
            if (!VmStore.BackendInstalled) ShowFirstRun();
            if (store.Machines.Count > 0) VmList.SelectedIndex = 0;
            Refresh();
        };
        Closing += (_, e) =>
        {
            if (sessions.Values.Any(s => s.IsRunning) &&
                MessageBox.Show("A VM is still running. Quit anyway? The VM will be stopped.", "InfernoWin",
                                MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
                e.Cancel = true;
            else
                foreach (var s in sessions.Values.Where(s => s.IsRunning)) _ = s.Stop();
        };
    }

    // MARK: VM list

    void ShowFirstRun() => new FirstRunWindow { Owner = this }.ShowDialog();

    void FirstRun_Click(object sender, RoutedEventArgs e) => ShowFirstRun();

    void NewVm_Click(object sender, RoutedEventArgs e)
    {
        if (!VmStore.BackendInstalled) { ShowFirstRun(); if (!VmStore.BackendInstalled) return; }
        var dialog = new NewVmWindow(entries) { Owner = this };
        if (dialog.ShowDialog() != true || dialog.Result == null) return;
        store.Add(dialog.Result);
        VmList.SelectedItem = dialog.Result;
        Tabs.SelectedItem = SetupTab;
    }

    async void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } vm) return;
        if (sessions.TryGetValue(vm.Id, out var s) && s.IsRunning) { MessageBox.Show("Stop the VM first."); return; }
        if (MessageBox.Show($"Delete “{vm.Name}” and its disks inside WSL? This can't be undone.", "Delete VM",
                            MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
        await Wsl.Run($"rm -rf {vm.WslFolder}");
        store.Remove(vm);
        Refresh();
    }

    void VmList_SelectionChanged(object sender, SelectionChangedEventArgs e) => Refresh();

    void Refresh()
    {
        if (Selected is not { } vm || EntryFor(vm) is not { } entry)
        {
            Detail.Visibility = Visibility.Collapsed;
            EmptyText.Visibility = Visibility.Visible;
            return;
        }
        Detail.Visibility = Visibility.Visible;
        EmptyText.Visibility = Visibility.Collapsed;
        VmTitle.Text = vm.Name;
        VmSubtitle.Text = $"{entry.DeviceName} · iOS {entry.Ios}" + (vm.Jailbroken ? " · jailbroken" : "");

        var runner = Runner(vm, entry);
        StepsList.ItemsSource = SetupRunner.Steps.Select(s => new
        {
            s.Title,
            Icon = runner.States[s.Id] switch
            {
                SetupRunner.StepState.Done => "✔",
                SetupRunner.StepState.Running => "⏳",
                SetupRunner.StepState.Failed => "✖",
                _ => "○",
            },
        }).ToList();
        SetupButton.IsEnabled = !runner.IsRunning;
        SetupButton.Content = runner.IsRunning ? "Setting up…" : vm.State == VmState.Failed ? "Retry Setup" : vm.State == VmState.Ready ? "Run Setup Again" : "Set Up";
        SetupLog.Text = LogFor(setupLogs, vm).ToString();
        SetupLog.ScrollToEnd();

        var running = sessions.TryGetValue(vm.Id, out var session) && session.IsRunning;
        StartButton.IsEnabled = vm.State == VmState.Ready && !running;
        StopButton.IsEnabled = running;
        RunStatus.Text = running ? "Running" : vm.State == VmState.Ready ? "Ready" : "Finish setup first";
        ButtonsPanel.IsEnabled = running;
        JailbreakHeader.Visibility = JailbreakPanel.Visibility = vm.Jailbroken ? Visibility.Visible : Visibility.Collapsed;
        JailbreakPanel.IsEnabled = running;
        ConsoleLog.Text = LogFor(consoleLogs, vm).ToString();
        ConsoleLog.ScrollToEnd();
        VmList.Items.Refresh();
    }

    static System.Text.StringBuilder LogFor(Dictionary<Guid, System.Text.StringBuilder> logs, VmRecord vm)
    {
        if (!logs.TryGetValue(vm.Id, out var sb)) logs[vm.Id] = sb = new System.Text.StringBuilder();
        return sb;
    }

    // MARK: setup

    SetupRunner Runner(VmRecord vm, SupportEntry entry)
    {
        if (runners.TryGetValue(vm.Id, out var existing)) return existing;
        var runner = new SetupRunner(vm, entry);
        if (vm.State == VmState.Ready)
            foreach (var (id, _) in SetupRunner.Steps) runner.States[id] = SetupRunner.StepState.Done;
        runner.Changed += () => Dispatcher.Invoke(() => { if (Selected == vm) Refresh(); });
        runner.Log += line => Dispatcher.Invoke(() =>
        {
            LogFor(setupLogs, vm).AppendLine(line);
            if (Selected == vm) { SetupLog.AppendText(line + "\n"); SetupLog.ScrollToEnd(); }
        });
        runner.Progress += pct => Dispatcher.Invoke(() =>
        {
            if (Selected != vm) return;
            SetupProgress.Visibility = pct >= 0 ? Visibility.Visible : Visibility.Collapsed;
            if (pct >= 0) SetupProgress.Value = pct;
        });
        runner.Finished += (ok, message) => Dispatcher.Invoke(() =>
        {
            vm.State = ok ? VmState.Ready : VmState.Failed;
            store.Save();
            LogFor(setupLogs, vm).AppendLine(ok ? "== VM is ready — go to the Device tab and press Start" : "!! " + message);
            SetupProgress.Visibility = Visibility.Collapsed;
            Refresh();
            FlashIfInactive();
        });
        runners[vm.Id] = runner;
        return runner;
    }

    async void SetUp_Click(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } vm || EntryFor(vm) is not { } entry) return;
        vm.State = VmState.SettingUp;
        store.Save();
        var runner = Runner(vm, entry);
        var task = runner.Run();
        Refresh();
        await task;
    }

    void FlashIfInactive()
    {
        if (!IsActive) System.Media.SystemSounds.Asterisk.Play();
    }

    // MARK: running

    VmSession Session(VmRecord vm, SupportEntry entry)
    {
        if (sessions.TryGetValue(vm.Id, out var existing)) return existing;
        var port = 4450 + store.Machines.IndexOf(vm);
        var session = new VmSession(vm, entry, port);
        session.Output += text => Dispatcher.Invoke(() =>
        {
            LogFor(consoleLogs, vm).Append(text);
            if (Selected == vm) { ConsoleLog.AppendText(text); ConsoleLog.ScrollToEnd(); }
        });
        session.Exited += code => Dispatcher.Invoke(() =>
        {
            LogFor(consoleLogs, vm).AppendLine($"\n[VM exited with status {code}]");
            Refresh();
        });
        sessions[vm.Id] = session;
        return session;
    }

    async void Start_Click(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } vm || EntryFor(vm) is not { } entry) return;
        StartButton.IsEnabled = false;
        RunStatus.Text = "Starting (the companion VM comes up first)…";
        await Session(vm, entry).Start();
        Refresh();
    }

    async void Stop_Click(object sender, RoutedEventArgs e) => await OnSession(s => s.Stop());

    async Task OnSession(System.Func<VmSession, Task> action)
    {
        if (Selected is not { } vm || !sessions.TryGetValue(vm.Id, out var s) || !s.IsRunning) return;
        try { await action(s); }
        catch (System.Exception ex) { Note(vm, "couldn't reach the VM's control port: " + ex.Message); }
    }

    void Note(VmRecord vm, string text)
    {
        var line = $"\n[{text}]\n";
        LogFor(consoleLogs, vm).Append(line);
        if (Selected == vm) { ConsoleLog.AppendText(line); ConsoleLog.ScrollToEnd(); }
    }

    void SendLines(params string[] lines)
    {
        if (Selected is not { } vm || !sessions.TryGetValue(vm.Id, out var s) || !s.IsRunning) return;
        foreach (var line in lines) s.Send(line);
        Tabs.SelectedItem = ConsoleTab;
    }

    // MARK: device actions (same commands as InfernoMac)

    async void Trust_Click(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } vm) return;
        Tabs.SelectedItem = ConsoleTab;
        Note(vm, "asking iOS to trust the companion…");
        var (_, output) = await Wsl.Run("source \"$HOME/.infernowin/wsl/common.sh\" && \"${CSSH[@]}\" " +
            Wsl.Q("sudo systemctl start usbmuxd; sleep 3; idevicepair pair 2>&1; idevicepair validate 2>&1"));
        Note(vm, output.Contains("SUCCESS") ? "paired ✓ — USB internet should come up within a minute"
               : output.Contains("denied") ? "iOS refused (Don't Trust was tapped). Stop and Start the VM, then try again and tap Trust."
               : output.Contains("Please accept") ? "Prompt shown — tap Trust in the VM, then press Send Trust Prompt again."
               : output.Trim());
    }

    async void RestartInternet_Click(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } vm) return;
        Tabs.SelectedItem = ConsoleTab;
        Note(vm, "restarting USB internet on the companion…");
        var (_, output) = await Wsl.Run("source \"$HOME/.infernowin/wsl/common.sh\" && \"${CSSH[@]}\" " +
            Wsl.Q("sudo systemctl restart usbmuxd; sudo systemctl restart iphone-tether.service; sudo systemctl restart dnsmasq; ip -br addr | grep enx || echo 'no iPhone network interface yet'"));
        Note(vm, output.Trim());
    }

    void Writable_Click(object sender, RoutedEventArgs e) => SendLines(
        "mount -uw /",
        "mkdir -p /var/lib/dpkg/info /var/lib/dpkg/updates /var/lib/apt/lists/partial /var/cache/apt/archives/partial /etc/apt/sources.list.d",
        "touch /var/lib/dpkg/status /var/lib/dpkg/available",
        "mount | grep ' / ' && echo SYSTEM_WRITABLE");

    void Zebra_Click(object sender, RoutedEventArgs e)
    {
        Writable_Click(sender, e);
        SendLines(
            "echo 'deb https://apt.bingner.com/ ios/1700.00 main' > /etc/apt/sources.list.d/bingner.list",
            "echo 'deb [trusted=yes] https://getzbra.com/repo/ ./' > /etc/apt/sources.list.d/zebra.list",
            "apt-get update",
            "mkdir -p /tmp/debs && cd /tmp/debs && rm -f *.deb && apt-get download --allow-unauthenticated xyz.willy.zebra uikittools",
            "dpkg -i --force-depends --force-overwrite /tmp/debs/*.deb",
            "uicache -p /Applications/Zebra.app",
            "echo ZEBRA_INSTALL_DONE",
            "killall -9 SpringBoard");
    }

    void Respring_Click(object sender, RoutedEventArgs e) => SendLines("killall -9 SpringBoard");

    // MARK: console

    void Send_Click(object sender, RoutedEventArgs e) => SendConsoleInput();

    void ConsoleInput_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) { SendConsoleInput(); e.Handled = true; }
    }

    void SendConsoleInput()
    {
        if (Selected is not { } vm || !sessions.TryGetValue(vm.Id, out var s) || !s.IsRunning) return;
        s.Send(ConsoleInput.Text);
        ConsoleInput.Clear();
    }
}
