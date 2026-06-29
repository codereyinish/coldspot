# ColdSpot — Setup Guide

Three pieces: the **iPhone app** (Part 1), and the **exit server + Mac** (Part 2).
Do Part 1 once in Xcode; Part 2 is a single command.

---

## Part 2 at a glance — exit server + Mac (one command)

```bash
# builds a free Oracle Always-Free VM, installs the exit over SSH, then runs
# mac/install.sh to fetch its cert + credentials and wire up the menu-bar toggle
cd server/provision && ./provision.sh
```

- The only manual prerequisite is a free Oracle Cloud account
  (<https://signup.cloud.oracle.com> — card + SMS, required by Oracle). See
  [server/provision/README.md](../server/provision/README.md) for details.
- **Already have an Ubuntu server?** Skip provisioning and just run
  `bash mac/install.sh`, giving it the server's IP. It SSHes in, installs the
  exit if needed, and saves the config to `~/.coldspot/`.
- Re-runs are safe: the exit's TLS cert + credentials are generated once and
  reused, so they never go stale on an already-configured Mac.

After Part 2: connect the Mac to the iPhone's Personal Hotspot and flip the ❄️
menu-bar toggle **ON**.

---

## Part 1 — the iPhone app (Xcode, one-time)

## Step 1 — Create Xcode Project
1. Open Xcode
2. File → New → Project
3. Choose: iOS → App
4. Fill in:
   - Product Name: ProxyTest
   - Bundle Identifier: com.yourname.proxytest
   - Interface: SwiftUI
   - Language: Swift
5. Save location: coldspot/ios/ProxyTest/

## Step 2 — Replace Generated Files
Xcode creates default files. Replace them with ours:

1. Delete generated ContentView.swift → replace with our ContentView.swift
2. Add TestServer.swift (File → Add Files → select TestServer.swift)
3. Keep ProxyTestApp.swift as is (or replace with ours)

## Step 3 — Add Info.plist Keys
In Xcode → ProxyTest target → Info tab, add:
- NSLocalNetworkUsageDescription → "Needed to accept connections from Mac over hotspot"
- NSBonjourServices → Array → Item 0 → _http._tcp

OR: copy our Info.plist directly into the project folder and link it.

## Step 4 — Sign the App
1. Xcode → ProxyTest target → Signing & Capabilities
2. Team → Add Account → sign in with Apple ID (free account works)
3. Xcode auto-signs

## Step 5 — Install on iPhone
1. Plug iPhone into Mac via USB cable
2. iPhone → Trust This Computer → enter passcode
3. Xcode top bar → select your iPhone
4. Click ▶ Run
5. App installs on iPhone

## Step 6 — Trust the App on iPhone
Settings → General → VPN & Device Management
→ Your Apple ID → Trust → Trust

## Step 7 — Run Tests
See README.md for test instructions.

## File Structure
ProxyTest/
├── ProxyTestApp.swift   (app entry point)
├── ContentView.swift    (UI — two test buttons)
├── TestServer.swift     (NWListener + URLSession tests)
└── Info.plist           (local network + VoIP permissions)
