#!/bin/bash

CONFIG_FILE="migration.config" 


GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
RED=$(tput setaf 1)
BOLD=$(tput bold)
NC=$(tput sgr0)

if [[ -f "$CONFIG_FILE" ]]; then
  echo "Loading your configuration from $CONFIG_FILE"
  source "$CONFIG_FILE"
else
  echo "Warning: Configuration file '$CONFIG_FILE' not found. "
fi

echo ""
echo ""
echo "${GREEN}Provisioning required resources...${NC}"
echo ""
echo "---------------------------------------------------------"
echo "${BOLD}Creating Bigquery Result Dataset and Table${NC}"
echo ""
echo "Creating BigQuery results table in project '$PROJECT_ID' and dataset '$BQ_DVT_DATASET'..."
# Create the BigQuery dataset if it doesn't exist
bq mk --location="$REGION" --dataset "$PROJECT_ID":"$BQ_DVT_DATASET" 2> /dev/null || echo "Dataset '$PROJECT_ID:$BQ_DVT_DATASET' already exists."
# Read the SQL content from the file
SQL_CONTENT=$(cat sqls/results_schema.sql)
# Replace the placeholders with the provided parameters
MODIFIED_SQL=$(echo "$SQL_CONTENT" | sed "s/__PROJECT_ID__/${PROJECT_ID}/g" | sed "s/__BQ_DVT_DATASET__/${BQ_DVT_DATASET}/g")
# Execute the modified SQL query
bq query --use_legacy_sql=false --nouse_cache --project_id="$PROJECT_ID" "$MODIFIED_SQL"
echo "BigQuery results table created successfully (or already existed) in '$PROJECT_ID:$BQ_DVT_DATASET'."
echo "---------------------------------------------------------"
echo ""
echo "---------------------------------------------------------"
echo "${BOLD}Do you want to create a Virtual Machine for Data Validations?${NC}"
echo ""
echo "Note: If you already have a VM with required permissions, you don't need to create one."
read -p "Enter your choice (y/n): " is_vm_required
is_vm_required="${is_vm_required,,}"
if [[ "$is_vm_required" == "y" ]]; then
    echo "${BOLD}You chose 'yes'. Moving ahed with VM creation.${NC}"
    #creating service account for least previleage principle
    echo ""
    echo "${BOLD}Creating Service Account to run DVT...${NC}"
    gcloud iam service-accounts create $SERVICE_ACCOUNT --display-name="Service Account for DVT"
    echo ""
    echo "${BOLD}Granting BQ Editor role to Service Account...${NC}"
    #granting BQ editor role to this service account
    gcloud projects add-iam-policy-binding $PROJECT_ID \
      --member="serviceAccount:$SERVICE_ACCOUNT@$PROJECT_ID.iam.gserviceaccount.com" \
      --role="roles/bigquery.dataEditor" --condition=None
    echo ""
    echo "${BOLD}Creating VM...${NC}"
    if gcloud compute instances describe "$INSTANCE_NAME" --project="$PROJECT_ID" --zone="$ZONE" >/dev/null 2>&1; then
      echo "${BOLD}${YELLOW}VM ${INSTANCE_NAME} already exists. Skipping creation.${NC}"
    else
      gcloud compute instances create $INSTANCE_NAME --project=$PROJECT_ID --zone=$ZONE --machine-type=$MACHINE_TYPE --network=$NETWORK_NAME --subnet=$SUBNET_NAME --service-account=$SERVICE_ACCOUNT@$PROJECT_ID.iam.gserviceaccount.com --boot-disk-size=$BOOT_DISK --boot-disk-type=$DISK_TYPE --image=$IMAGE --scopes=cloud-platform,bigquery --no-address --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring
      if [ $? -ne 0 ]; then
        echo "${BOLD}${RED}Error creating VM. Exiting...${NC}"
        exit 1
      fi
      echo "VM is being created...please wait"
    fi

    # --- Check and Wait Loop ---
    while true; do
        STATUS=$(gcloud compute instances describe "$INSTANCE_NAME" \
            --project="$PROJECT_ID" --zone="$ZONE" --format="value(status)")

        if [[ "$STATUS" == "RUNNING" ]]; then
            echo "VM instance '$INSTANCE_NAME' is RUNNING!"
            break  # Exit the loop when the VM is running
        else
            echo "VM instance '$INSTANCE_NAME' is still in $STATUS state. Waiting..."
            sleep 5  # Wait for 5 seconds before checking again
        fi
    done
    echo "---------------------------------------------------------"
    echo "${GREEN}VM is ready to perform further actions...${NC}"
    echo ""
    echo "${BOLD}Do you want the tool to login to VM and run validations?${NC}"
    echo "Note: This step will register SSH keys to VM."
    read -p "Choose y or n (y/n): " is_SSH_key
    if [[ "$is_SSH_key" =~ ^[Yy]$ ]]; then
        echo ""
        echo "${YELLOW}${BOLD}Setting up SSH keys.${NC}"
        # --- Fetch Username from gcloud (without domain) ---
        # Use gcloud config to get account or default username if none
        FULL_USERNAME=$(gcloud config get-value account 2> /dev/null || echo "defaultuser")
        # Strip away the domain part using parameter expansion
        USERNAME=${FULL_USERNAME%@*}
        echo "Using username: $USERNAME"

        # --- Key Generation ---
        # You can comment out this section and provide your existing key as well.

        if [[ -f "$KEY_FILE" && -f "$KEY_FILE.pub" ]]; then
            read -p "Key files already exist. Overwrite? (y/n): " OVERWRITE
            if [[ ! "$OVERWRITE" =~ ^[Yy]$ ]]; then
                echo "Keyfile already exists. Using the same."
            else 
                # Include username in SSH key comment to avoid warnings
                ssh-keygen -t rsa -b 4096 -f "$KEY_FILE" -C "$USERNAME"
                chmod 600 "$KEY_FILE"
            fi
        fi
        # --- Add Key to GCP VM ---

        echo "Adding public key to GCP VM metadata..."
        gcloud compute instances add-metadata "$INSTANCE_NAME" \
            --metadata-from-file ssh-keys="$KEY_FILE.pub" \
            --project="$PROJECT_ID" --zone="$ZONE"

        echo "${BOLD}Public key added successfully.${NC}"
        echo "---------------------------------------------------------"
        echo "${GREEN}VM is ready to perform further actions...${NC}"
        read -p "Connect to the VM now? (y/n): " SSH_CONNECT
        if [[ "$SSH_CONNECT" =~ ^[Yy]$ ]]; then
            echo "Copying script files to the '$INSTANCE_NAME' VM..."
            gcloud compute scp migration.config $INSTANCE_NAME:migration.config --zone=$ZONE --project=$PROJECT_ID --ssh-key-file="$KEY_FILE"
            gcloud compute scp prevalidations.sh $INSTANCE_NAME:prevalidations.sh --zone=$ZONE --project=$PROJECT_ID --ssh-key-file="$KEY_FILE"
            #gcloud compute scp $INPUT_CSV $INSTANCE_NAME:$INPUT_CSV --zone=$ZONE --project=$PROJECT_ID --ssh-key-file="$KEY_FILE"
            echo "${BOLD}Scripts copied to the VM.${NC}"
            echo "---------------------------------------------------------"
            # Execute the prevalidations script on the VM
            echo "${BOLD}Executing pre-validations on the VM '${INSTANCE_NAME}'...${NC}"
            gcloud compute ssh --project "$PROJECT_ID" --zone "$ZONE" --ssh-key-file "$KEY_FILE" "$USERNAME@$INSTANCE_NAME" --command "bash prevalidations.sh"
            echo ""
            echo "${YELLOW}Downloading files...${NC}"
            echo "Downloading CSV file from VM..."
            # Function to check the exit status of gcloud scp
            handle_scp_error() {
              local filename="$1"
              if [ $? -ne 0 ]; then
                echo "${BOLD}${RED}Error downloading '$filename' from VM '${INSTANCE_NAME}'. Please ensure the file exists on the VM.${NC}"
                exit 1
              fi
            }

            # Download users_and_roles.sql
            echo "Downloading users_and_roles.sql..."
            gcloud compute scp --project="$PROJECT_ID" --zone="$ZONE" --ssh-key-file="$KEY_FILE" "$INSTANCE_NAME":"users_and_roles.sql" "users_and_roles.sql"
            handle_scp_error "users_and_roles.sql"

            # Download permissions.sql
            echo "Downloading permissions.sql..."
            gcloud compute scp --project="$PROJECT_ID" --zone="$ZONE" --ssh-key-file="$KEY_FILE" "$INSTANCE_NAME":"permissions.sql" "permissions.sql"
            handle_scp_error "permissions.sql"

            # Download alter_owners.sql
            echo "Downloading alter_owners.sql..."
            gcloud compute scp --project="$PROJECT_ID" --zone="$ZONE" --ssh-key-file="$KEY_FILE" "$INSTANCE_NAME":"alter_owners.sql" "alter_owners.sql"
            handle_scp_error "alter_owners.sql"

            echo "${BOLD}Successfully downloaded SQL files from VM.${NC}"
        else
            echo "Note: You can login to the VM manually and run prevalidations command. Please check guide here : https://github.com/itsabhisharma23/alloydbmigration/blob/main/README.md"
        fi
    else
        echo ""
        echo "${BOLD}You chose not to generate SSH keys to connect to VM.${NC}"
        echo "Note: You can login to the VM manually and run prevalidations command. Please check guide here : https://github.com/itsabhisharma23/alloydbmigration/blob/main/README.md"
    fi
    


    
else
    echo "You choose 'no'. Skipping VM creation."
    echo "Note: You can login to the VM manually and run prevalidations command. Please check guide here : https://github.com/itsabhisharma23/alloydbmigration/blob/main/README.md"
fi









