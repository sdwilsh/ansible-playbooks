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
