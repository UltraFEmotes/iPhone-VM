using System;
using System.Windows;

namespace InfernoWin;

/// First run: make sure WSL2 + a Linux distro exist, copy the bash backend in, and run install.sh.
public partial class FirstRunWindow : Window
{
    public FirstRunWindow()
    {
        InitializeComponent();
        Loaded += async (_, _) => await CheckWsl();
    }

    async System.Threading.Tasks.Task CheckWsl()
    {
        WslStatus.Text = "Checking WSL…";
        if (await Wsl.HasLinux())
        {
            WslStatus.Text = "✓ WSL2 with Linux is ready";
            InstallWslButton.Visibility = Visibility.Collapsed;
            BuildButton.IsEnabled = true;
        }
        else
        {
            WslStatus.Text = await Wsl.IsInstalled()
                ? "WSL is installed but has no Linux distro yet"
                : "WSL2 is not installed";
            InstallWslButton.Visibility = Visibility.Visible;
        }
    }

    void InstallWsl_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Wsl.InstallUbuntu();
            Append("Installing WSL2 + Ubuntu in a separate window. When it finishes:\n" +
                   "  1. Restart Windows if it asks you to.\n" +
                   "  2. Open Ubuntu from the Start menu once and create your Linux username and password.\n" +
                   "  3. Reopen InfernoWin.\n");
        }
        catch (Exception ex)
        {
            Append("Couldn't start the WSL installer: " + ex.Message + "\nRun this in an administrator PowerShell instead:  wsl --install -d Ubuntu\n");
        }
    }

    async void Build_Click(object sender, RoutedEventArgs e)
    {
        BuildButton.IsEnabled = false;
        BuildStatus.Text = "Copying scripts into WSL…";
        var (deployCode, deployOut) = await Wsl.DeployScripts();
        if (deployCode != 0 || !deployOut.Contains("DEPLOYED"))
        {
            Append(deployOut);
            BuildStatus.Text = "Couldn't copy the scripts into WSL";
            BuildButton.IsEnabled = true;
            return;
        }
        BuildStatus.Text = "Building (20–60 min) — Linux may ask for your password";
        Append("Setup runs sudo inside Ubuntu. If it stops at a password prompt, open Ubuntu and run:\n" +
               "  sudo -v   (then click Start Setup again)\n\n");
        var (code, output) = await Wsl.Script("install.sh", Array.Empty<string>(), line => Dispatcher.Invoke(() =>
        {
            if (line.StartsWith("STEP:")) BuildStatus.Text = "Building: " + line[5..];
            Append(line + "\n");
        }));
        if (code == 0 && output.Contains("\nDONE"))
        {
            VmStore.BackendInstalled = true;
            BuildStatus.Text = "✓ Emulator and companion VM are ready";
            DoneButton.IsEnabled = true;
        }
        else
        {
            BuildStatus.Text = "Setup stopped — see the log, fix, and click Start Setup again (it resumes)";
            BuildButton.IsEnabled = true;
        }
    }

    void Done_Click(object sender, RoutedEventArgs e) => DialogResult = true;

    void Append(string text)
    {
        LogBox.AppendText(text);
        LogBox.ScrollToEnd();
    }
}
