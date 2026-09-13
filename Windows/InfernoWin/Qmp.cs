using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;

namespace InfernoWin;

/// Minimal QMP client. The iPhone VM listens on 127.0.0.1:&lt;port&gt; inside WSL2, which Windows reaches
/// through WSL's localhost forwarding. Inferno maps the device buttons to function keys.
public static class Qmp
{
    public static async Task Send(int port, string commandJson)
    {
        using var client = new TcpClient();
        await client.ConnectAsync("127.0.0.1", port);
        using var stream = client.GetStream();
        var greeting = new byte[4096];
        _ = await stream.ReadAsync(greeting);
        var bytes = Encoding.UTF8.GetBytes("{\"execute\":\"qmp_capabilities\"}\n" + commandJson + "\n");
        await stream.WriteAsync(bytes);
        await Task.Delay(400);
    }

    public static Task SendKey(int port, string qcode, int holdMilliseconds = 120) =>
        Send(port, "{\"execute\":\"send-key\",\"arguments\":{\"keys\":[{\"type\":\"qcode\",\"data\":\"" + qcode +
                   "\"}],\"hold-time\":" + holdMilliseconds + "}}");

    public static Task Quit(int port) => Send(port, "{\"execute\":\"quit\"}");
}

public sealed record DeviceButton(string Title, string QCode)
{
    public static readonly DeviceButton[] All =
    {
        new("Power", "f5"), new("Home", "f6"), new("Vol +", "f4"), new("Vol −", "f3"), new("Ringer", "f2"),
    };
}
