#!/bin/bash
#
# SSH Diagnostic Script for Remote Server
# Run this ON THE REMOTE SERVER (65.21.202.252)
#

echo "=== SSH Diagnostic Report ==="
echo "Date: $(date)"
echo "Server: $(hostname)"
echo ""

echo "1. Checking .ssh directory permissions:"
ls -la ~/.ssh/ 2>/dev/null || echo "  .ssh directory not found"
echo ""

echo "2. Checking authorized_keys:"
if [ -f ~/.ssh/authorized_keys ]; then
    ls -la ~/.ssh/authorized_keys
    echo "  Lines in file: $(wc -l < ~/.ssh/authorized_keys)"
    echo "  File size: $(stat -c%s ~/.ssh/authorized_keys) bytes"
else
    echo "  authorized_keys not found!"
fi
echo ""

echo "3. Checking for your key:"
if grep -q "AAAAII1zvD/lJmRT536AL1iCDLVeSzQlBMIBReP5XQqTf1kx" ~/.ssh/authorized_keys 2>/dev/null; then
    echo "  ✅ Your key found in authorized_keys"
    grep "AAAAII1zvD/lJmRT536AL1iCDLVeSzQlBMIBReP5XQqTf1kx" ~/.ssh/authorized_keys
else
    echo "  ❌ Your key NOT found!"
fi
echo ""

echo "4. Checking sshd configuration:"
sudo grep -E "^(PubkeyAuthentication|AuthorizedKeysFile|PermitRootLogin)" /etc/ssh/sshd_config 2>/dev/null || echo "  Cannot read sshd_config (need sudo)"
echo ""

echo "5. Last SSH authentication attempts:"
sudo tail -20 /var/log/auth.log 2>/dev/null | grep -E "sshd|Accepted|Failed|publickey" || \
sudo journalctl -u ssh -n 20 --no-pager 2>/dev/null | grep -E "sshd|Accepted|Failed|publickey" || \
echo "  Cannot read logs (need sudo)"
echo ""

echo "6. SELinux status:"
if command -v sestatus &> /dev/null; then
    sestatus | grep "SELinux status"
else
    echo "  SELinux not installed"
fi
echo ""

echo "=== Recommended fixes ==="
echo ""
echo "If permissions are wrong, run:"
echo "  chmod 700 ~/.ssh"
echo "  chmod 600 ~/.ssh/authorized_keys"
echo "  chown -R root:root ~/.ssh"
echo ""
echo "If PubkeyAuthentication is off, run:"
echo "  sudo sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config"
echo "  sudo systemctl reload sshd"
echo ""
