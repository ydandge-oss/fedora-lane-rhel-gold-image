# 15-minute script — aligned to presentation slides

**Deck:** [`Fedora-Lane-Expansion-Pack-Technical-Solution.pptx`](./Fedora-Lane-Expansion-Pack-Technical-Solution.pptx) (14 slides)  
**Audience:** Casey Novak / Alex Lee (RHSH practice or customer)  
**Screen:** Google Slides + terminal with one live gold PoC VM (AWS or Azure)  
**Blueprint (open on screen):** [`fedora-lane-gold.blueprint.toml`](./fedora-lane-gold.blueprint.toml) · explained in [`blueprint-explained.md`](./blueprint-explained.md)

Replace `[Name]` with your name. Speak naturally; timings are targets.

---

## Timing map

| Segment | Slides | Time |
|---|---|---|
| Opening | 1–4 | ~1.5–2 min |
| Live walkthrough | 5–9 | ~7–9 min |
| Value summary | 10–11 | ~2–3 min |
| Closing | 12–14 | ~1–1.5 min |
| **Total** | **1–14** | **~15 min** |

---

## OPENING (slides 1–4) · ~2 minutes

### Slide 1 — Title (~15 sec)

“Hi everyone. I’m **[Name]**, Junior Consultant on the FASTER **Server/Cloud OS** TDP for **Fedora Lane**.

Today I’ll walk our technical solution: a **RHEL gold image** built with **local Image Builder**, proven on **AWS and Azure**.”

---

### Slide 2 — Why we are here (~30 sec)

“**Why we’re here:** Fedora Lane needs a secure, repeatable RHEL baseline for the e-commerce **web** fleet.

We designed, built, and can demo a working Red Hat–based gold image — not a slideware proposal.

**Objective today:** confirm your challenges, walk the live implementation, show value, and leave you with **one clear next step**.”

---

### Slide 3 — Challenges we confirm (~40 sec)

“Let me confirm the challenges we heard:

First — **inconsistent estate**: roughly **1,600** servers across Rocky, Ubuntu, CentOS Stream, Amazon Linux — no single web OS standard.

Second — **risky, untraceable change**: drift and ad-hoc fixes drive long outages.

Third — a **container skills gap**: ops need a clear, repeatable way to run services in containers on RHEL.

And Expansion Pack asks for a **manual / local Image Builder** gold image — **not** hosted console.redhat.com — deployable on **AWS and Azure**.

Does that match your understanding? … Good — let’s continue.”

---

### Slide 4 — Agenda (~20 sec)

“**Agenda:** opening — done; then a **live walkthrough** of architecture, build steps, and a gold VM; then **value**; then **closing** with one ask.

Let’s walk the solution.”

---

## LIVE WALKTHROUGH (slides 5–9) · ~8 minutes

### Slide 5 — What we implemented (~45 sec)

“Here’s what we built:

- A **versioned blueprint** in Git — the source of truth  
- **Local RHEL Image Builder** composing a gold **AMI** for AWS and **VHD** for Azure  
- VMs launched **from that gold image**, not stock Marketplace OS  
- Expansion Pack controls baked in  
- **httpd as a container** on port **35443**  
- A working deployment we can prove live — SSH **2222**, curl **35443**

Before architecture — what is that blueprint?”

---

### What is the blueprint? (say this on slide 5 or 6 · ~45–60 sec)

*(Open `docs/fedora-lane-gold.blueprint.toml` or `image-builder/fedora-lane-gold.blueprint.toml` on screen.)*

“The **blueprint** is a **TOML recipe file**. It is **not** a running server we hand-configure.

It tells Image Builder: which RHEL 10 version, which packages, how to partition the disk, who the admins are, which ports the firewall opens, and how SSH is locked down.

In our file you can see:

- `distro = rhel-10.x` — exact Image Builder distro id  
- Separate mounts for `/var/log`, `/home`, `/tmp`, `/var/tmp` — each under **5 GiB**  
- Group **fladmins**, users **fladmin1** / **fladmin2**, with SSH keys  
- Firewall ports **2222** and **35443**  
- SSH drop-in: port 2222, no root, no password login  
- A **firstboot** script that finishes SELinux, `/tmp` noexec, and starts the **httpd container**

So when we say ‘source of truth in Git,’ we mean **this file**. Change the blueprint → compose a **new** gold image → launch new VMs. We do not snowflake servers.”

---

### Slide 6 — Solution architecture (~1.5 min)

Point at the flow left to right:

“This is the factory:

1. **TOML blueprint** — the recipe we just opened — source of truth in Git  
2. **Local Image Builder** — on a subscribed RHEL 10 host — reads that TOML  
3. **Gold disk `.raw`** — hardened RHEL disk file produced by the compose  
4. **AWS AMI** — and the same recipe gives an **Azure VHD**  
5. **Web nodes** — identical launches from that catalog image  

We do **not** snowflake each server.

On **every** VM from the gold image you get:

- SSH on **2222** — `fladmin1` / `fladmin2`, key-only  
- **httpd in Podman** on **35443**  
- Firewall only those ports  
- **SELinux enforcing**  
- Separate mounts and **`/tmp` noexec**  

That’s the Expansion Pack baseline, baked in.”

---

### Slide 7 — Build steps · what we run (~2–2.5 min)

“Here’s what we actually run — you don’t need to watch a full hour-long compose live.

**1 — Blueprint in Git** — `fedora-lane-gold.blueprint.toml` (then `generate-blueprint.sh` → compose-ready `.toml`). That is the recipe: partitions under 5 GiB for `/var/log`, `/home`, `/tmp`, `/var/tmp`, fladmins, firewall 2222/35443.”

**2 — Builder + RHSM** — Image Builder needs `sudo rhc connect` on the builder.

**3 — Compose** — `image-builder build ami` → produces a **`.raw`** on the builder.

**4 — Upload + register** — S3 plus the **`vmimport`** role → AMI named **`fl-rhel-gold`**.

**5 — Launch** — EC2 from that AMI; security group opens **2222** and **35443**.

**6 — Prove** — SSH and curl; we also have `verify-remote.sh`.

Same recipe on Azure: compose **vhd** → managed image → launch VM.

*(Show briefly — pick AWS or Azure; don’t run full compose:)*

```bash
# AWS path (narrate)
cd solution/cloud/aws
# ./setup-vmimport-role.sh
# ./compose-on-builder.sh          # → .raw → AMI
# ./launch-gold-ami.sh

# or Azure
cd solution/cloud/azure
# ./compose-vhd-on-azure-builder.sh
# ./create-image.sh && ./launch-vm.sh
```

Docs: `docs/how-to-build-and-run.md` and the AWS gold AMI runbook.”

---

### Slide 8 — Critical decisions (~1 min)

“A few decisions worth calling out:

- **Local Image Builder**, not hosted console — matches Expansion Pack.  
- **One blueprint, two clouds** — same controls on AWS and Azure.  
- **Replace in waves** from a frozen gold image — we don’t compose 1,600 times, and we don’t swap root on live prod as the primary model.  
- **Firstboot / User data** starts httpd — the image has the tooling; launch finishes the service.  
- **App updates** can land on the httpd volume without a new AMI; **OS/hardening** changes mean a **new** gold image.”

---

### Slide 9 — What we prove on the live VM (~2.5–3 min) ⭐ DEMO

“Now the live proof — this is a VM **launched from the gold image**.”

```bash
ssh -i ~/.ssh/fl-gold-poc.pem -p 2222 fladmin1@<POC_IP>
```

Run slowly so cameras catch output:

```bash
getenforce
findmnt /var/log
findmnt /home
findmnt /tmp
findmnt /var/tmp
findmnt -n -o OPTIONS /tmp | grep noexec
ss -tln | grep -E '2222|35443'
curl -s http://127.0.0.1:35443/ | head
exit
```

From laptop:

```bash
curl -s http://<POC_IP>:35443/
# optional:
# ./verify-remote.sh
```

“You see **SELinux Enforcing**, separate mounts, **noexec** on `/tmp`, listeners on **2222** and **35443**, and the Fedora Lane web page from the **httpd container**.

Same checklist passed on **AWS and Azure**, including after **reboot**.

That’s the Expansion Pack satisfied on a real cloud VM.”

---

## VALUE SUMMARY (slides 10–11) · ~2.5 minutes

### Slide 10 — How this addresses the challenges (~1.5 min)

“Back to your challenges:

| Challenge | What we delivered |
|---|---|
| Inconsistency | One Git blueprint → identical AMI/VHD baselines |
| Risky change | Hardened SSH/sudo baked in; rebuild from Git anytime |
| Container skills gap | httpd runs as a **container** on every gold web VM |
| Dual cloud | Proven path on **AWS and Azure** |

So the technical solution maps directly to what Fedora Lane asked for.”

---

### Slide 11 — Future possibilities (~1 min)

“This also leaves the door open:

- Scale with Launch Templates / ASG or Azure Scale Sets  
- Day-2: change blueprint → new gold version → replace waves  
- Stretch: **OpenSCAP CIS** on the same factory — we haven’t done that yet; it’s next  
- Deploy apps onto the httpd volume without rebuilding the AMI  
- Fit into your existing CI/CD and change control  

Kickstart and Image Mode stay in the repo as alternate factories if you prefer them later.”

---

## CLOSING (slides 12–14) · ~1.5 minutes

### Slide 12 — Core message (~30 sec)

“**Core message:** Fedora Lane can standardize the e-commerce web OS with a **repeatable RHEL gold image** — Red Hat Image Builder, Git as source of truth, Expansion Pack controls included, proven on AWS and Azure.”

---

### Slide 13 — One concrete next step (~40 sec)

“**One next step:** approve a **non-prod pilot** — launch web nodes from the gold AMI or Azure image.

Keep Git as change control; use Launch Template / scale set for new capacity.

After the pilot: wave-replace selected prod pools.

That’s the ask.”

---

### Slide 14 — Thank you (~20 sec)

“Everything is in the Git repo — README, how-to-build-and-run, AWS and Azure runbooks, verify checklist.

Thank you — I’m happy to take questions.”

---

## Teleprompter one-pager (if you run short / long)

| If short on time | Skip / shorten |
|---|---|
| Under 13 min | Shorten slide 7 command paste; keep live demo (slide 9) |
| Over 16 min | Don’t re-explain architecture on slide 7; cut OpenSCAP sentence |

| Must not skip | Why |
|---|---|
| Challenges (slide 3) | Opening requirement |
| Architecture or build steps (6 or 7) | Shows what you built |
| Live VM demo (slide 9) | Walkthrough requirement |
| Challenge → value (slide 10) | Value requirement |
| One next step (slide 13) | Closing requirement |

---

## Recording checklist

- [ ] Slide 1–4: team, why, challenges, agenda  
- [ ] Slide 6 or 7: architecture / build path  
- [ ] Slide 8: at least one critical decision  
- [ ] Slide 9: live SSH + mounts + curl 35443  
- [ ] Slide 10–11: value + future  
- [ ] Slide 12–13: core message + non-prod pilot ask  
- [ ] No secrets / keys on screen  

---

## After recording

1. RHSH → get recording link  
2. Google form: topic **Server/Cloud OS TDP** + links in [`part1-submission-guide.md`](./part1-submission-guide.md)  
