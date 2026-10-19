# Azure — launch gold image (CLI + Console)

Gold VMs use **SSH 2222** and **httpd 35443**.

---

## After VHD → managed image exists

Scripts (recommended):

```bash
cd azure
cp -n env.example env.local
./create-image.sh      # if not done
./launch-vm.sh
./verify-remote.sh
```

---

## CLI — create VM from managed image

```bash
az login
az account set --subscription <SUBSCRIPTION_ID>

RG=fl-gold-rg
IMAGE=fl-rhel-gold          # or your managed image name
LOC=eastus

az image show -g $RG -n $IMAGE -o table

# NSG: allow 2222 + 35443 from your IP
MYIP=$(curl -4 -fsS ifconfig.me)

az vm create \
  -g $RG \
  -n fl-rhel-gold-poc \
  --image $(az image show -g $RG -n $IMAGE --query id -o tsv) \
  --admin-username azureuser \
  --ssh-key-values ~/.ssh/fl-gold-poc.pem.pub \
  --public-ip-sku Standard \
  --size Standard_D2s_v3 \
  -o table
```

Open ports on the NSG attached to the VM NIC:

```bash
# Example — adjust NSG name from: az network nsg list -g $RG -o table
az network nsg rule create -g $RG --nsg-name <NSG> -n AllowSSH2222 \
  --priority 1000 --access Allow --protocol Tcp \
  --destination-port-ranges 2222 --source-address-prefixes $MYIP/32

az network nsg rule create -g $RG --nsg-name <NSG> -n AllowHttpd35443 \
  --priority 1010 --access Allow --protocol Tcp \
  --destination-port-ranges 35443 --source-address-prefixes $MYIP/32
```

```bash
IP=$(az vm list-ip-addresses -g $RG -n fl-rhel-gold-poc --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" -o tsv)
ssh -i ~/.ssh/fl-gold-poc.pem -p 2222 fladmin1@$IP
curl -s http://$IP:35443/
```

---

## Console

1. Portal → **Images** (or Virtual machines → Create → see **My Images**)  
2. Create VM from **fl-rhel-gold** (or your gold managed image)  
3. Networking / NSG: allow **TCP 2222** and **TCP 35443** from your IP  
4. SSH: `fladmin1` port **2222** with your key  
5. Verify with [08-verify-customizations.md](./08-verify-customizations.md)  

---

## Build the VHD (high level)

```bash
cd azure
./compose-vhd-on-azure-builder.sh
# ssh to builder → sudo rhc connect → --continue
./upload-vhd-from-azure-builder.sh <BUILDER_IP>   # if needed
./create-image.sh
```
