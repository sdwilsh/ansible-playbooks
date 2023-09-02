# Provision a new host

## Prerequisites

### FreeBSD

#### Install Core Dependencies

Run this on the remote machine:
```
pkg install bash python37 sudo
```

#### Setup `sshd`

Run this on the remote machine:
```
echo 'sshd_enable="YES"' >> /etc/rc.conf.d/sshd
service sshd start
```

#### Create `provision` User

This command creates the user `provision` that expires one hour after creation with the password `provision`

Run this on the remote machine:
```
echo 'provision:::::+1h::/nonexistent:/bin/sh:provision' | adduser -G wheel -f - 
```

#### Enable `wheel` Group to Use Password-based `sudo`

Run this on the remote machine:
```
sed -i '' 's/#\(.*%wheel.*ALL=(ALL).*ALL$\)/%wheel ALL=(ALL) ALL/' /usr/local/etc/sudoers
```

#### Set the Appropriate `host_vars`

In this repository, setup a host_vars for the host with these contents:
```
---
ansible_python_interpreter: "/usr/local/bin/python3.7"
ansible_remote_tmp: "/tmp/ansible"

common__etc_dir: "/usr/local/etc"
```

### VyOS

#### Create `ansible` User

Run this on the remote machine:
```
configure
set system login user ansible authentication public-keys sdwilsh-dev key AAAAC3NzaC1lZDI1NTE5AAAAIMiRn+dJyIkJ22qrkuMlNC33xxS7VUwkYRY/55Wf4ryq
set system login user ansible authentication public-keys sdwilsh-dev type ssh-ed25519
commit
```

If you are using the OVA Template for ESXI, you can just specify the user data with the contents of
[this file](https://github.com/sdwilsh/ansible-playbooks/blob/main/cloud-init-vyos-esxi).  This was generated
with [this repository](https://github.com/zdc/vyos-cloud-init-userdata/) and the above commands.

#### Set IP Address

Run this on the remote machine (chaning the interface and IP address as appropriate):
```
configure
set interfaces ethernet eth1 vif 10 address 10.10.0.48/24
commit
```

#### Enable SSH

Run this on the remote machine:
```
configure
set service ssh port 22
commit
```

## Do the Provision

1) Create or modify an inventory file with the hostname in it
2) Connect to the machine with the provision account (adds this to known hosts):

```
ssh provision@{{ hostname }} echo 'success!'
```

```
ansible-playbook \
    -l {{ hostname }} \
    plays/provision.yml \
    -u provision \
    --ask-pass \
    --ask-become-pass \
    --ssh-common-args="-o PasswordAuthentication=yes"
```

Note: The user `provision` will be removed automatically when the `common` role is run not as that user.
