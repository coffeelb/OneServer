# OneServer

[![Build](https://github.com/qichiyuhub/OneServer/actions/workflows/lint.yml/badge.svg)](https://github.com/qichiyuhub/OneServer/actions/workflows/lint.yml)
[![Latest release](https://img.shields.io/github/v/release/qichiyuhub/OneServer?display_name=tag&sort=semver)](https://github.com/qichiyuhub/OneServer/releases/latest)
[![License](https://img.shields.io/github/license/qichiyuhub/OneServer)](LICENSE)
[![Shell](https://img.shields.io/badge/Shell-Bash%204.3%2B-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)

[简体中文](README.md) | English

## Overview

OneServer is a lightweight server administration toolkit for standalone Debian and Ubuntu hosts. It installs and operates a practical web stack, databases, containers, and baseline security controls from an interactive terminal UI or a scriptable CLI.

- **Security first:** Administrative actions stay in the terminal; the web dashboard is read-only. Secrets are kept in a root-only store and are excluded from command arguments and logs.
- **Almost no control-plane overhead:** There is no resident controller or control-plane database. With the web dashboard disabled, OneServer keeps no resident process or daemon of its own.
- **Host-native operations:** The core is plain Bash with no third-party runtime. Services remain under systemd, APT, and standard configuration files.
- **Predictable changes:** Dry runs inspect live state, repeated runs are safe, mutations are globally serialized, and files are replaced atomically. Reversible changes are rolled back on failure.
- **Clean removal:** OneServer records the resources it creates, removes components from that inventory, and leaves application data intact by default.
- **Built for people and automation:** Use the terminal menu for routine work, or the CLI and JSON output for scripts, CI, and AI-assisted operations.
- **Useful visibility without a remote control surface:** The optional read-only dashboard brings services, ports, firewall rules, logs, and component health into one browser view.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/qichiyuhub/OneServer/main/install.sh | bash
```

`os` is the shortcut for the interactive menu. To discover commands without entering the menu:

```bash
oneserver --help
oneserver <command> --help
```

## Requirements

- Debian or Ubuntu with systemd
- Root privileges
- Working APT repositories and outbound network access
- Podman from the distribution repository: Debian 13+, or Ubuntu 24.04+
- On older releases, use Docker or provide an existing Podman 4.4+ installation

The Podman version restriction does not apply to the rest of OneServer.

## What it manages

| Area | Included capabilities |
| --- | --- |
| Web stack | Caddy, PHP-FPM, Node.js, and WordPress |
| Data services | MariaDB, Valkey, database provisioning, and account management |
| Containers | Docker, Podman, Compose projects, images, containers, and volumes |
| Host security | UFW, SSH configuration, security hardening, and system updates |
| Operations | Health checks, diagnostics, secret storage, backup and restore, and the read-only dashboard |

## Updates and removal

Updates are available from the terminal menu (`os`) or directly from the CLI. The web dashboard cannot change system state.

```bash
oneserver update check
oneserver update run

oneserver uninstall --id=<component-id>
oneserver uninstall --all
```

Components must be removed one at a time. `--all` removes the OneServer toolkit itself; it does not remove installed components. Application data and backup archives are never deleted automatically.

## Dependencies

- Base system: Bash 4.3+, systemd, APT, dpkg, and util-linux
- Installed automatically when missing: `curl`, `tar`, `coreutils`, and `ca-certificates`
- Optional: `rclone`, required only for remote backups

## Operational notes

- Use `--dry-run` before making changes.
- `--yes` never bypasses destructive-operation confirmation.
- Do not edit the OneServer state or secret files by hand.
- Keep a second SSH session or provider console open when changing SSH or firewall settings.
- Verify the archive and target before starting a restore.
- The web dashboard listens on all interfaces and uses Basic Auth. Restrict its source addresses with a firewall and add HTTPS where appropriate.
- Run `oneserver doctor` when state or environment checks fail. Recovery procedures are documented in the [operations runbook](docs/OPERATIONS.md) (Simplified Chinese).
- Human-readable prompts and terminal output are currently in Simplified Chinese.

## License

OneServer is licensed under the [MIT License](LICENSE). Third-party software and incorporated material remain subject to their respective licenses; see [Third-party notices](docs/THIRD_PARTY.md).
