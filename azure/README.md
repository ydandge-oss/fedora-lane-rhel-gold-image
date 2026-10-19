# Azure automation (RHDP Blank OPEN)

```bash
cp -n env.example env.local   # never commit
./compose-vhd-on-azure-builder.sh
# builder: sudo rhc connect → --continue
./create-image.sh
./launch-vm.sh
./verify-remote.sh
./cleanup.sh
```

Plain CLI/console: [../docs/azure-cli-and-console.md](../docs/azure-cli-and-console.md)
