# Supported software catalog

Generated from [`gui/config/apps.json`](https://github.com/ITakeCake/LabLifter/blob/main/gui/config/apps.json), the same file the
deployment engine runs from, so this list cannot drift from reality.

**81 application cards, 80 fully silent.** The exceptions are attended on purpose,
vendor installers with no working silent mode, documented per card. Only one card
is winget-sourced; every other application installs from a **natively staged
payload** (NSIS, Inno, MSI, InstallShield, ODT, DISM, file deploy), fully offline.

| Automation | Cards |
|---|---:|
| Automatic detection (installed / missing / broken, re-checked every scan) | 81 |
| Silent end-to-end install | 80 |
| Automated licensing (codes injected from a gitignored local file) | 5 |
| Dependency chains (prerequisite auto-installed first) | 15 |
| System PATH configuration (registry-level, REG_EXPAND_SZ-safe) | 2 |
| First-launch tracking (card stays amber until the app was opened once) | 12 |

| # | Application | Version | Install method | Silent | Auto-licence | PATH setup | Depends on | First-run tracked | Extras |
|---:|---|---|---|:---:|:---:|:---:|---|:---:|---|
| 1 | .NET Framework 3.5 (Windows Feature) | - | Windows Feature (DISM) | &#9989; |  |  | - |  | - |
| 2 | ADInstruments LabChart | 8.1.31 | Interactive (licence key) | &#9989; | &#9989; |  | - | &#9989; | - |
| 3 | Anaconda3 (Python distribution) | 2026.07-1 | Silent EXE | &#9989; |  |  | - |  | - |
| 4 | Ansys Electronics Desktop | 2025 R2 | Image Install | &#9989; |  |  | - |  | local-copy offload |
| 5 | Apache Maven | - | File Copy + PATH | &#9989; |  | &#9989; | OpenJDK |  | post-install config |
| 6 | Arduino App Lab | - | Silent EXE | &#9989; |  |  | - |  | - |
| 7 | Arduino IDE | - | File deploy | &#9989; |  |  | - | &#9989; | - |
| 8 | Arduino Lab for MicroPython | - | File deploy | &#9989; |  |  | - |  | - |
| 9 | Biology Public Desktop Folders | - | Config Copy | &#9989; |  |  | - |  | scripted uninstall |
| 10 | BLED112 USB Driver (Silicon Labs) | 1.2.0 (2013 signed pkg) | Driver Install (pnputil) | &#9989; |  |  | - |  | - |
| 11 | Chemistry Shortcut (Public Desktop) | - | Scripted Config | &#9989; |  |  | - |  | ordered |
| 12 | CLion | - | Silent EXE | &#9989; |  |  | VisualStudio |  | - |
| 13 | Cytek SpectroFlo | 3.0.3 | Attended Install (attended by design) |  |  |  | - | &#9989; | - |
| 14 | Digilent WaveForms | - | Silent EXE | &#9989; |  |  | - |  | - |
| 15 | Distance 7.5 | 7.5 | Silent EXE | &#9989; |  |  | - |  | - |
| 16 | EOTN (SimCC / SimVC) | - | Silent EXE | &#9989; |  |  | - |  | - |
| 17 | Excel Data Analysis Add-Ons | - | Scripted Config | &#9989; |  |  | - |  | ordered |
| 18 | FinchTV | - | Silent MSI | &#9989; |  |  | - |  | - |
| 19 | Git for Windows | - | Silent EXE | &#9989; |  |  | - |  | - |
| 20 | GitHub Desktop | - | MSI Install | &#9989; |  |  | Git |  | - |
| 21 | Go (Golang) | - | MSI Install | &#9989; |  |  | - |  | - |
| 22 | ImageJ | - | File deploy | &#9989; |  |  | - |  | - |
| 23 | IntelliJ IDEA Community Edition | - | Silent EXE | &#9989; |  |  | OpenJDK |  | - |
| 24 | JASP | - | Silent MSI | &#9989; |  |  | - |  | ordered |
| 25 | Java 8 (JRE) | 8u301 | Silent EXE | &#9989; |  |  | - |  | - |
| 26 | Keil MDK (uVision 5) | 5.41 | Silent Install | &#9989; |  |  | - |  | - |
| 27 | LabChart Add-Ons (Biology) | - | Scripted Install | &#9989; |  |  | LabChart |  | - |
| 28 | LabChart Licence - SCI1 (111/209/310/311/316) | - | File deploy | &#9989; | &#9989; |  | ['LabChart'] |  | ordered |
| 29 | LabChart Licence - SCI2 Biology (142/143/145) | - | File deploy | &#9989; | &#9989; |  | ['LabChart'] |  | ordered |
| 30 | Logisim Evolution | - | Silent MSI | &#9989; |  |  | - | &#9989; | - |
| 31 | Lt LabStation | 1.0.4 | Interactive (licence) | &#9989; | &#9989; |  | - |  | - |
| 32 | Lt LabStation 1.10.6 | 1.10.6 | Silent MSI | &#9989; | &#9989; |  | - |  | - |
| 33 | Lt LabStation Course Content | - | File deploy | &#9989; |  |  | - | &#9989; | - |
| 34 | LTSpice | - | Silent MSI | &#9989; |  |  | - | &#9989; | - |
| 35 | MATLAB | R2026a | GUI Image Install | &#9989; |  |  | - | &#9989; | local-copy offload, ordered |
| 36 | MATLAB + Simulink Arduino Support | - | Silent (mpm) | &#9989; |  |  | MATLAB |  | ordered |
| 37 | MATLAB Lab Defaults (UNIV) | - | Config Copy | &#9989; |  |  | MATLAB |  | ordered |
| 38 | Mbed Studio | - | Silent EXE | &#9989; |  |  | - |  | - |
| 39 | Microsoft Visio (Microsoft 365) | - | Licensed Install | &#9989; |  |  | - |  | ordered |
| 40 | MiniTab (web app shortcut) | - | Desktop Shortcut | &#9989; |  |  | - |  | - |
| 41 | MS Visual Studio 2015 Shell (Isolated) | - | Silent (bootstrapper) | &#9989; |  |  | - |  | - |
| 42 | MSYS2 | - | Silent EXE | &#9989; |  |  | - |  | - |
| 43 | NI ELVIS | - | Interactive (NI wizard) | &#9989; |  |  | - |  | post-install config |
| 44 | NI LabVIEW 2021 SP1 (32-bit) + ELVIS III | 2021 SP1 | Offline NIPM Install | &#9989; |  |  | - |  | scripted uninstall, local-copy offload |
| 45 | NI Package Manager | - | Silent EXE | &#9989; |  |  | - |  | - |
| 46 | Npcap (packet capture driver) | - | Silent EXE | &#9989; |  |  | - |  | - |
| 47 | OpenJDK 21 (Microsoft) | - | Silent MSI | &#9989; |  |  | - |  | - |
| 48 | PASCO Capstone | - | Silent Install | &#9989; |  |  | - |  | - |
| 49 | Pine AfterMath | 1.6.10523 | File deploy | &#9989; |  |  | - |  | - |
| 50 | PingPlotter | - | Silent EXE | &#9989; |  |  | - |  | - |
| 51 | PuTTY | - | MSI Install | &#9989; |  |  | - |  | fallback installer |
| 52 | Python 3.14 | 3.14.6 | Silent EXE | &#9989; |  |  | - |  | - |
| 53 | Python on system PATH | - | Scripted Config | &#9989; |  | &#9989; | Python |  | - |
| 54 | Quanser QUARC 2025 | 2025 | Scripted Install | &#9989; |  |  | - |  | - |
| 55 | QuantStudio Design & Analysis | - | Silent (unverified) | &#9989; |  |  | - | &#9989; | - |
| 56 | R for Windows | 4.3.2 | Silent EXE | &#9989; |  |  | - |  | - |
| 57 | R for Windows 4.2.3 | 4.2.3 | Silent EXE | &#9989; |  |  | - |  | - |
| 58 | Raven Lite 2 | 2.0.5 | Scripted Install | &#9989; |  |  | - | &#9989; | - |
| 59 | Rockwell CCW | - | Silent DVD (verify 1st run) | &#9989; |  |  | ['DotNet35', 'VSIsoShell2015'] |  | local-copy offload |
| 60 | RStudio | 2026.07.1+147 | Silent EXE | &#9989; |  |  | R | &#9989; | - |
| 61 | RStudio Web | - | Desktop Shortcut | &#9989; |  |  | - |  | - |
| 62 | SCI Laptop Printers | - | Scripted Config | &#9989; |  |  | - | &#9989; | ordered |
| 63 | SnapGene Viewer | - | Silent EXE | &#9989; |  |  | - |  | - |
| 64 | SpectroFlo Instrument Config (bio cart) | - | Scripted Config | &#9989; |  |  | ['SpectroFlo'] |  | ordered |
| 65 | ST-LINK Driver | - | Driver Install | &#9989; |  |  | - |  | - |
| 66 | ST-Link Firmware Upgrader | - | File deploy | &#9989; |  |  | - |  | - |
| 67 | Swabian Time Tagger | 2.22.2 | Silent MSI | &#9989; |  |  | - |  | - |
| 68 | Thorlabs EDU-QOP1 (Quantum Optics Kit) | 1.2.1.3 | Silent EXE | &#9989; |  |  | - |  | - |
| 69 | Thorlabs Kinesis | 1.14.60 (32-bit wow64) | Silent EXE | &#9989; |  |  | - |  | - |
| 70 | Vernier Graphical Analysis | 5.11.0-2168 | Silent EXE | &#9989; |  |  | - |  | - |
| 71 | Vernier Graphical Analysis 6.3 | 6.3.0-4396 | Scripted Install | &#9989; |  |  | - |  | - |
| 72 | Vernier Logger Pro | 3.11 + 3.15/3.16.2 per room | Scripted Install | &#9989; |  |  | - | &#9989; | - |
| 73 | Vernier Spectral Analysis | 5.1.0-2993 | Scripted Install | &#9989; |  |  | - |  | - |
| 74 | VI Package Manager | 22.0.2371 (VIPM 2022) | Silent EXE | &#9989; |  |  | ['LabVIEW'] |  | - |
| 75 | Visual Studio 2022 | 2022 | Image Install | &#9989; |  |  | - |  | - |
| 76 | Visual Studio Code | - | Silent EXE | &#9989; |  |  | - |  | - |
| 77 | VLC | 3.0.23 | winget | &#9989; |  |  | - |  | - |
| 78 | VS Code Extensions (CSE set) | - | Scripted Config | &#9989; |  |  | VSCode |  | ordered |
| 79 | Wireshark | - | Interactive (bundled Npcap wizard) | &#9989; |  |  | - |  | - |
| 80 | Xilinx Vivado | 2022.2 | Image Install | &#9989; |  |  | - |  | post-install config, local-copy offload |
| 81 | XMALab | - | Silent MSI | &#9989; |  |  | - |  | - |

Detection methods available to cards: `path`, `folder`, `registry`, `appx`,
`filematch` (byte-compare a deployed file set), `envpath` (resolve an exe against
the real machine PATH from the registry, rejecting 0-byte alias stubs).
