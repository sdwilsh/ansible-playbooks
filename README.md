# Provision a new host

1) Create or modify an inventory file with the hostname in it
2) Connect to the machine with a known, existing account:

```
    ansible-playbook -i {{inventory_file}} -l {{hostname}} provision.yml -u {{remote_user}} --ask-pass --ask-become-pass
```

Note: this will remove a user with the name `provision` automatically, so it's best to set that up as the first user.