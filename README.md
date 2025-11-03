# 🧠 Proxmox Helper Script — Obico Server (Local Install)

[![Proxmox](https://img.shields.io/badge/Proxmox-VE%208.x-orange?logo=proxmox)](https://www.proxmox.com)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20LTS-blue?logo=ubuntu)](https://ubuntu.com)
[![Docker](https://img.shields.io/badge/Docker-Automated%20Install-2496ED?logo=docker&logoColor=white)](https://www.docker.com)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

## 🚀 Ein-Klick-Installation

Installiere den **Obico Server** (The Spaghetti Detective) automatisch  
in einem LXC Container auf deinem **Proxmox VE Host** –  
komplett mit Docker & docker-compose.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/proxmox-obico-helper/main/obico-proxmox-helper.sh)
---
🧩 Was dieses Script macht

✅ Erstellt automatisch einen neuen Ubuntu 22.04 LXC Container
✅ Installiert Docker & docker-compose
✅ Klont das Obico Server Repository
✅ Startet alle Dienste mit docker compose up -d
✅ Zeigt dir am Ende IP & Login-Infos an

🧠 Über Obico

Obico
 (früher The Spaghetti Detective) ist eine Open-Source KI-Plattform,
um deine 3D-Drucker in Echtzeit zu überwachen.
Dieses Script richtet den Obico-Server lokal in deinem Netzwerk ein
(ohne SSL oder Domain).

⚙️ Systemanforderungen
Komponente	Empfehlung
Proxmox VE	7.x oder 8.x
Template	Ubuntu 22.04 LTS
RAM	≥ 2 GB
Storage	≥ 15 GB
CPU	≥ 2 Cores
