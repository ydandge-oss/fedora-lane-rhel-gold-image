# AWS automation (RHDP Blank OPEN)

```bash
cp -n env.example env.local   # never commit
./setup-vmimport-role.sh
./compose-on-builder.sh
# builder: sudo rhc connect
# ./continue-compose-on-builder.sh <IP>
./launch-gold-ami.sh
./verify-remote.sh
./terminate-ec2.sh
```

Plain CLI/console: [../docs/aws-cli-and-console.md](../docs/aws-cli-and-console.md)
