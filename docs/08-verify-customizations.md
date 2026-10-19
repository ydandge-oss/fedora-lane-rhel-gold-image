# Verify gold-image customizations

SSH in (security group / NSG must allow your IP on **2222**):

```bash
ssh -i ~/.ssh/fl-gold-poc.pem -p 2222 fladmin1@<PUBLIC_IP>
```

Wait a few minutes after first boot for the httpd container, then run these on the instance.

---

## Base OS

```bash
cat /etc/redhat-release
hostname
```

---

## SELinux and filesystems

```bash
getenforce
# expect: Enforcing

findmnt /var/log /home /tmp /var/tmp
# each path should be its own mount

findmnt -no OPTIONS /tmp
# must include: noexec
```

---

## SSH hardening

```bash
ss -tlnp | grep 2222
# sshd on 2222

# From your laptop (should fail):
# ssh -p 2222 root@<PUBLIC_IP>
```

---

## Admins

```bash
getent group fladmins
id fladmin1
id fladmin2
```

---

## Firewall

```bash
sudo firewall-cmd --list-ports
# expect: 2222/tcp and 35443/tcp
```

---

## httpd container (port 35443)

```bash
ss -tlnp | grep 35443
curl -s http://127.0.0.1:35443/ | head
cat /etc/fl-gold/MARKER
```

From your laptop:

```bash
curl -s http://<PUBLIC_IP>:35443/
```

---

## Automated check

From the repo (Mac), after `aws/launch-gold-ami.sh` or `azure/launch-vm.sh`:

```bash
cd aws    # or azure
./verify-remote.sh
```

Or on the VM:

```bash
# copy verify/verify.sh to the host, then:
sudo bash verify.sh
```

---

## Reboot survival

```bash
# Prefer cloud reboot (no sudo password needed):
# aws ec2 reboot-instances --instance-ids i-xxxx
# az vm restart -g <rg> -n <vm>
```

Wait 2–3 minutes, re-run the checks above.
