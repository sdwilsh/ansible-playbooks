# Provision a new host

## Prerequisites

### FreeBSD

#### Install Core Dependencies

Run this on the remote machine:
```
pkg install bash python39 sudo
```

#### Setup `sshd`

Run this on the remote machine:
```
echo 'sshd_enable="YES"' >> /etc/rc.conf
service sshd start
```

#### Create `provision` User

This command creates the user `provision` that expires one hour after creation with the password `provision`

Run this on the remote machine:
```
echo 'provision:::::+1h::/nonexistent:/bin/sh:provision' | adduser -G wheel -f - 
```

####

In this repository, setup a host_vars for the host with these contents:
```
---
ansible_python_interpreter: "/usr/local/bin/python3.9"
ansible_remote_tmp: "/tmp/ansible"

common__etc_dir: "/usr/local/etc"
```

## Do the Provision

1) Create or modify an inventory file with the hostname in it
2) Connect to the machine with the provision account (adds this to known hosts):

```
ssh provision@{{ hostname }} echo 'success!'
```

```
    ansible-playbook -i {{ inventory_file }} -l {{} hostname }} provision.yml -u provision --ask-pass --ask-become-pass
```

Note: The user `provision` will be removed automatically when the `common` role is run not as that user.
