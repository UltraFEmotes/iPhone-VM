InfernoWin — an emulated iPhone 11 on Windows
=============================================

InfernoWin runs the ChefKiss Inferno emulator inside WSL2 (Linux on Windows) and gives it a Windows
interface: make a VM, set it up, start it, press the phone's buttons, and use its console.

This is a first version that has only been built, not yet run on Windows. Expect rough edges, and
send back the log text when something fails.


What your PC needs
------------------
- Windows 11, or Windows 10 22H2 with the latest updates
- Virtualization turned on in the BIOS/UEFI (Intel VT-x / AMD-V, often called "SVM" on AMD)
- 16 GB RAM recommended (8 GB minimum)
- About 40 GB free on C: (the emulator build, one iPhone firmware download, and one VM)
- A few hours for the first setup; most of it runs unattended


Speed: please read
------------------
Inferno emulates the iPhone entirely in software on every platform, Macs included, so booting can take
many minutes and the home screen will be sluggish. That's expected, not a bug. Only the small helper VM
uses hardware acceleration. How fast it is on your PC hasn't been measured yet, so please share yours.


First run
---------
1. Unzip this folder anywhere (for example Documents\InfernoWin) and open InfernoWin.exe.
   If Windows SmartScreen warns about an unknown app, click "More info" > "Run anyway".
2. The Setup window checks for WSL2.
   - If it's missing, click "Install WSL2 + Ubuntu". Restart Windows if asked, then open "Ubuntu"
     from the Start menu once and pick a Linux username and password. Reopen InfernoWin.
3. Click "Start Setup". It builds the emulator and a small helper Linux VM inside Ubuntu
   (20–60 minutes). Linux asks for your password for installs: if the log stops at a password
   prompt, open Ubuntu, type  sudo -v  and your password, then click Start Setup again.
   Setup resumes where it stopped whenever you re-run it.


Making an iPhone VM
-------------------
1. New VM… > pick "iPhone 11 — iOS 14.0 beta 5" (the tested one) > tick Jailbreak if you want a
   root shell > Create.
2. Setup tab > Set Up. It downloads the firmware from Apple (~5 GB), restores iOS and patches it.
   This takes a while; you can leave it running.
3. Device tab > Start. The phone screen opens in its own window.
   - Buttons: Power, Home, Vol +/−, Ringer (also F5, F6, F4, F3, F2 in the phone window)
   - Send Trust Prompt: tap "Trust" in the phone to give it internet through the helper VM
   - Console tab: type commands into the phone's root shell (jailbroken VMs)


Known risks
-----------
- The last setup step ("Patch filesystem") writes to the iPhone disk using an experimental Linux
  APFS driver. The Inferno developers have only tested this step on macOS. InfernoWin keeps an
  untouched copy (root.prepatch) until patching succeeds.
- Only iPhone 11 / iOS 14.0 beta 5 is tested. Other versions are marked experimental.
- Don't set a passcode, don't enable Location Services, and never use "Erase All Content and
  Settings" inside the iPhone — the Inferno guide warns these break the installation.


Where things are
----------------
- VM list: %LOCALAPPDATA%\InfernoWin\vms.json
- Everything else lives inside Ubuntu, in ~/InfernoData (emulator, helper VM, firmware, VM disks).
  To free space, delete a VM from the app, or remove ~/InfernoData/ipsw-cache after setup finishes.


Troubleshooting
---------------
- "companion did not come up": the helper VM boots slowly without hardware acceleration. Enabling
  nested virtualization for WSL2 (Windows 11: add  nestedVirtualization=true  under [wsl2] in
  %UserProfile%\.wslconfig, then run  wsl --shutdown ) makes it much faster.
- No phone window: make sure WSLg works (in Ubuntu, try  xeyes  after  sudo apt install x11-apps ).
- Copy the log text from the Setup tab or Console tab and send it over.
