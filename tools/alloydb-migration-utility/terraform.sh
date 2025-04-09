#!/bin/bash

# Clone Terraform module repository for AlloyDB
git clone https://github.com/GoogleCloudPlatform/terraform-google-alloy-db.git

cd terraform-google-alloy-db

# Path to the variables.tf file
file="variables.tf"

# Check if the file exists
if [ ! -f "$file" ]; then
  echo "ERROR: File $file not found."
  exit 1
fi

# Ask the user if they want to enable Private Service Connect
read -p "Do you want to enable Private Service Connect (PSC)? (y/n): " enable_psc

if [ "$enable_psc" == "y" ]; then
  # Enable PSC in variables.tf
  sed -i '' 's/default\s\s\s=\sfalse/default\s\s\s=\strue/g' "$file"
  echo "Default value for psc_enabled has been changed to true in $file"
else
  # Ask the user if they want to provide a network ID
  read -p "Do you want to provide a network ID? (y/n): " provide_network_id

  if [ "$provide_network_id" == "y" ]; then
    read -p "Enter the network ID: " network_id

    # Set the value of network_self_link in the Terraform file
    sed -i '' "s/network_self_link\s*=\s*null/network_self_link = \"$network_id\"/g" "$file"
    echo "Network self link has been set to $network_id"
  fi
fi

# Initialize Terraform
terraform init

# Create a Terraform execution plan
terraform plan

# Apply the Terraform configuration to create the AlloyDB cluster
terraform apply -var 'primary_instance={instance_id="my-primary-instance"}'
