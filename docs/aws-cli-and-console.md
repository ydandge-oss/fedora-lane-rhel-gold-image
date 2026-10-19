# AWS — launch gold AMI (CLI + Console)

Gold VMs use **SSH 2222** and **httpd 35443** (not port 22).  
Region for our PoC: **us-east-2**.

---

## CLI — one small step at a time

```bash
export AWS_REGION=us-east-2
export AWS_DEFAULT_REGION=us-east-2
```

### 1) Find gold AMI

```bash
aws ec2 describe-images --owners self \
  --filters Name=name,Values=fedora-lane-rhel10-gold Name=state,Values=available \
  --output table
```

Also try name `fl-rhel-gold` if that is what you registered.

```bash
AMI_ID=ami-xxxxxxxx
```

### 2) VPC + subnet

```bash
aws ec2 describe-vpcs --filters Name=isDefault,Values=true --output table
VPC_ID=vpc-xxxxxxxx

aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID --output table
SUBNET_ID=subnet-xxxxxxxx
```

### 3) Security group

```bash
aws ec2 create-security-group \
  --group-name fl-gold-sg \
  --description "SSH 2222 + httpd 35443" \
  --vpc-id $VPC_ID \
  --output table
SG_ID=sg-xxxxxxxx

MYIP=x.x.x.x/32
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 2222 --cidr $MYIP
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 35443 --cidr $MYIP
```

### 4) Launch

```bash
aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type t3.medium \
  --key-name fl-gold-poc \
  --security-group-ids $SG_ID \
  --subnet-id $SUBNET_ID \
  --associate-public-ip-address \
  --output table

INSTANCE_ID=i-xxxxxxxx
aws ec2 wait instance-running --instance-ids $INSTANCE_ID

aws ec2 describe-instances --instance-ids $INSTANCE_ID --output table
PUBLIC_IP=x.x.x.x
```

### 5) Connect (wait ~4–5 min)

```bash
ssh -i ~/.ssh/fl-gold-poc.pem -p 2222 fladmin1@$PUBLIC_IP
curl -s http://$PUBLIC_IP:35443/
```

### Optional User data (so httpd starts on console launches)

```yaml
#cloud-config
runcmd:
  - [rm, -f, /var/lib/fl-gold-firstboot-done]
  - [/bin/bash, /etc/fl-gold/bin/fl-gold-firstboot.sh]
```

---

## Console

1. Region **us-east-2**  
2. EC2 → AMIs → Owned by me → gold AMI → **Launch instance from AMI**  
3. Type `t3.medium` · public IP · SG with **2222** + **35443** from My IP  
4. Advanced → paste User data above  
5. Launch → wait → SSH `fladmin1` port 2222  

---

## Script path (easier)

```bash
cd aws
./launch-gold-ami.sh
./verify-remote.sh
```
