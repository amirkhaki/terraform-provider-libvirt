#!/bin/bash
# Test scenario to demonstrate the domain update fix

# This script demonstrates how the fix works with a real Terraform example.
# Note: Requires libvirt to be running (qemu:///system)

set -e

echo "===== Domain Update Fix Test Scenario ====="
echo ""
echo "This demonstrates that changing vcpu and memory now UPDATES"
echo "the existing VM instead of destroying and recreating it."
echo ""

# Create a test directory
TEST_DIR="/tmp/terraform-libvirt-update-test"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

# Create initial Terraform configuration
cat > main.tf << 'EOF'
terraform {
  required_providers {
    libvirt = {
      source = "dmacvicar/libvirt"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

resource "libvirt_domain" "update_test" {
  name        = "test-domain-update-demo"
  memory      = 512
  memory_unit = "MiB"
  vcpu        = 1
  type        = "kvm"

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
  }
}

output "domain_uuid" {
  value = libvirt_domain.update_test.uuid
}
EOF

echo "Step 1: Initial apply with 512 MiB memory and 1 vCPU"
echo "------------------------------------------------------"
terraform init
terraform apply -auto-approve

# Save the UUID
INITIAL_UUID=$(terraform output -raw domain_uuid)
echo ""
echo "Initial UUID: $INITIAL_UUID"
echo ""

# Update the configuration
echo "Step 2: Update to 1024 MiB memory and 2 vCPUs"
echo "----------------------------------------------"
cat > main.tf << 'EOF'
terraform {
  required_providers {
    libvirt = {
      source = "dmacvicar/libvirt"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

resource "libvirt_domain" "update_test" {
  name        = "test-domain-update-demo"
  memory      = 1024  # Changed from 512
  memory_unit = "MiB"
  vcpu        = 2     # Changed from 1
  type        = "kvm"

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
  }
}

output "domain_uuid" {
  value = libvirt_domain.update_test.uuid
}
EOF

# Show the plan
echo ""
echo "Terraform plan (notice it shows 'update in-place', not 'destroy and recreate'):"
echo "---------------------------------------------------------------------------------"
terraform plan

# Apply the update
echo ""
echo "Applying the update..."
terraform apply -auto-approve

# Verify UUID is the same
UPDATED_UUID=$(terraform output -raw domain_uuid)
echo ""
echo "Updated UUID: $UPDATED_UUID"
echo ""

if [ "$INITIAL_UUID" = "$UPDATED_UUID" ]; then
    echo "✅ SUCCESS: UUID is the same - domain was UPDATED, not recreated!"
else
    echo "❌ FAILURE: UUID changed - domain was recreated"
    exit 1
fi

# Verify the new configuration
echo ""
echo "Step 3: Verify the domain configuration"
echo "----------------------------------------"
virsh dumpxml test-domain-update-demo | grep -E "<memory|<vcpu"

echo ""
echo "Cleanup..."
terraform destroy -auto-approve

echo ""
echo "===== Test Complete ====="
echo ""
echo "Summary:"
echo "- Initial domain created with 512 MiB / 1 vCPU"
echo "- Updated to 1024 MiB / 2 vCPUs"
echo "- Same UUID before and after: $INITIAL_UUID"
echo "- Domain was updated in-place, not destroyed and recreated"
echo ""
