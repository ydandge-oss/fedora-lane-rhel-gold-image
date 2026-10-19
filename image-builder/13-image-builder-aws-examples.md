# Image Builder → AWS examples (copy-paste)

Replace bucket name, distro id, and paths for your account.

## 1) List AMI types

```bash
sudo image-builder list | grep rhel-10 | grep x86_64 | grep ami
```

## 2) Compose AMI only (disk stays local)

```bash
sudo image-builder build ami \
  --blueprint ./fedora-lane-gold.toml \
  --distro rhel-10.1 \
  --with-buildlog
```

## 3) Compose + upload + register AMI

```bash
sudo image-builder build ami \
  --blueprint ./fedora-lane-gold.toml \
  --distro rhel-10.1 \
  --aws-region us-east-2 \
  --aws-bucket fl-gold-ACCOUNT-us-east-2 \
  --aws-ami-name fedora-lane-rhel10-gold
```

## 4) Upload existing `.raw`

```bash
sudo image-builder upload \
  ./path-to-image.raw \
  --to=aws \
  --aws-region us-east-2 \
  --aws-bucket fl-gold-ACCOUNT-us-east-2 \
  --aws-ami-name fedora-lane-rhel10-gold
```

## 5) Manual S3 → snapshot → AMI → EC2 (fallback)

```bash
# Upload
aws s3 cp ./disk.raw s3://fl-gold-ACCOUNT-us-east-2/gold/disk.raw

# Import snapshot (needs vmimport role) — see AWS VM Import docs
# Then register-image from the snapshot id, then run-instances.

# Prefer Path 3/4 or ../aws/reupload-ami-from-builder.sh
```

## 6) Repo script wrappers

```bash
cd ../aws
./setup-vmimport-role.sh
./compose-on-builder.sh
./launch-gold-ami.sh
./verify-remote.sh
```
