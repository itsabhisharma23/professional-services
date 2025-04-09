#!/bin/bash

# Install figlet and continue on error
sudo apt install figlet || true

# Check if the installation was successful
if command -v figlet; then
    figlet "AlloyDB Migration Utility"
else
    echo "$(tput setaf 2)AlloyDB Migration Utility$(tput setaf 7)"
fi
cat <<'END_DOC'

+-----------------------------------------------------------------+
| Automated GCP migration tool for PostgreSQL to AlloyDB / CloudSQL
+-----------------------------------------------------------------+
| Tool created by: Abhi Sharma & Dipinti Manandhar               |
+-----------------------------------------------------------------+

This tool can automate end-to-end PostgreSQL migration to CloudSQL
or AlloyDB using Database Migration Service.
END_DOC
