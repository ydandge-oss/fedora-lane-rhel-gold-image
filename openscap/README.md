# OpenSCAP / CIS (stretch goal)

This gold image applies **CIS** hardening two ways:

1. **At compose time (primary)** — blueprint `[customizations.openscap]` with  
   `profile_id = "xccdf_org.ssgproject.content_profile_cis"`  
   so Image Builder / osbuild remediates during the AMI/VHD build.

2. **At firstboot (report)** — `openscap-scanner` + `scap-security-guide` packages  
   run a CIS **eval** and write:
   - `/var/log/fl-gold/openscap-cis-report.html`
   - `/var/log/fl-gold/openscap-cis-results.xml`

## Verify on a gold VM

```bash
cat /etc/fl-gold/MARKER
ls -la /var/log/fl-gold/
# optional browser copy of the HTML report
sudo cp /var/log/fl-gold/openscap-cis-report.html /tmp/ && sudo chmod a+r /tmp/openscap-cis-report.html
```

Manual re-scan:

```bash
sudo oscap xccdf eval --profile xccdf_org.ssgproject.content_profile_cis \
  --results /tmp/fl-cis-results.xml \
  --report /tmp/fl-cis-report.html \
  /usr/share/xml/scap/ssg/content/ssg-rhel10-ds.xml
```

(Use `ssg-rhel9-ds.xml` if rhel10 datastream is not present on the image.)

Official: Red Hat docs — OpenSCAP compliance scanning and remediation.
