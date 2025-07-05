# Provision a new host

## Prerequisites

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
