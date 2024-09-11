# Provision a new host

## Prerequisites

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

# Create a new VM with kubevirt

1) Set the context to the namespace you wish to upload the ISO to with:

```
kubectl config set-context --current --namespace=$(NAMESPACE)
```

2) Upload with:

```
virtctl image-upload pvc ubuntu-22.04-live-server-amd64 \
    --access-mode=ReadWriteMany \
    --image-path ubuntu-22.04.4-live-server-amd64.iso \
    --size=3Gi \
    --storage-class=image-upload-storageclass \
    --uploadproxy-url=https://cdi-image-upload.hogs.tswn.us \
    --wait-secs=240
```
