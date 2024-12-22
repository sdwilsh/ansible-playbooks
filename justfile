# Lists all targets
default:
    just --list

# Validate renovate.json file
renovate-validate:
    renovate-config-validator
