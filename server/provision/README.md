# server/provision — one-command Oracle exit server

Builds the ColdSpot exit server on Oracle Cloud's **Always-Free** tier with
Terraform, then hands off to the Mac installer. The only manual step is creating
a free Oracle account (Oracle requires a human: card + SMS verification).

```bash
cd server/provision
./provision.sh
```

What it does:

1. Installs the **OCI CLI** and **Terraform** if missing.
2. One browser login (`oci setup bootstrap`) → writes `~/.oci/config`. No OCIDs
   or keys to paste; the API key is **reused** on future runs (Oracle caps you
   at 3 keys/user).
3. Generates an SSH key (`~/.ssh/id_ed25519`) if you don't have one.
4. `terraform apply` builds: a VCN, public subnet, internet gateway, route table,
   a **firewall** opening **TCP 22** (SSH) and **TCP 443** (the exit), and an
   **Ubuntu 22.04 VM** with your SSH key.
5. Waits for SSH, then runs `../../mac/install.sh`, which pushes
   `server/setup.sh` + `server/exit.py` over SSH and configures this Mac.

Nothing secret is committed — credentials are passed to Terraform as `TF_VAR_*`
env vars read from `~/.oci/config` and `~/.ssh`. State files and `terraform.tfvars`
are gitignored.

**Re-runs are safe.** The exit's TLS cert + credentials are generated once on the
server and reused, so re-provisioning or re-installing never breaks a configured
Mac.

To tear it down: `terraform destroy` in this directory.
