# Server preparation notes

Working notes for the steps that happen **before** the application exists on a
server — hardening the box, installing Docker, and getting SSH access working.

These sit outside [README.md](README.md) on purpose. Nothing in this repo
provisions a server (see the README's *Prerequisites* table for what must
already be true); this file is just the running record of how that provisioning
was done, so it can be repeated on the next box.

Order matters: **1 → 2 → 3**, then [Set up the application](#4-set-up-the-application).

---

## 1. Harden the VPS and install Docker

Reference walkthrough: <https://tonyteaches.tech/install-docker-ubuntu-vps/>

```bash
curl -fsSL https://raw.githubusercontent.com/tonyflo/ttt-vps-scripts/main/setup-docker.sh | bash
```

Installs Docker Engine with the Compose plugin — the two things
`scripts/setup-app.sh` checks for and refuses to install itself.

> ⚠ This is a third-party script piped into a shell. Read it first
> (`curl -fsSL <url> | less`) before running it on a box you care about.

---

## 2. SSH keys

Generate a dedicated key — one per purpose, never a reused personal key.

```bash
ssh-keygen -o -a 100 -t ed25519 -f ~/.ssh/homeserver -C mroshan.dev@gmail.com
```

| Flag | Meaning |
|---|---|
| `-o` | Write in the newer OpenSSH private-key format (implied for `ed25519`, harmless to state) |
| `-a` | KDF rounds for the passphrase — higher is slower to brute-force |
| `-t` | Key type: `dsa \| ecdsa \| ecdsa-sk \| ed25519 \| ed25519-sk \| rsa` |
| `-f` | Output keyfile — writes `~/.ssh/homeserver` and `~/.ssh/homeserver.pub` |
| `-C` | Comment, so the key is identifiable in `authorized_keys` |

Install the **public** half on the server:

```bash
ssh-copy-id -i ~/.ssh/homeserver node1@192.168.1.40   # -i = identity file
```

Then log in with it:

```bash
ssh -i ~/.ssh/homeserver node1@192.168.1.40
```

The CI deploy key is a **separate** key from this one — generated locally and
handed over as a public half only. See *Set up the application* in
[README.md](README.md#set-up-the-application).

---

## 3. Docker permissions

The account that deploys has to reach the Docker socket. The supported way is
group membership:

```bash
sudo groupadd docker            # usually already exists after step 1
sudo usermod -aG docker ${USER}
```

**Log out and back in** afterwards — group membership is only picked up on a new
login session, so `docker info` keeps failing in the shell that ran `usermod`.

```bash
sudo chmod 666 /var/run/docker.sock
```

> ⚠ Last resort only. This makes the Docker socket world-writable, which is
> effectively root on the host for every local account, and it resets on reboot.
> Use it to unblock a session, then fix the group membership properly.

Verify before moving on — this is exactly what `setup-app.sh` probes:

```bash
docker info
```

---

## 4. Set up the application

Once the above holds, the server is ready for the one-time application setup.
Run it **as the account CI will connect as**:

```bash
curl -fsSL https://raw.githubusercontent.com/mroshan74/psc-archiver-deploy/master/scripts/setup-app.sh | bash
```

It checks its prerequisites, clones this repo to `/opt/psc-archiver`, creates
`.env` from the template, and prints the remaining manual steps (also saved to
`/opt/psc-archiver/REMAINING-STEPS.txt`). Safe to re-run.

Full details: [README.md → Set up the application](README.md#set-up-the-application).
