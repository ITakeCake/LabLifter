# Security policy

## Reporting a vulnerability

Report security issues privately through GitHub, using the Report a vulnerability button on the Security tab of this repository. That opens a private advisory visible only to the maintainer.

Please do not open a public issue for a security problem.

Include what you found, which file or component it affects, and how to reproduce it. A rough proof of concept helps more than a description. Expect a first reply within about a week. This is a single maintainer project, so response times are best effort.

## What this repository is

LabLifter is a PowerShell 5.1 and WPF application that runs from a USB stick to install software on lab machines. It runs with administrator rights, by necessity, because the installers it drives require them. That makes the following areas the ones worth your attention.

## In scope

* Command injection through `gui/config/apps.json`. The catalog names commands that run as administrator, so any path where untrusted input reaches an install argument is a serious finding.
* Path traversal or unsafe path handling in payload deployment, in the stick sync scripts, or in shortcut creation.
* Privilege escalation beyond what an install already requires, including cases where a non administrator can influence what the tool executes.
* Weaknesses in the telemetry client that would let a network position change what runs on a machine. The design intends telemetry to be strictly one way, up. A break in that property is the highest value finding in this repository.
* Handling of BitLocker recovery keys, licence material, or any other secret the tool reads or files.
* Detection logic that can be tricked into reporting an application as correctly installed when it is not, since technicians act on that state.

## Out of scope

* Vulnerabilities in the vendor installers LabLifter drives. Report those to the vendor.
* The requirement for administrator rights itself. Installing this software needs them.
* Findings that require an attacker to already have administrator access on the machine.
* Social engineering, physical access to an unlocked machine, or theft of a deployment stick. Physical control of a stick is assumed to mean control of what it deploys.
* Anything about the private production configuration. This repository carries a sanitised catalog with no licence codes, no server names, and no recovery keys.

## Design properties worth verifying

If you want to attack the interesting claim, attack this one. Telemetry is one way by construction, not by policy. Sticks push observations to a Cloudflare Worker and the dashboard renders them. The only downstream verbs in the whole protocol are five status words: verified, override, missing, broken, clear. Those are pulled by the master, never pushed to a lab machine, and are only ever displayed to a human. A machine never receives configuration, cards, code, or commands from the network.

The companion telemetry service lives in the LabBoard repository.
