# AWS access, S3, and AMI registration

## Credentials

Use RHDP **AWS Blank OPEN** keys in `aws/env.local` (never commit):

```bash
cd ../aws
cp -n env.example env.local
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION=us-east-2
aws sts get-caller-identity
```

## vmimport role

Required so AWS can import your disk from S3 into an AMI:

```bash
cd ../aws
./setup-vmimport-role.sh
```

## Path A — Image Builder uploads for you

```bash
sudo image-builder build ami \
  --blueprint ./fedora-lane-gold.toml \
  --distro rhel-10.1 \
  --aws-region us-east-2 \
  --aws-bucket fl-gold-<ACCOUNT>-us-east-2 \
  --aws-ami-name fedora-lane-rhel10-gold
```

## Path B — `.raw` already on builder

```bash
cd ../aws
./reupload-ami-from-builder.sh <BUILDER_IP>
```

Manual equivalent:

```bash
sudo image-builder upload ./disk.raw \
  --to=aws \
  --aws-region us-east-2 \
  --aws-bucket YOUR_BUCKET \
  --aws-ami-name fedora-lane-rhel10-gold
```

## What AWS creates

```text
.raw on builder → S3 object → (vmimport) EBS snapshot → AMI
```

You do **not** manually snapshot a running PoC VM for the gold standard.

## Confirm

```bash
aws ec2 describe-images --owners self \
  --filters Name=name,Values=fedora-lane-rhel10-gold \
  --output table
```
