# TrinityCore Cata Classic 4.4.2 — Windows One-Click Compiler + Certificates generator + Client Patcher

Windows PowerShell scripts to build a **TrinityCore `cata_classic`** server from source
(WoW **Cataclysm Classic 4.4.2**, build 60895) and to set up a **locally-trusted Battle.net
login** so a portal-patched client can connect to it. Includes client patcher for clean client!

| File | Purpose |
|---|---|
| `Compile-TrinityCore-CataClassic.ps1` | One-click build: tooling → dependencies → compile → databases → configs. **Stops after compiling** — never starts the servers. |
| `make-bnet-cert.ps1` | Generates the self-signed login certificate and installs it into the Windows Root store. |
| `ed25519_patch.ps1` | Patches clean client to allow local connection. |

---

## Requirements

- **Windows 10/11 x64**
- Run PowerShell **as Administrator** (both scripts need it: winget installs / `certutil`)
- ~60–100 GB free disk for source, dependencies and build
- **Patience**: vcpkg builds Boost (~30–90 min), the C++ build takes ~20–60+ min
- A **4.4.2 (build 60895) client** with a portal-patched executable (use included patcher)
- `openssl` on PATH for the cert script (it also checks the usual install locations:
  `C:\Program Files\OpenSSL-Win64\bin\openssl.exe`, vcpkg tool folder)

---

## 1. `Compile-TrinityCore-CataClassic.ps1`

### What it does

1. **Tooling** — installs Git, CMake, 7-Zip and Visual Studio 2022 Build Tools (C++ workload) via winget if missing.
2. **Dependencies** — bootstraps vcpkg, builds OpenSSL, Boost and libmysql (`x64-windows`).
3. **Source** — clones the `cata_classic` branch of TrinityCore (updates if already present).
4. **Portable MariaDB** — downloads the latest stable Windows server ZIP (plain `mariadb-<ver>-winx64.zip`), extracts it to `mariadb-portable\`, initializes the data dir, starts it on **port 3307** (default), sets the root password and creates the `auth`, `world`, `characters` and `hotfixes` databases plus the `trinity` user.
5. **Build** — CMake configure (VS 2022, x64, `-DSCRIPTS=static`, tools included) then MSBuild **Release** install into `server\`.
6. **TDB** — downloads the newest `TDB442.*` release and copies **both** `TDB_full_world_*.sql` and `TDB_full_hotfixes_*.sql` into the server folder (worldserver auto-imports them on first boot).
7. **Configs** — regenerates `bnetserver.conf` / `worldserver.conf` from the `.dist` templates with working values:

   | Setting | Value | Where |
   |---|---|---|
   | `LoginDatabaseInfo` / `WorldDatabaseInfo` / `CharacterDatabaseInfo` / `HotfixDatabaseInfo` | `127.0.0.1;3307;trinity;trinity;<db>` | both |
   | `Updates.EnableDatabases` | `7` (auth/world/characters) | `bnetserver.conf` |
   | `Updates.EnableDatabases` | `15` (adds hotfixes) | `worldserver.conf` |
   | `DataDir` | `"./Data"` | `worldserver.conf` |
   | `LoginREST.ExternalAddress` / `LoginREST.LocalAddress` | `localhost.actual.<PortalDomain>` | `bnetserver.conf` |

8. **`start-database.bat`** — written into the server folder so the portable DB can be brought back up after a reboot (it is not a Windows service).
9. **Stops.** bnetserver/worldserver are **never launched** — worldserver crashes without extracted data, so starting the servers is deliberately manual.

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `InstallRoot` | script folder | Where source, build, server, DB and tools go |
| `SqlPort` | `3307` | Port for the portable MariaDB |
| `SqlRootPassword` | `RootPass123!` | MariaDB root password |
| `TrinityDbPassword` | `trinity` | Password for the `trinity` DB user |
| `PortalDomain` | `wowemu.dev` | Domain used for `LoginREST.*Address` in bnetserver.conf (must match the patched client) |
| `SkipBuild` | off | Skip compile/configure (assume `server\` is already built) |

### Usage

```powershell
# everything into the folder the script lives in
powershell -ExecutionPolicy Bypass -File .\Compile-TrinityCore-CataClassic.ps1

# custom location
powershell -ExecutionPolicy Bypass -File .\Compile-TrinityCore-CataClassic.ps1 `
    -InstallRoot "D:\WoWServer"
```

### After the build (manual, in this order) - Data Extraction

Copy mapextractor, vmap4extractor, vmap4assembler, mmaps_generator into root of your legitimate client(or Whitemane) and run through cmd in that folder like this:
| Type | Command |
|---|---|
| `mapextractor` | mapextractor.exe -p whitemane-60895 |
| `vmap4extractor` | vmap4extractor.exe -p whitemane-60895 |
| `vmap4assembler` | vmap4assembler.exe Buildings vmaps |
| `mmaps_generator` | Can be run normally with double clicking |

### After data extraction

```bat
start-database.bat        :: from the server folder
bnetserver.exe
worldserver.exe
```

> First worldserver start imports the TDB world + hotfixes SQL — this can take several minutes.


## 2. `make-bnet-cert.ps1` / `make-bnet-cert.bat`

The 4.4.2 client's embedded login page **refuses a raw IP** for the web-login host, so the
login server must present a **DNS name** that the client trusts. These scripts create that
certificate for you:

1. **Generates** a self-signed cert in the current folder:

   ```bat
   openssl req -x509 -newkey rsa:2048 -keyout bnetserver.key.pem -out bnetserver.cert.pem ^
     -days 365 -nodes -subj "/CN=localhost.actual.wowemu.dev" ^
     -addext "subjectAltName=DNS:localhost.actual.wowemu.dev,DNS:localhost"
   ```

2. **Installs** it into the Windows Root store:

   ```bat
   certutil -addstore -f Root bnetserver.cert.pem
   ```

3. **`-Hosts`** (default with the `.bat`): checks the hosts file for
   `127.0.0.1 localhost.actual.wowemu.dev` and, with confirmation, appends it.

### Usage

**Double-click `make-bnet-cert.bat`** — it auto-elevates via UAC and enables the hosts check:

```bat
make-bnet-cert.bat
```

or run the PowerShell script manually **as Administrator**:

```powershell
powershell -ExecutionPolicy Bypass -File .\make-bnet-cert.ps1 -Hosts
# without the hosts handling:
powershell -ExecutionPolicy Bypass -File .\make-bnet-cert.ps1
```

### After the cert is generated

1. Copy `bnetserver.cert.pem` + `bnetserver.key.pem` into the **server folder**, overwriting the old ones.
2. **Restart bnetserver** (it loads the certificate only at startup).
3. Log in.

> **Regenerating** the cert creates a new key pair — re-install it (the script does) and
> re-copy it to the server folder every time, or the client will no longer trust it.

---

## How the login flow works

```
patched client  ──TCP 1119──▶  us.actual.wowemu.dev        (first contact, hosts → 127.0.0.1)
                        │
                        ▼
        https://localhost.actual.wowemu.dev:8081/bnetserver/login/   (embedded browser login)
                        │
                        ▼
        GET /bnetserver/portal/  →  localhost.actual.wowemu.dev:1119 (BGS session address)
```

Required **hosts** entry on the client machine:

```
127.0.0.1  localhost.actual.wowemu.dev
```

(`ipconfig /flushdns` after editing.)

**Battle.net accounts** are created in the bnetserver console:

```
bnetaccount create email@example.com <password>
```

## 3. `ed25519_patch.ps1`

Place both ed25519_patch.ps1 and ed25519_patch.bat into the same folder as your WowClassic.exe

Run .bat, press Y on confirmation and it will produce WowClassic-ed25519.exe used to enter the game!

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| MariaDB downloaded but `bin\mysqld.exe` missing | The script now filters out the `*-debugsymbols.zip` asset — delete `_tools\mariadb.zip` and `mariadb-portable\` and re-run |
| Client: `BLZ51901016` / Front disconnected | `LoginREST.*Address` must be a **hostname** (not `127.0.0.1`), hosts entries present, cert installed in Root store **and** copied to the server folder, bnetserver restarted |
| openssl progress dots appear as PS errors | Cosmetic only (PS 5.1 stderr handling) — the script already guards against it |
| `worldserver` can't connect to DB | Check `*DatabaseInfo` lines point at `127.0.0.1;3307;trinity;trinity;...` |

---

## Layout after a successful build

```
<InstallRoot>/
├── TrinityCore/            # source (cata_classic)
├── vcpkg/                  # dependencies
├── build/                  # CMake/MSBuild artifacts
├── mariadb-portable/       # portable MariaDB (data/ inside)
├── _tools/                 # downloads, logs
└── server/
    ├── bnetserver.exe / worldserver.exe
    ├── bnetserver.conf / worldserver.conf
    ├── bnetserver.cert.pem / bnetserver.key.pem
    ├── TDB_full_world_*.sql / TDB_full_hotfixes_*.sql
    ├── start-database.bat
    └── Data/               # dbc/ maps/ vmaps/ mmaps/   (see extraction section)
```
